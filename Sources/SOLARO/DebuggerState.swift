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

    /// Wall-clock time each source position was most recently
    /// executed. Drives the canvas "executing now" pulse.
    var lastExecutedAt: [SourceRef: Date] = [:]

    /// Per feature set name, when it was last seen running.
    /// Drives the container-level glow.
    var lastExecutedAtPerFeatureSet: [String: Date] = [:]

    /// Source position → runtime error message. Paints the red
    /// border + tooltip on the failing canvas node.
    var errorLines: [SourceRef: String] = [:]

    /// PASS/FAIL outcome per test feature-set name.
    var testResults: [String: TestNodeResult] = [:]

    /// Monotonic tick incremented on each lastExecutedAt update
    /// so TimelineView-driven animations keep scheduling even
    /// when the same line fires twice in a row.
    var executionTick: UInt64 = 0

    /// Whether a program is running right now (#765).
    ///
    /// The canvas animates off `executionTick` alone, which is enough
    /// when a redraw is what you want. The Project Map's pulses travel
    /// *between* records, so it needs to know when to keep asking for
    /// frames and when to stop — hence a flag rather than a counter.
    var isRunning: Bool = false
}


/// Where the runtime said something happened: which file, and which line
/// in it.
///
/// The line alone is not enough. `lastExecutedAt` and `errorLines` used to be
/// keyed by `Int`, so in a multi-file project — the documented norm of
/// `users.aro`, `orders.aro`, `events.aro` — statement 12 of `orders.aro`
/// firing pulsed line 12 of whichever file happened to be open, and a red
/// error border could appear in a file that never ran (GitLab #824 is the
/// same shape in `aro check`; this is #742).
///
/// `file` is the basename the runtime reports (`"main.aro"`), because that is
/// what `DebugEventLog` writes and what `aro debug` matches breakpoints on.
/// An empty string means the record carried no file — older recordings, and
/// some event kinds — and matches every file so those keep behaving as they
/// did rather than silently vanishing from the canvas.
struct SourceRef: Hashable, Sendable {
    /// Basename, e.g. `"orders.aro"`. Empty when unknown.
    let file: String
    /// 1-indexed.
    let line: Int

    init(file: String?, line: Int) {
        // Normalise: the runtime writes a basename, but a path would still
        // match the right file this way.
        self.file = (file?.split(separator: "/").last).map(String.init) ?? ""
        self.line = line
    }

    /// Does this position belong to `basename`?
    func matches(file basename: String) -> Bool {
        file.isEmpty || file == basename
    }
}

extension Dictionary where Key == SourceRef {
    /// The entries belonging to one file, keyed by line, for a view that
    /// renders that file alone.
    ///
    /// Entries with no file are included: a record that did not say where it
    /// happened is better shown than dropped.
    func inFile(_ url: URL?) -> [Int: Value] {
        let basename = url?.lastPathComponent ?? ""
        var projected: [Int: Value] = [:]
        for (ref, value) in self where basename.isEmpty || ref.matches(file: basename) {
            projected[ref.line] = value
        }
        return projected
    }
}
