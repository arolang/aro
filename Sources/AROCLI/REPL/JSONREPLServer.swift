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
    private var drainToken = 0

    init(session: REPLSession) {
        self.session = session
        self.engine = REPLCellEngine(session: session)
        #if !os(Windows)
        self.protocolFD = dup(STDOUT_FILENO)
        #endif
        engine.note = { [weak self] text in
            self?.note(text)
        }
    }

    // MARK: - Lifecycle

    func run() async {
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
                send(JSONREPLEncoder.result(id: -1, status: .error, extra: [
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
            let id = self.stateLock.withLock { self.currentRequestId }
            self.send(JSONREPLEncoder.stream(id: id, name: name, text: text))
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
    /// transport does — `readLine` blocks, and blocking a task executor
    /// thread would stall the runtime work the REPL itself depends on.
    private func nextLine() async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: readLine(strippingNewline: true))
            }
        }
    }

    // MARK: - Dispatch

    /// Handle one request. Returns true when the server should stop.
    private func handle(_ request: JSONREPLRequest) async -> Bool {
        stateLock.withLock { currentRequestId = request.id }

        switch request.type {
        case "execute":
            await execute(id: request.id, code: request.code ?? "")
        case "is_complete":
            isComplete(id: request.id, code: request.code ?? "")
        case "complete":
            complete(id: request.id, code: request.code ?? "", cursor: request.cursor ?? 0)
        case "inspect":
            inspect(id: request.id, code: request.code ?? "", cursor: request.cursor ?? 0)
        case "info":
            send(JSONREPLEncoder.result(id: request.id, status: .ok, extra: [
                "info": [
                    "implementation": "aro",
                    "version": AROVersion.shortVersion,
                    "featureSets": session.featureSetNames,
                    "variables": session.variableNames
                ]
            ]))
        case "reset":
            reset()
            send(JSONREPLEncoder.result(id: request.id, status: .ok))
        case "shutdown":
            send(JSONREPLEncoder.result(id: request.id, status: .ok))
            return true
        default:
            send(JSONREPLEncoder.result(id: request.id, status: .error, extra: [
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

    private func execute(id: Int, code: String) async {
        #if os(Windows)
        // `Log` consults this sink before falling back to writing at fd 1
        // (ResponseActions). Windows has no `pipe`/`dup2` capture, so the
        // sink is the only thing that keeps a `Log` out of the protocol
        // stream there.
        let sink: @Sendable (String) -> Void = { [weak self] text in
            self?.send(JSONREPLEncoder.stream(id: id, name: "stdout", text: text + "\n"))
        }
        await ConsoleObject.$sink.withValue(sink) {
            await executeUnits(id: id, code: code)
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
        await executeUnits(id: id, code: code)
        #endif
    }

    private func executeUnits(id: Int, code: String) async {
        let start = Date()
        guard !REPLCellSplitter.split(code).isEmpty else {
            send(JSONREPLEncoder.result(id: id, status: .ok, extra: ["durationMs": 0]))
            return
        }
        let outcome = await engine.executeCell(code)
        finish(id: id, display: outcome.display, error: outcome.error, start: start)
    }

    private func finish(id: Int, display: [String: Any]? = nil, error: JSONREPLError? = nil, start: Date) {
        drainCaptures()
        let durationMs = Date().timeIntervalSince(start) * 1000

        if let error {
            send(JSONREPLEncoder.result(id: id, status: .error, extra: [
                "error": error.payload,
                "durationMs": durationMs
            ]))
            return
        }

        var extra: [String: Any] = ["durationMs": durationMs]
        if let display, !display.isEmpty {
            extra["display"] = display
        }
        send(JSONREPLEncoder.result(id: id, status: .ok, extra: extra))
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
        send(JSONREPLEncoder.result(id: id, status: status, extra: extra))
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
        send(JSONREPLEncoder.result(id: id, status: .ok, extra: [
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
            send(JSONREPLEncoder.result(id: id, status: .ok, extra: ["found": true, "text": text]))
        } else {
            send(JSONREPLEncoder.result(id: id, status: .ok, extra: ["found": false]))
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
