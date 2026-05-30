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
    private var nextMode: StepMode = .stepOver   // first checkpoint pauses
    private var hasFiredEntry = false

    // MARK: - Init

    public init(frontend: any DebugFrontend) {
        self.frontend = frontend
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
        let matched: DebugBreakpoint? = breakpoints.first { bp in
            switch bp {
            case .location(let f, let l):
                return l == line && basename.hasSuffix(f)
            case .verb(let v):
                return verb == v
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

        nextMode = await frontend.didPause(info, controller: self)
    }

    /// Called by the harness when the program completes. Frontend gets a
    /// chance to print a wrap-up message or close a socket.
    public func didEnd(error: Error?) async {
        await frontend.didEnd(error: error)
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
