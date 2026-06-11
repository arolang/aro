// ============================================================
// DebuggerState.swift
// SOLARO — debugger + execution snapshot extracted from
// WorkspaceController (#306)
// ============================================================
//
// The fields here used to live as flat properties on both
// `ConsoleProcess` and `WorkspaceController`. Bundling them into
// a single value type makes the ownership model explicit: the
// `ConsoleProcess` is the *session* — the active aro-run or
// aro-debug subprocess — and `debuggerState` is the snapshot it
// publishes. The controller still carries a mirror so SwiftUI
// views that observe the controller continue to update, but the
// session is the source of truth.
//
// All fields are value types, so the @Observable macro on the
// owning classes tracks `\.debuggerState` as a single stored
// property — mutations to inner fields propagate via Swift's
// value semantics without explicit `withMutation` calls per
// field.

import Foundation

/// Bundle of runtime state a debugger / running program produces.
/// Stored as one struct on both `ConsoleProcess` (the producer)
/// and `WorkspaceController` (the SwiftUI subscriber). Equatable
/// so onChange-style observers can short-circuit unchanged
/// snapshots.
struct DebuggerState: Equatable {
    /// 1-indexed source line of the most recent debugger pause.
    var pausedLine: Int?

    /// Symbols visible at the most recent pause. Cleared on
    /// continue / step / next / finish.
    var pauseSymbols: [String: ConsoleProcess.SymbolValue] = [:]

    /// Wall-clock time each source line was most recently
    /// executed. Drives the canvas "executing now" pulse.
    var lastExecutedAt: [Int: Date] = [:]

    /// Per feature set name, when it was last seen running.
    /// Drives the container-level glow.
    var lastExecutedAtPerFeatureSet: [String: Date] = [:]

    /// Source line → runtime error message. Paints the red
    /// border + tooltip on the failing canvas node.
    var errorLines: [Int: String] = [:]

    /// PASS/FAIL outcome per test feature-set name.
    var testResults: [String: TestNodeResult] = [:]

    /// Monotonic tick incremented on each lastExecutedAt update
    /// so TimelineView-driven animations keep scheduling even
    /// when the same line fires twice in a row.
    var executionTick: UInt64 = 0
}
