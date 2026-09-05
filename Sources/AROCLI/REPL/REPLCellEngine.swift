// ============================================================
// REPLCellEngine.swift
// ARO REPL — cell execution shared by every kernel front-end
// ============================================================
//
// The part of "run a notebook cell" that has nothing to do with a
// wire: split the cell into units (ARO-0091 cell semantics),
// accumulate definitions so later cells see earlier ones,
// auto-display the last value-producing statement, reject
// statements that block forever, and answer completion/inspection
// over the session.
//
// Extracted from `JSONREPLServer` so the native ZMQ kernel
// (`aro kernel`) and the stdio JSON server execute cells through
// one code path — a cell must behave identically no matter which
// transport delivered it.

import Foundation
import AROParser
import ARORuntime

final class REPLCellEngine: @unchecked Sendable {

    let session: REPLSession
    /// Where the engine's own notes go (definition confirmations,
    /// meta-command output) — the front-end turns them into its
    /// stream shape. Notes bypass the captured descriptors so they
    /// cannot interleave mid-line with program output.
    var note: (String) -> Void = { _ in }

    private let commands = MetaCommandRegistry.shared
    private let compiler = Compiler()

    /// Sources of every feature set defined in this session, in
    /// definition order, keyed by name so a redefinition replaces
    /// rather than duplicates.
    private(set) var definitions: [String: String] = [:]
    private(set) var definitionOrder: [String] = []

    /// Statements that never return in a notebook. `Keepalive` blocks
    /// until a shutdown signal, which in a cell means a spinner that
    /// never stops. Better to say so than to hang.
    private static let blockingVerbs: Set<String> = ["keepalive", "wait", "block"]

    init(session: REPLSession) {
        self.session = session
    }

    var companionSources: [String] {
        definitionOrder.compactMap { definitions[$0] }
    }

    func reset() {
        session.clear()
        definitions.removeAll()
        definitionOrder.removeAll()
    }

    // MARK: - Execute

    /// @unchecked: the display bundle is `[String: Any]` (JSON
    /// scalars/arrays/dicts only, produced by `REPLDisplay`), handed
    /// across exactly one async→thread bridge and never shared.
    struct Outcome: @unchecked Sendable {
        var display: [String: Any]?
        var error: JSONREPLError?
    }

    /// Run one whole cell: meta-commands, definitions, and statement
    /// blocks in source order. Output streams through the installed
    /// captures as it happens; the returned outcome carries only the
    /// final display bundle or error.
    func executeCell(_ code: String) async -> Outcome {
        let units = REPLCellSplitter.split(code)
        guard !units.isEmpty else { return Outcome() }

        var display: [String: Any]?

        for unit in units {
            switch unit {
            case .meta(let line, _):
                if let failure = await runMeta(line) {
                    return Outcome(error: failure)
                }

            case .featureSet(let name, let activity, let source, let startLine):
                if let failure = define(name: name, activity: activity,
                                        source: source, startLine: startLine) {
                    return Outcome(error: failure)
                }
                display = nil

            case .statements(let source, let startLine):
                if let blocked = blockingVerbRejection(in: source, startLine: startLine) {
                    return Outcome(error: blocked)
                }
                switch await runStatements(source) {
                case .failure(let failure):
                    return Outcome(error: failure)
                case .success(let bundle):
                    display = bundle
                }
            }
        }

        return Outcome(display: display)
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

        // A domain handler is live from this moment: an Emit in a later
        // cell dispatches to it (ARO-0091 event dispatch). Say so —
        // "Defined" alone reads as "parked".
        if let eventType = REPLSession.domainHandlerEventType(for: activity) {
            note("Defined (\(name): \(activity)) — fires on <\(eventType): event>\n")
        } else {
            note("Defined (\(name): \(activity))\n")
        }
        return nil
    }

    private func runStatements(_ source: String) async -> UnitOutcome {
        let companions = companionSources

        // Rebinding guard. The semantic analyzer catches duplicate
        // bindings *within* one program, but a cell is compiled alone —
        // it cannot see that an earlier cell already bound <volume>.
        // The runtime treats that miss as a compiler bug and fatalErrors
        // (RuntimeContext.bind), which in a notebook kills the kernel
        // and the whole session with it. Answer with ARO's immutability
        // message instead — the same advice the language gives
        // (Immutability: bind a new name).
        if let rebound = firstReboundVariable(in: source, companions: companions) {
            return .failure(JSONREPLError(
                name: "ImmutabilityError",
                message: """
                Cannot rebind immutable variable '\(rebound)' — it was bound by an earlier input in this session.
                Variables in ARO are immutable (ARO-0001). Bind a new name instead:
                    Compute the <\(rebound)-updated> …
                or reset the session to start over.
                """
            ))
        }

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

    /// The first result name this unit would bind that the session
    /// already holds, or nil. Only value-producing roles bind their
    /// result (`own` / `request`) — a `Log`'s "result" is its message,
    /// and flagging it would reject legal statements.
    ///
    /// Only TOP-LEVEL statements are checked. A binding inside a
    /// `for each` body lives in the loop's own scope (loop isolation)
    /// and legally shadows a session name — flattening the body into
    /// the scan rejected exactly the code the language allows (the
    /// CI notebook binds `<total>` at top level in one cell and again
    /// inside a later cell's loop). Nested scopes that *do* leak
    /// bindings are the runtime's concern; the guard errs toward
    /// permitting.
    private func firstReboundVariable(in source: String, companions: [String]) -> String? {
        var wrapped = "(_repl_temp_: Interactive) {\n\(source)\n}"
        if !companions.isEmpty {
            wrapped += "\n\n" + companions.joined(separator: "\n\n")
        }
        let result = compiler.compile(wrapped)
        guard result.isSuccess,
              let featureSet = result.analyzedProgram.byName["_repl_temp_"] else {
            // Not compilable — let execution produce the real diagnostic.
            return nil
        }
        let existing = Set(session.variableNames)
        for statement in featureSet.featureSet.statements {
            guard let aro = statement as? AROStatement else { continue }
            // Update-family verbs (update/set/modify/configure) rebind BY
            // CONTRACT — the runtime binds them with allowRebind, and
            // `Configure the <http-client: retries>` after an earlier
            // Configure on the same category is exactly how ARO-0035 says
            // configuration accumulates. Flagging them was a guard false
            // positive (GitLab #506).
            let verb = aro.action.verb.lowercased()
            if VerbSets.updateVerbs.contains(verb) { continue }
            switch aro.action.semanticRole {
            case .own, .request:
                let name = aro.result.base
                if !name.isEmpty, !name.hasPrefix("_"), existing.contains(name) {
                    return name
                }
            case .response, .export, .server:
                continue
            }
        }
        return nil
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

    /// LSP-backed completion via the shared `REPLIntel` engine — the
    /// same answers `aro repl --json` serves, so a Jupyter front-end
    /// on the native kernel and a notebook on the JSON server
    /// complete identically.
    func complete(code: String, cursor: Int) -> REPLIntel.CompletionAnswer {
        REPLIntel.complete(
            code: code,
            cursor: cursor,
            session: session,
            definitions: companionSources
        )
    }

    /// "What is this?": live session value, then LSP hover, then the
    /// action catalog (see `REPLIntel.inspect`).
    func inspect(code: String, cursor: Int) -> (found: Bool, text: String?) {
        REPLIntel.inspect(
            code: code,
            cursor: cursor,
            session: session,
            definitions: companionSources
        )
    }

    // MARK: - Helpers

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
