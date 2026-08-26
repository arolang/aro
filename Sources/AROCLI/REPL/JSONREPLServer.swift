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
    private let commands = MetaCommandRegistry.shared
    private let compiler = Compiler()

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

    /// Sources of every feature set defined in this session, in definition
    /// order, keyed by name so a redefinition replaces rather than duplicates.
    private var definitions: [String: String] = [:]
    private var definitionOrder: [String] = []

    private let stateLock = NSLock()
    private var currentRequestId = 0
    private var drainToken = 0

    /// Statements that never return in a notebook. `Keepalive` blocks until a
    /// shutdown signal, which in a cell means a spinner that never stops and
    /// a session that can only be recovered by restarting the kernel. Better
    /// to say so than to hang.
    private static let blockingVerbs: Set<String> = ["keepalive", "wait", "block"]

    init(session: REPLSession) {
        self.session = session
        #if !os(Windows)
        self.protocolFD = dup(STDOUT_FILENO)
        #endif
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
        session.clear()
        definitions.removeAll()
        definitionOrder.removeAll()
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
        let units = REPLCellSplitter.split(code)

        guard !units.isEmpty else {
            send(JSONREPLEncoder.result(id: id, status: .ok, extra: ["durationMs": 0]))
            return
        }

        var display: [String: Any]?

        for unit in units {
            switch unit {
            case .meta(let line, _):
                if let failure = await runMeta(line) {
                    finish(id: id, error: failure, start: start)
                    return
                }

            case .featureSet(let name, let activity, let source, let startLine):
                if let failure = define(name: name, activity: activity, source: source, startLine: startLine) {
                    finish(id: id, error: failure, start: start)
                    return
                }
                display = nil

            case .statements(let source, let startLine):
                if let blocked = blockingVerbRejection(in: source, startLine: startLine) {
                    finish(id: id, error: blocked, start: start)
                    return
                }
                switch await runStatements(source) {
                case .failure(let failure):
                    finish(id: id, error: failure, start: start)
                    return
                case .success(let bundle):
                    display = bundle
                }
            }
        }

        finish(id: id, display: display, start: start)
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

    // MARK: - Units

    private enum UnitOutcome {
        case success([String: Any]?)
        case failure(JSONREPLError)
    }

    private func runMeta(_ line: String) async -> JSONREPLError? {
        do {
            let result = try await commands.execute(input: line, session: session)
            switch result {
            case .output(let text):
                note(text + "\n")
            case .table(let rows):
                note(REPLTextTable.render(rows))
            case .error(let message):
                return JSONREPLError(name: "CommandError", message: message)
            case .exit:
                // `:quit` has no meaning here — the client owns the process
                // lifetime, and silently killing the kernel from a cell would
                // look like a crash.
                note("Use the client's \"restart kernel\" action to end this session.\n")
            case .clear, .none:
                break
            }
        } catch {
            return JSONREPLError(name: "CommandError", message: String(describing: error))
        }
        return nil
    }

    private func define(name: String, activity: String, source: String, startLine: Int) -> JSONREPLError? {
        let result = compiler.compile(source)
        guard result.isSuccess else {
            return JSONREPLError(
                name: "CompileError",
                message: diagnosticText(result.diagnostics, startLine: startLine, wrapperOffset: 0)
            )
        }
        guard let analyzed = result.analyzedProgram.byName[name]
            ?? result.analyzedProgram.featureSets.first else {
            return JSONREPLError(name: "CompileError", message: "No feature set found in '\(name)'")
        }

        session.addFeatureSet(name: name, featureSet: analyzed, source: source)
        if definitions[name] == nil {
            definitionOrder.append(name)
        }
        definitions[name] = source

        note("Defined (\(name): \(activity))\n")
        return nil
    }

    private func runStatements(_ source: String) async -> UnitOutcome {
        let companions = definitionOrder.compactMap { definitions[$0] }

        do {
            let result = try await session.executeStatement(source, companions: companions)
            switch result {
            case .value(let value):
                return .success(REPLDisplay.bundle(for: value))
            case .ok:
                return .success(autoDisplay(for: source, companions: companions))
            case .error(let message):
                return .failure(JSONREPLError(message: message))
            default:
                return .success(nil)
            }
        } catch {
            return .failure(JSONREPLError(message: String(describing: error)))
        }
    }

    /// The value to show for a cell that ran without an explicit `Return`.
    ///
    /// A notebook that shows nothing for `Compute the <total> from <a> + <b>.`
    /// is not a notebook. The last statement's result is displayed, but only
    /// when that statement produces a value: showing something after `Log` or
    /// `Store` would duplicate output or invent a result the statement never
    /// had.
    private func autoDisplay(for source: String, companions: [String]) -> [String: Any]? {
        var wrapped = "(_repl_temp_: Interactive) {\n\(source)\n}"
        if !companions.isEmpty {
            wrapped += "\n\n" + companions.joined(separator: "\n\n")
        }

        let result = compiler.compile(wrapped)
        guard
            result.isSuccess,
            let featureSet = result.analyzedProgram.byName["_repl_temp_"],
            let last = featureSet.flattenedAROStatements.last
        else { return nil }

        switch last.action.semanticRole {
        case .own, .request:
            break
        case .response, .export, .server:
            return nil
        }

        let name = last.result.base
        guard !name.isEmpty, !name.hasPrefix("_"), let value = session.getVariable(name) else {
            return nil
        }
        return REPLDisplay.bundle(for: value)
    }

    /// Reject a cell whose statement would block until shutdown.
    ///
    /// Set `ARO_REPL_ALLOW_BLOCKING=1` to run it anyway — the escape hatch
    /// exists because "start a server and keep it alive" is a legitimate
    /// thing to demonstrate, just not one a cell can return from.
    private func blockingVerbRejection(in source: String, startLine: Int) -> JSONREPLError? {
        if ProcessInfo.processInfo.environment["ARO_REPL_ALLOW_BLOCKING"] == "1" { return nil }

        for (offset, line) in source.components(separatedBy: .newlines).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let verb = trimmed.split(separator: " ").first.map(String.init) else { continue }
            let normalized = verb.trimmingCharacters(in: CharacterSet(charactersIn: "<>")).lowercased()
            guard Self.blockingVerbs.contains(normalized) else { continue }

            return JSONREPLError(
                name: "BlockingStatement",
                message: """
                Line \(startLine + offset + 1): '\(verb)' blocks until the process is signalled, \
                so it never returns in an interactive session.
                Services started in an earlier statement keep running without it.
                Set ARO_REPL_ALLOW_BLOCKING=1 to run it anyway.
                """
            )
        }
        return nil
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

    /// Prefix completion over the things a session can name.
    ///
    /// Deliberately local rather than routed through the LSP's completion
    /// handler: that one answers for a document on disk with a full
    /// compilation behind it, while a half-typed cell has neither, and the
    /// session's own variables and feature sets are the part a notebook user
    /// actually reaches for.
    private func complete(id: Int, code: String, cursor: Int) {
        let characters = Array(code)
        let safeCursor = max(0, min(cursor, characters.count))

        // Walk back over the token being typed. `<` and `:` are included as
        // starts because they select what kind of name is wanted.
        var start = safeCursor
        while start > 0 {
            let character = characters[start - 1]
            if character.isLetter || character.isNumber || character == "-" || character == "_" || character == "." {
                start -= 1
            } else {
                break
            }
        }
        let token = String(characters[start..<safeCursor])
        let preceding = start > 0 ? characters[start - 1] : " "

        var matches: [String] = []

        if preceding == ":" && start > 1 {
            // `<value: qual` — a qualifier slot.
            matches += AROCatalog.qualifiersSnapshot()
                .map(\.fullName)
                .filter { $0.hasPrefix(token) }
        } else if token.hasPrefix(":") || preceding == ":" {
            matches += commands.commandNames.map { ":\($0)" }.filter { $0.hasPrefix(token) }
        } else {
            if preceding == "<" {
                matches += session.variableNames.filter { $0.hasPrefix(token) }
            }
            matches += AROCatalog.actionsSnapshot()
                .map(\.verb)
                .filter { $0.lowercased().hasPrefix(token.lowercased()) }
            matches += session.featureSetNames.filter { $0.hasPrefix(token) }
            if preceding != "<" {
                matches += session.variableNames.filter { $0.hasPrefix(token) }
            }
        }

        send(JSONREPLEncoder.result(id: id, status: .ok, extra: [
            "matches": Array(Set(matches)).sorted(),
            "cursorStart": start,
            "cursorEnd": safeCursor
        ]))
    }

    /// Answer "what is this?" for the token under the cursor: a session
    /// variable's value, or an action's role and prepositions.
    private func inspect(id: Int, code: String, cursor: Int) {
        let characters = Array(code)
        let safeCursor = max(0, min(cursor, characters.count))

        var start = safeCursor
        while start > 0, isTokenCharacter(characters[start - 1]) { start -= 1 }
        var end = safeCursor
        while end < characters.count, isTokenCharacter(characters[end]) { end += 1 }

        let token = String(characters[start..<end])
        guard !token.isEmpty else {
            send(JSONREPLEncoder.result(id: id, status: .ok, extra: ["found": false]))
            return
        }

        if let value = session.getVariable(token) {
            let text = """
            <\(token)>

            \(ResponseFormatter.formatValue(value, for: .human))
            """
            send(JSONREPLEncoder.result(id: id, status: .ok, extra: [
                "found": true,
                "text": text
            ]))
            return
        }

        if let action = AROCatalog.actionsSnapshot().first(where: { $0.verb.lowercased() == token.lowercased() }) {
            var text = "\(action.verb) — \(action.role.rawValue) action"
            if !action.prepositions.isEmpty {
                text += "\nPrepositions: \(action.prepositions.joined(separator: ", "))"
            }
            if let description = action.description {
                text += "\n\n\(description)"
            }
            send(JSONREPLEncoder.result(id: id, status: .ok, extra: ["found": true, "text": text]))
            return
        }

        send(JSONREPLEncoder.result(id: id, status: .ok, extra: ["found": false]))
    }

    private func isTokenCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "-" || character == "_" || character == "."
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
