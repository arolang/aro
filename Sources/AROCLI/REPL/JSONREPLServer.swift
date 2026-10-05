// ============================================================
// JSONREPLServer.swift
// ARO REPL — the `aro repl --json` server
// ============================================================
//
// Drives a `REPLSession` from another program: read a request line, execute
// it, answer with one result line. The Jupyter kernel in Editor/jupyter-aro
// is the first client, but nothing here knows about Jupyter — it is the
// general "embed an ARO REPL" surface, and the same loop serves an editor
// scratchpad or a test harness.
//
// Two things make this more than a thin wrapper around `REPLSession`:
//
//   * A cell is not a line. `REPLCellSplitter` breaks it into definitions,
//     statements, and meta-commands the way an interactive session would
//     have received them one at a time.
//   * Definitions accumulate. Every statement is compiled together with the
//     feature sets defined earlier in the session, which is what lets cell 5
//     call the user-defined action (ARO-0081) that cell 2 defined.

import Foundation
import AROParser
import ARORuntime
import AROVersion

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class JSONREPLServer: @unchecked Sendable {

    private let session: REPLSession
    /// The transport-independent half of the server: cell splitting,
    /// definition accumulation, auto-display, completion. Shared with
    /// the native ZMQ kernel so both front-ends run cells identically.
    private let engine: REPLCellEngine

    /// The real stdout, duplicated before fd 1 was redirected. Protocol
    /// messages go here and nowhere else.
    ///
    /// On Windows no redirection happens (see `OutputCapture`), so the
    /// standard handle *is* the protocol channel.
    #if !os(Windows)
    private let protocolFD: Int32
    private var captures: [OutputCapture] = []
    #endif
    private let writeLock = NSLock()

    private let stateLock = NSLock()
    private var currentRequestId = 0

    /// Whether a request is executing right now.
    ///
    /// `currentRequestId` is the *last* request seen, which is the right
    /// stamp for output a cell produced and the wrong one for output that
    /// arrives between cells. A `File Event Handler` woken by a file dropped
    /// while the session idles was being reported under whichever cell ran
    /// last — three seconds after it finished, in the case that found this
    /// (GitLab #913).
    private var requestInFlight = false
    private var drainToken = 0
    /// Whether the `execute` in flight may ask the client a question
    /// (GitLab #690). Per request, because `allow_stdin` is per request
    /// in Jupyter and for the same reason: "Run All" and a headless test
    /// harness have nobody at the keyboard.
    private var allowStdin = false

    /// One reader for stdin, shared by the request loop and by an open
    /// `input_request` — see `StdinLineReader`.
    private let stdin = StdinLineReader()

    init(session: REPLSession) {
        self.session = session
        self.engine = REPLCellEngine(session: session)
        #if !os(Windows)
        self.protocolFD = dup(STDOUT_FILENO)
        #endif
        engine.note = { [weak self] text in
            self?.note(text)
        }
        session.useInteractiveInput(FrontEndInputChannel { [weak self] prompt, hidden in
            guard let self else { throw InteractiveInputError.closed(action: "Prompt") }
            return try await self.askClient(prompt: prompt, hidden: hidden)
        })
    }

    // MARK: - Lifecycle

    func run() async {
        stdin.start()
        #if !os(Windows)
        // Before installCaptures(): it replaces fd 2 with a pipe, and a
        // duplicate taken after that points at the process's own reader
        // thread rather than at the client (GitLab #490).
        REPLDiagnostics.install()
        #endif
        installCaptures()
        send(JSONREPLEncoder.line([
            "type": "ready",
            "version": AROVersion.shortVersion,
            "protocol": 1
        ]))

        while let line = await nextLine() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            guard
                let data = trimmed.data(using: .utf8),
                let request = try? JSONDecoder().decode(JSONREPLRequest.self, from: data)
            else {
                sendResult(JSONREPLEncoder.result(id: -1, status: .error, extra: [
                    "error": JSONREPLError(name: "ProtocolError", message: "malformed request: \(trimmed)").payload
                ]))
                continue
            }

            let shouldStop = await handle(request)
            if shouldStop {
                #if !os(Windows)
                REPLDiagnostics.markShuttingDown()
                #endif
                break
            }
        }
    }

    /// Redirect stdout and stderr into `stream` messages.
    ///
    /// Installed after `protocolFD` is duplicated, so the protocol keeps a
    /// private handle on the real stdout while everything the runtime prints
    /// is routed to the client as output.
    private func installCaptures() {
        #if !os(Windows)
        let emit: @Sendable (String, String) -> Void = { [weak self] name, text in
            guard let self else { return }
            let (id, inFlight) = self.stateLock.withLock {
                (self.currentRequestId, self.requestInFlight)
            }
            // Output that arrives while nothing is executing belongs to no
            // cell. It is said so explicitly rather than attributed to the
            // last one, which is a claim about causation that is simply false
            // — and which a front-end that has already finalised that cell
            // would either misplace or drop (GitLab #913).
            if inFlight {
                self.send(JSONREPLEncoder.stream(id: id, name: name, text: text))
            } else {
                self.send(JSONREPLEncoder.backgroundStream(name: name, text: text))
            }
        }

        if let out = OutputCapture(name: "stdout", targetFD: STDOUT_FILENO, emit: emit) {
            captures.append(out)
        }
        if let err = OutputCapture(name: "stderr", targetFD: STDERR_FILENO, emit: emit) {
            captures.append(err)
        }
        #endif
    }

    /// Flush captured output and wait for it, so every `stream` message for a
    /// request is on the wire before that request's result.
    private func drainCaptures() {
        #if !os(Windows)
        let token = stateLock.withLock { () -> Int in
            drainToken += 1
            return drainToken
        }

        for capture in captures {
            capture.drain(token: token)
        }
        #endif
    }

    /// Send a `result`, which is also what ends a request.
    ///
    /// The flag has to drop here rather than at the end of `handle`, because
    /// a handler woken by the cell can still be running when the result goes
    /// out — and from that moment its output is background output, not the
    /// cell's (GitLab #913).
    private func sendResult(_ line: String) {
        stateLock.withLock { requestInFlight = false }
        send(line)
    }

    private func send(_ line: String) {
        let payload = Data((line + "\n").utf8)
        writeLock.lock()
        defer { writeLock.unlock() }
        #if os(Windows)
        FileHandle.standardOutput.write(payload)
        #else
        payload.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < raw.count {
                let n = write(protocolFD, base.advanced(by: written), raw.count - written)
                if n <= 0 { break }
                written += n
            }
        }
        #endif
    }

    /// Read one line from stdin off the cooperative pool, as the MCP
    /// transport does — the read blocks, and blocking a task executor
    /// thread would stall the runtime work the REPL itself depends on.
    ///
    /// The read goes through `StdinLineReader` rather than `readLine`
    /// directly, because an open `input_request` reads the same
    /// descriptor and needs a *bounded* wait (GitLab #690).
    private func nextLine() async -> String? {
        switch await stdin.nextOffPool(timeoutSeconds: nil) {
        case .line(let line): return line
        case .endOfInput, .timedOut: return nil
        }
    }

    // MARK: - Interactive input (GitLab #690)

    /// Ask the client a question and wait for its `input_reply`.
    ///
    /// Only reachable from inside an `execute`, which is what makes
    /// reading stdin here safe: the request loop is parked in
    /// `handle(_:)` until the cell finishes, so this is the only reader
    /// at this moment — and `StdinLineReader` makes that structural
    /// rather than merely true.
    ///
    /// Three ways out, so no cell can wait forever:
    /// the reply, EOF (the client is gone), and the timeout.
    private func askClient(prompt: String, hidden: Bool) async throws -> String {
        let (id, allowed) = stateLock.withLock { (currentRequestId, allowStdin) }

        guard allowed else {
            throw InteractiveInputError.declined(
                action: "Prompt",
                detail: #"the client did not set "allowStdin": true on this execute request"#)
        }

        // The question's own context — a `Select` menu, a `Log` line
        // above it — is on the captured descriptors. Flush it first, or
        // the client renders an input box for a question whose text is
        // still in a pipe (the same ordering rule results already obey).
        drainCaptures()
        send(JSONREPLEncoder.inputRequest(id: id, prompt: prompt, password: hidden))

        let timeout = InteractiveInput.timeoutSeconds
        let deadline = timeout == 0 ? nil : timeout

        while true {
            switch await stdin.nextOffPool(timeoutSeconds: deadline) {
            case .timedOut:
                throw InteractiveInputError.timedOut(action: "Prompt", seconds: timeout)

            case .endOfInput:
                throw InteractiveInputError.closed(action: "Prompt")

            case .line(let line):
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                guard
                    let data = trimmed.data(using: .utf8),
                    let message = try? JSONDecoder().decode(JSONREPLRequest.self, from: data)
                else {
                    send(JSONREPLEncoder.result(id: -1, status: .error, extra: [
                        "error": JSONREPLError(
                            name: "ProtocolError",
                            message: "malformed request: \(trimmed)").payload
                    ]))
                    continue
                }

                if message.type == "shutdown" {
                    // The front-end is leaving. That is an answer of a
                    // kind: the statement fails, and the request loop
                    // gets the message back so the server still exits.
                    stdin.unread(line)
                    throw InteractiveInputError.closed(action: "Prompt")
                }

                guard message.type == "input_reply" else {
                    // A request sent while a question is open. Answering
                    // it would run a second cell inside the first, on a
                    // session that is explicitly one-request-at-a-time
                    // (ARO-0091 §Limits). Refuse it by name and keep
                    // waiting for the answer.
                    send(JSONREPLEncoder.result(id: message.id, status: .error, extra: [
                        "error": JSONREPLError(
                            name: "ProtocolError",
                            message: "an input_request for request \(id) is open — "
                                   + "answer it with an input_reply before sending a "
                                   + "'\(message.type)'").payload
                    ]))
                    continue
                }

                if message.status == "error" {
                    throw InteractiveInputError.declined(
                        action: "Prompt",
                        detail: "the client answered the input_request with an error")
                }
                return message.value ?? ""
            }
        }
    }

    // MARK: - Dispatch

    /// Handle one request. Returns true when the server should stop.
    private func handle(_ request: JSONREPLRequest) async -> Bool {
        stateLock.withLock {
            currentRequestId = request.id
            requestInFlight = true
        }

        switch request.type {
        case "execute":
            // Per request, and false unless asked for (GitLab #690).
            stateLock.withLock { allowStdin = request.allowStdin ?? false }
            await execute(id: request.id, code: request.code ?? "",
                          cellID: request.cellId, baseDir: request.baseDir)
            stateLock.withLock { allowStdin = false }
        case "input_reply":
            // Only meaningful while a question is open, and then it is
            // read by `askClient`, not here. Reaching the dispatch loop
            // means there was nothing to answer — say so, rather than
            // report it as an unknown message type.
            send(JSONREPLEncoder.result(id: request.id, status: .error, extra: [
                "error": JSONREPLError(
                    name: "ProtocolError",
                    message: "no input_request is open").payload
            ]))
        case "is_complete":
            isComplete(id: request.id, code: request.code ?? "")
        case "complete":
            complete(id: request.id, code: request.code ?? "", cursor: request.cursor ?? 0)
        case "inspect":
            inspect(id: request.id, code: request.code ?? "", cursor: request.cursor ?? 0)
        case "info":
            sendResult(JSONREPLEncoder.result(id: request.id, status: .ok, extra: [
                "info": [
                    "implementation": "aro",
                    "version": AROVersion.shortVersion,
                    "featureSets": session.featureSetNames,
                    "variables": session.variableNames
                ]
            ]))
        case "reset":
            reset()
            sendResult(JSONREPLEncoder.result(id: request.id, status: .ok))
        case "shutdown":
            sendResult(JSONREPLEncoder.result(id: request.id, status: .ok))
            return true
        default:
            sendResult(JSONREPLEncoder.result(id: request.id, status: .error, extra: [
                "error": JSONREPLError(
                    name: "ProtocolError",
                    message: "unknown request type '\(request.type)'"
                ).payload
            ]))
        }
        return false
    }

    private func reset() {
        engine.reset()
    }

    // MARK: - Execute

    /// Run a cell, with relative paths resolving against the notebook's own
    /// folder when the front-end said which one it is (GitLab #915).
    ///
    /// `AROWorkingDirectory.setProcessDefault` rather than its task-local:
    /// binding an ARORuntime `@TaskLocal` from AROCLI segfaults on Linux
    /// inside `swift_task_localValuePush` (GitLab #490, the same reason the
    /// console sink is not bound here). The process default is safe because
    /// this server executes one cell at a time, and it is restored after.
    private func execute(id: Int, code: String, cellID: String? = nil,
                         baseDir: String?) async {
        guard let baseDir, !baseDir.isEmpty else {
            await execute(id: id, code: code, cellID: cellID)
            return
        }
        let previous = AROWorkingDirectory.setProcessDefault(baseDir)
        defer { AROWorkingDirectory.setProcessDefault(previous) }
        await execute(id: id, code: code, cellID: cellID)
    }

    private func execute(id: Int, code: String, cellID: String? = nil) async {
        #if os(Windows)
        // `Log` consults this sink before falling back to writing at fd 1
        // (LogAction). Windows has no `pipe`/`dup2` capture, so the
        // sink is the only thing that keeps a `Log` out of the protocol
        // stream there.
        let sink: @Sendable (String) -> Void = { [weak self] text in
            self?.send(JSONREPLEncoder.stream(id: id, name: "stdout", text: text + "\n"))
        }
        await ConsoleObject.$sink.withValue(sink) {
            await executeUnits(id: id, code: code, cellID: cellID)
        }
        #else
        // No sink on POSIX: `OutputCapture` already redirects fd 1, so
        // `Log` arrives as a `stream` message either way, and `drain`
        // — not the sink — is what guarantees a cell's output precedes
        // its result.
        //
        // Binding it was also a hard crash on Linux (GitLab #490).
        // `ConsoleObject.sink` is a `@TaskLocal` declared in ARORuntime;
        // binding it from AROCLI segfaulted inside
        // `swift_task_localValuePush` on the first statement of every
        // session, while the interactive REPL — which never binds it —
        // ran the same statements fine. gdb, on the crashing thread:
        //
        //     #0  swift_task_localValuePush
        //     #1  TaskLocal.withValue(…)  JSONREPLServer.swift:237
        //     #2  JSONREPLServer.execute(id:code:)
        //
        // Two mechanisms for one job, one of which does not work here.
        await executeUnits(id: id, code: code, cellID: cellID)
        #endif
    }

    private func executeUnits(id: Int, code: String, cellID: String? = nil) async {
        let start = Date()
        guard !REPLCellSplitter.split(code).isEmpty else {
            sendResult(JSONREPLEncoder.result(id: id, status: .ok, extra: ["durationMs": 0]))
            return
        }
        let outcome = await engine.executeCell(code, cellID: cellID)
        finish(id: id, display: outcome.display, error: outcome.error, start: start)
    }

    private func finish(id: Int, display: [String: Any]? = nil, error: JSONREPLError? = nil, start: Date) {
        drainCaptures()
        let durationMs = Date().timeIntervalSince(start) * 1000

        if let error {
            sendResult(JSONREPLEncoder.result(id: id, status: .error, extra: [
                "error": error.payload,
                "durationMs": durationMs
            ]))
            return
        }

        var extra: [String: Any] = ["durationMs": durationMs]
        if let display, !display.isEmpty {
            extra["display"] = display
        }
        sendResult(JSONREPLEncoder.result(id: id, status: .ok, extra: extra))
    }

    // MARK: - Completion & inspection

    private func isComplete(id: Int, code: String) {
        let status: JSONREPLStatus
        var extra: [String: Any] = [:]

        switch MultilineDetector.check(code) {
        case .complete:
            status = .complete
        case .needsMore:
            status = .incomplete
            extra["indent"] = "    "
        case .error:
            status = .invalid
        }
        sendResult(JSONREPLEncoder.result(id: id, status: status, extra: extra))
    }

    /// LSP-backed completion (ARO-0091): the shared `REPLIntel` engine
    /// frames the cell the way `execute` frames it, runs the same
    /// `CompletionHandler` the editors use, and merges the session's
    /// own names on top. Definitions come from the cell engine — the
    /// native kernel shares them through the same call.
    private func complete(id: Int, code: String, cursor: Int) {
        let answer = REPLIntel.complete(
            code: code,
            cursor: cursor,
            session: session,
            definitions: engine.companionSources
        )
        sendResult(JSONREPLEncoder.result(id: id, status: .ok, extra: [
            "matches": answer.matches,
            "items": answer.items,
            "cursorStart": answer.cursorStart,
            "cursorEnd": answer.cursorEnd
        ]))
    }

    /// Answer "what is this?" for the token under the cursor: a session
    /// variable's live value, the LSP's hover for the compiled cell, or
    /// the action catalog — in that order (see `REPLIntel.inspect`).
    private func inspect(id: Int, code: String, cursor: Int) {
        let answer = REPLIntel.inspect(
            code: code,
            cursor: cursor,
            session: session,
            definitions: engine.companionSources
        )
        if answer.found, let text = answer.text {
            sendResult(JSONREPLEncoder.result(id: id, status: .ok, extra: ["found": true, "text": text]))
        } else {
            sendResult(JSONREPLEncoder.result(id: id, status: .ok, extra: ["found": false]))
        }
    }

    // MARK: - Helpers

    /// Write text to the client as stdout, without going through the captured
    /// descriptor — used for the server's own notes (definitions registered,
    /// meta-command output) so they cannot interleave mid-line with program
    /// output that is still draining.
    private func note(_ text: String) {
        let id = stateLock.withLock { currentRequestId }
        send(JSONREPLEncoder.stream(id: id, name: "stdout", text: text))
    }

    /// Render diagnostics with line numbers relative to the cell.
    ///
    /// `wrapperOffset` is how many lines the compiler saw before the user's
    /// first line; `startLine` is where the unit began in the cell. Getting
    /// this wrong points the user at the wrong line, which is worse than
    /// printing no line at all.
    private func diagnosticText(_ diagnostics: [Diagnostic], startLine: Int, wrapperOffset: Int) -> String {
        diagnostics
            .filter { $0.severity == .error }
            .map { diagnostic in
                guard let location = diagnostic.location else { return diagnostic.message }
                let line = location.line - wrapperOffset + startLine
                return "Line \(line): \(diagnostic.message)"
            }
            .joined(separator: "\n")
    }
}

// MARK: - Text tables

/// Renders a meta-command's table as monospaced text.
///
/// `:vars` and `:fs` return rows the shell prints with column alignment; a
/// notebook shows the same thing, so the alignment has to happen here rather
/// than in `REPLShell`, which is not on this path.
enum REPLTextTable {
    static func render(_ rows: [[String]]) -> String {
        guard let header = rows.first else { return "" }

        var widths = header.map { $0.count }
        for row in rows {
            for (index, cell) in row.enumerated() where index < widths.count {
                widths[index] = max(widths[index], cell.count)
            }
        }

        func line(_ row: [String]) -> String {
            row.enumerated()
                .map { index, cell in
                    index < widths.count ? cell.padding(toLength: widths[index], withPad: " ", startingAt: 0) : cell
                }
                .joined(separator: " | ")
                .trimmingCharacters(in: .whitespaces)
        }

        var output = line(header) + "\n"
        output += widths.map { String(repeating: "-", count: $0) }.joined(separator: "-+-") + "\n"
        for row in rows.dropFirst() {
            output += line(row) + "\n"
        }
        return output
    }
}
