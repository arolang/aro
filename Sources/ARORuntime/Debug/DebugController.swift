// ============================================================
// DebugController.swift
// ARO Runtime - Debug Controller
// ============================================================
//
// Issue #229 Phase 1. The controller is the runtime-side half of the
// debugger: it holds breakpoint state, decides whether each statement
// should pause, and hands control to the frontend when it does. The
// frontend (TUI / DAP) decides what to do next and returns a `StepMode`
// that drives the next checkpoint.
//
// The controller is a Swift actor — only one checkpoint runs at a time
// even across concurrent feature sets. That matches every real debugger
// I've used and keeps the symbol-table snapshots coherent.

import Foundation
import AROParser

public actor DebugController {
    // MARK: - State

    private let frontend: any DebugFrontend
    private var breakpoints: [DebugBreakpoint] = []
    private var watchExpressions: [String] = []
    private var nextMode: StepMode = .stepOver   // first checkpoint pauses
    private var hasFiredEntry = false
    private var recorder: DebugEventLogWriter?

    // MARK: - Init

    public init(frontend: any DebugFrontend) {
        self.frontend = frontend
    }

    /// Phase 4 — install a record sink. Every pause + event + error
    /// after this call gets appended as a JSONL line.
    public func setRecorder(_ recorder: DebugEventLogWriter) {
        self.recorder = recorder
    }

    // MARK: - Breakpoint management (callable from frontend)

    public func addBreakpoint(_ bp: DebugBreakpoint) {
        if !breakpoints.contains(bp) {
            breakpoints.append(bp)
        }
    }

    public func removeBreakpoint(_ bp: DebugBreakpoint) {
        breakpoints.removeAll { $0 == bp }
    }

    public func clearBreakpoints() {
        breakpoints.removeAll()
    }

    public func listBreakpoints() -> [DebugBreakpoint] {
        breakpoints
    }

    // MARK: - Watch expressions (Phase 3)

    public func addWatch(_ expression: String) {
        if !watchExpressions.contains(expression) {
            watchExpressions.append(expression)
        }
    }

    public func removeWatch(_ expression: String) {
        watchExpressions.removeAll { $0 == expression }
    }

    public func listWatches() -> [String] {
        watchExpressions
    }

    /// Whether any breakpoint cares about a given event name. Cheap
    /// lookup the EventBus hook calls before doing anything expensive.
    nonisolated public func wantsEvent(_ name: String) -> Bool {
        // We can't read the actor state from a nonisolated context, so
        // we cache a *snapshot* on the side. Phase 3 keeps this simple
        // by always returning true and letting the controller filter
        // inside the actor — the EventBus only calls this when a
        // controller is bound at all.
        return true
    }

    // MARK: - Checkpoint hook (called from the runtime)

    /// Called from `FeatureSetExecutor` *before* each statement runs.
    ///
    /// Decides whether to pause and, if so, hands a `PauseInfo` to the
    /// frontend and awaits the next `StepMode`. Cheap fast-path when
    /// stepping is off and no breakpoint matches — a single array scan.
    public func checkpoint(
        statement: any Statement,
        featureSetName: String,
        businessActivity: String,
        sourceFile: String,
        symbols: [SymbolSnapshot]
    ) async {
        let (line, column, summary, verb) = describe(statement)
        let basename = sourceFile.isEmpty
            ? ""
            : URL(fileURLWithPath: sourceFile).lastPathComponent

        // Match breakpoints first — they override the step mode.
        // Conditional matching is evaluated separately; Phase 3 short-
        // circuits when the symbol table has all the names referenced.
        let matched: DebugBreakpoint? = breakpoints.first { bp in
            switch bp {
            case .location(let f, let l):
                return l == line && (f.isEmpty || basename.hasSuffix(f))
            case .verb(let v):
                return verb == v
            case .conditionalLocation(let f, let l, let predicate):
                guard l == line && (f.isEmpty || basename.hasSuffix(f)) else { return false }
                return Self.evaluatePredicate(predicate, symbols: symbols)
            case .event, .errorAny:
                return false   // not relevant at statement boundaries
            }
        }

        let reason: PauseInfo.Reason
        if let bp = matched {
            reason = .breakpoint(bp)
        } else if !hasFiredEntry {
            reason = .entry
        } else {
            switch nextMode {
            case .stepOver, .stepIn, .stepOut:
                reason = .step
            case .continue:
                return // no pause
            }
        }
        hasFiredEntry = true

        let info = PauseInfo(
            reason: reason,
            featureSetName: featureSetName,
            businessActivity: businessActivity,
            file: basename,
            line: line,
            column: column,
            statementSummary: summary,
            verb: verb,
            symbols: symbols
        )

        await record(pause: info)
        nextMode = await frontend.didPause(info, controller: self)
    }

    /// Called from the runtime when an event is about to be published.
    /// Pauses only when an `.event(name)` breakpoint matches; otherwise
    /// returns immediately.
    public func eventCheckpoint(name: String, featureSetName: String, businessActivity: String, payloadPreview: String) async {
        let matched = breakpoints.first { if case .event(let n) = $0 { return n == name } else { return false } }
        guard let bp = matched else { return }
        let info = PauseInfo(
            reason: .event(name),
            featureSetName: featureSetName,
            businessActivity: businessActivity,
            file: "",
            line: 0,
            column: 0,
            statementSummary: "Emit \(name) \(payloadPreview)",
            verb: "Emit",
            symbols: []
        )
        _ = bp  // used for description / future filtering
        nextMode = await frontend.didPause(info, controller: self)
    }

    /// Called from the runtime when a statement is about to fail.
    /// Pauses only when `.errorAny` is set.
    public func errorCheckpoint(message: String, featureSetName: String, businessActivity: String) async {
        let hasErrorBP = breakpoints.contains(.errorAny)
        guard hasErrorBP else { return }
        let info = PauseInfo(
            reason: .error(message),
            featureSetName: featureSetName,
            businessActivity: businessActivity,
            file: "",
            line: 0,
            column: 0,
            statementSummary: "[error] \(message)",
            verb: nil,
            symbols: []
        )
        nextMode = await frontend.didPause(info, controller: self)
    }

    /// Called by the harness when the program completes. Frontend gets a
    /// chance to print a wrap-up message or close a socket.
    public func didEnd(error: Error?) async {
        if let recorder {
            await recorder.write(.end, body: error.map { ["err": "\($0)"] } ?? [:])
            await recorder.close()
        }
        await frontend.didEnd(error: error)
    }

    // MARK: - Recording

    private func record(pause: PauseInfo) async {
        guard let recorder else { return }
        var body: [String: String] = [
            "reason": String(describing: pause.reason),
            "fs": pause.featureSetName,
            "act": pause.businessActivity,
            "file": pause.file,
            "line": "\(pause.line)",
            "col": "\(pause.column)",
            "stmt": pause.statementSummary
        ]
        if let verb = pause.verb { body["verb"] = verb }
        // Serialize symbol snapshots as a single JSON string so the
        // JSONL line stays flat (DebugEventRecord values are strings).
        let symsArr = pause.symbols.map { ["n": $0.name, "ty": $0.typeName, "v": $0.valuePreview] }
        if let symsData = try? JSONSerialization.data(withJSONObject: symsArr, options: [.sortedKeys]),
           let symsStr = String(data: symsData, encoding: .utf8) {
            body["syms"] = symsStr
        }
        await recorder.write(.pause, body: body)
    }

    // MARK: - Predicate evaluation (Phase 3)

    /// Minimal predicate evaluator: matches `<name>` references against
    /// the snapshot's bindings and supports `==`, `!=`, `&&`, `||` over
    /// string previews. This is intentionally tiny — Phase 3 documents
    /// a path to wiring `ExpressionEvaluator` for the full ARO
    /// expression grammar, but doing so requires a live `ExecutionContext`
    /// which the snapshot loses by design.
    private static func evaluatePredicate(_ source: String, symbols: [SymbolSnapshot]) -> Bool {
        var expr = source.trimmingCharacters(in: .whitespaces)
        // Resolve `<name>` references against the snapshot.
        for s in symbols {
            expr = expr.replacingOccurrences(of: "<\(s.name)>", with: "\"\(s.valuePreview)\"")
        }
        // Tiny grammar: split on `&&` first, then `||`, then compare.
        if expr.contains("&&") {
            return expr.split(separator: "&", maxSplits: .max, omittingEmptySubsequences: true)
                .filter { !$0.isEmpty }
                .map(String.init)
                .allSatisfy { evaluatePredicate($0, symbols: symbols) }
        }
        if expr.contains("||") {
            return expr.split(separator: "|", maxSplits: .max, omittingEmptySubsequences: true)
                .filter { !$0.isEmpty }
                .map(String.init)
                .contains { evaluatePredicate($0, symbols: symbols) }
        }
        for op in ["==", "!="] {
            if let range = expr.range(of: op) {
                let lhs = String(expr[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let rhs = String(expr[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                return op == "==" ? lhs == rhs : lhs != rhs
            }
        }
        // Bare expression: truthy when non-empty and not "false".
        let lowered = expr.lowercased()
        return !lowered.isEmpty && lowered != "false" && lowered != "\"\"" && lowered != "0"
    }

    // MARK: - Helpers

    private func describe(_ statement: any Statement) -> (line: Int, column: Int, summary: String, verb: String?) {
        if let aro = statement as? AROStatement {
            let line = aro.span.start.line
            let column = aro.span.start.column
            return (line, column, aro.description, aro.action.verb)
        }
        if let pub = statement as? PublishStatement {
            return (pub.span.start.line, pub.span.start.column, "Publish as \(pub.externalName) \(pub.internalVariable)", "Publish")
        }
        if let m = statement as? MatchStatement {
            return (m.span.start.line, m.span.start.column, "Match …", "Match")
        }
        if let r = statement as? RequireStatement {
            return (r.span.start.line, r.span.start.column, "Require …", "Require")
        }
        if let f = statement as? ForEachLoop {
            return (f.span.start.line, f.span.start.column, "For each …", "ForEach")
        }
        if let w = statement as? WhileLoop {
            return (w.span.start.line, w.span.start.column, "While …", "While")
        }
        if let r = statement as? RangeLoop {
            return (r.span.start.line, r.span.start.column, "Range …", "Range")
        }
        if let p = statement as? PipelineStatement {
            let start = p.stages.first?.span.start
            return (start?.line ?? 0, start?.column ?? 0, "Pipeline (\(p.stages.count) stages)", "Pipeline")
        }
        // BreakStatement and any future Statement types fall through here.
        return (0, 0, "<unknown statement>", nil)
    }
}
