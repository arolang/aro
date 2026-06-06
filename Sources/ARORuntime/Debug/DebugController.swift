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
    /// Wall-clock at the most recent checkpoint we built a
    /// PauseInfo for (#282 phase 2). Used to compute the
    /// `elapsedNanos` between successive statements.
    private var previousCheckpointAt: DispatchTime?

    // Phase 5 — sampling. When >1, the controller only enters the pause
    // path on every N-th eligible checkpoint. Used for `--attach` style
    // production debugging where pausing every statement would crater
    // request throughput.
    private var sampleStride: Int = 1
    private var sampleCounter: Int = 0

    // MARK: - Init

    public init(frontend: any DebugFrontend) {
        self.frontend = frontend
    }

    /// Phase 4 — install a record sink. Every pause + event + error
    /// after this call gets appended as a JSONL line.
    public func setRecorder(_ recorder: DebugEventLogWriter) {
        self.recorder = recorder
    }

    /// Phase 5 — sampling stride. `1` (default) pauses on every
    /// eligible checkpoint; `N > 1` skips N-1 between pauses. Breakpoints
    /// still match every time — sampling only thins the step-mode pause
    /// stream so an attached prod session doesn't stall every request.
    public func setSampleStride(_ stride: Int) {
        sampleStride = max(1, stride)
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
        symbols: [SymbolSnapshot],
        context: ExecutionContext? = nil
    ) async throws {
        // If a previous pause asked to quit, throw on the next statement
        // boundary so the executor unwinds cleanly. (eventCheckpoint /
        // errorCheckpoint set this state from non-throwing contexts.)
        if nextMode == .quit {
            throw DebuggerQuit()
        }

        let (line, column, summary, verb) = describe(statement)
        let basename = sourceFile.isEmpty
            ? ""
            : URL(fileURLWithPath: sourceFile).lastPathComponent

        // Match breakpoints first — they override the step mode.
        // Conditional predicates evaluate against the live context when
        // one is available (preferred) and fall back to the snapshot-
        // string evaluator when it isn't.
        var matched: DebugBreakpoint? = nil
        for bp in breakpoints {
            switch bp {
            case .location(let f, let l):
                if l == line && (f.isEmpty || basename.hasSuffix(f)) {
                    matched = bp
                }
            case .verb(let v):
                if verb == v { matched = bp }
            case .conditionalLocation(let f, let l, let predicate):
                guard l == line && (f.isEmpty || basename.hasSuffix(f)) else { continue }
                let result: Bool
                if let ctx = context {
                    result = await PredicateEvaluator.evaluate(predicate, context: ctx)
                } else {
                    result = Self.evaluatePredicateFromSnapshot(predicate, symbols: symbols)
                }
                if result { matched = bp }
            case .event, .errorAny:
                continue   // not relevant at statement boundaries
            }
            if matched != nil { break }
        }

        let reason: PauseInfo.Reason
        if let bp = matched {
            reason = .breakpoint(bp)
        } else if !hasFiredEntry {
            reason = .entry
        } else {
            switch nextMode {
            case .stepOver, .stepIn, .stepOut:
                // Phase 5 sampling — only the every-Nth checkpoint
                // actually pauses; the rest skip silently. Breakpoint
                // matches above are unaffected.
                sampleCounter += 1
                if sampleCounter < sampleStride { return }
                sampleCounter = 0
                reason = .step
            case .continue:
                return // no pause
            case .quit:
                throw DebuggerQuit()
            }
        }
        hasFiredEntry = true

        let now = DispatchTime.now()
        let elapsed: UInt64
        if let prev = previousCheckpointAt {
            elapsed = now.uptimeNanoseconds - prev.uptimeNanoseconds
        } else {
            elapsed = 0
        }
        previousCheckpointAt = now
        let metrics = PauseMetrics(
            elapsedNanos: elapsed,
            residentMemoryBytes: Self.residentMemoryBytes()
        )

        let info = PauseInfo(
            reason: reason,
            featureSetName: featureSetName,
            businessActivity: businessActivity,
            file: basename,
            line: line,
            column: column,
            statementSummary: summary,
            verb: verb,
            symbols: symbols,
            metrics: metrics
        )

        await record(pause: info)
        nextMode = await frontend.didPause(info, controller: self)
        if nextMode == .quit {
            throw DebuggerQuit()
        }
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
    /// Pauses only when `.errorAny` is set. `line`/`file` should be
    /// the source location of the failing statement so the frontend
    /// can paint the right node (the frontend's lookback-fallback
    /// gets stale when `checkpoint()` short-circuits at sampling).
    public func errorCheckpoint(
        message: String,
        featureSetName: String,
        businessActivity: String,
        line: Int = 0,
        file: String = ""
    ) async {
        let hasErrorBP = breakpoints.contains(.errorAny)
        guard hasErrorBP else { return }
        let info = PauseInfo(
            reason: .error(message),
            featureSetName: featureSetName,
            businessActivity: businessActivity,
            file: file,
            line: line,
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

    /// Fallback predicate evaluator used only when `checkpoint` is called
    /// without a live `ExecutionContext` — matches `<name>` against
    /// snapshot previews and supports `==` / `!=` / `&&` / `||`. The
    /// primary path is `PredicateEvaluator.evaluate`, which uses the
    /// real `AROParser` + `ExpressionEvaluator` against a live context
    /// (#230). Keeping this fallback around preserves bug-compatibility
    /// with the original #229 Phase 3 behavior for any harness that
    /// hasn't been updated to thread an `ExecutionContext` through.
    private static func evaluatePredicateFromSnapshot(_ source: String, symbols: [SymbolSnapshot]) -> Bool {
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
                .allSatisfy { evaluatePredicateFromSnapshot($0, symbols: symbols) }
        }
        if expr.contains("||") {
            return expr.split(separator: "|", maxSplits: .max, omittingEmptySubsequences: true)
                .filter { !$0.isEmpty }
                .map(String.init)
                .contains { evaluatePredicateFromSnapshot($0, symbols: symbols) }
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

    /// Resident memory the runtime process currently holds
    /// (#282 phase 2). Platform-specific:
    ///
    /// - macOS / Darwin: BSD `task_info(TASK_BASIC_INFO)` —
    ///   matches Activity Monitor's "Real Memory."
    /// - Linux: parses `VmRSS` out of `/proc/self/status` and
    ///   converts from kB to bytes.
    /// - Other: returns 0.
    ///
    /// 0 is the platform's "I don't know" sentinel — callers
    /// should treat it as "unknown" rather than "no memory."
    nonisolated static func residentMemoryBytes() -> UInt64 {
        #if canImport(Darwin)
        var info = task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_basic_info_data_t>.size
            / MemoryLayout<integer_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { p in
                task_info(mach_task_self_,
                          task_flavor_t(TASK_BASIC_INFO),
                          p,
                          &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return UInt64(info.resident_size)
        #elseif canImport(Glibc) || canImport(Musl)
        guard let text = try? String(
            contentsOfFile: "/proc/self/status",
            encoding: .utf8
        ) else { return 0 }
        for line in text.split(separator: "\n") {
            if line.hasPrefix("VmRSS:") {
                // `VmRSS:    12345 kB`
                let parts = line.split(separator: " ",
                                       omittingEmptySubsequences: true)
                if parts.count >= 2, let kb = UInt64(parts[1]) {
                    return kb * 1024
                }
            }
        }
        return 0
        #else
        return 0
        #endif
    }
}
