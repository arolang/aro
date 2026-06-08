// ============================================================
// PauseInfo.swift
// ARO Runtime - Debug Pause Snapshot
// ============================================================

import Foundation
import AROParser

/// Snapshot of execution state at a pause point, handed to the frontend.
///
/// Snapshots are value types so frontends can hold them across awaits
/// without worrying about racing the runtime that produced them.
public struct PauseInfo: Sendable {
    /// Why the runtime paused.
    public enum Reason: Sendable, Equatable {
        case step                          // any stepping mode wanted to pause
        case breakpoint(DebugBreakpoint)   // a registered breakpoint matched
        case entry                         // first checkpoint of a feature set
        case event(String)                 // event-bus emission about to fire
        case error(String)                 // runtime about to raise
    }

    public let reason: Reason
    public let featureSetName: String
    public let businessActivity: String
    public let file: String                 // basename of the source file
    public let line: Int
    public let column: Int
    public let statementSummary: String     // human-readable, e.g. "Emit <UserCreated: event> with <user>"
    public let verb: String?
    public let symbols: [SymbolSnapshot]    // visible bindings at this point
    /// First-class per-statement instrumentation (#282 phase 2).
    /// Populated by `DebugController.checkpoint` from monotonic
    /// timestamps + Mach task info; nil only when the platform
    /// helpers refuse to answer.
    public let metrics: PauseMetrics?

    public init(
        reason: Reason,
        featureSetName: String,
        businessActivity: String,
        file: String,
        line: Int,
        column: Int,
        statementSummary: String,
        verb: String?,
        symbols: [SymbolSnapshot],
        metrics: PauseMetrics? = nil
    ) {
        self.reason = reason
        self.featureSetName = featureSetName
        self.businessActivity = businessActivity
        self.file = file
        self.line = line
        self.column = column
        self.statementSummary = statementSummary
        self.verb = verb
        self.symbols = symbols
        self.metrics = metrics
    }
}

/// First-class per-statement instrumentation handed to the
/// frontend on every pause (#282 phase 2). Both fields are
/// best-effort: when the platform helpers refuse (e.g. running
/// under a sandbox that blocks Mach calls) the values stay at
/// zero and the frontend should treat them as "unknown" rather
/// than "actually zero."
public struct PauseMetrics: Sendable, Equatable {
    /// Elapsed wall-clock nanoseconds between this checkpoint and
    /// the previous one in the same execution.
    public let elapsedNanos: UInt64
    /// Resident memory the runtime process currently holds, in
    /// bytes. Sampled with `task_info()`.
    public let residentMemoryBytes: UInt64

    public init(elapsedNanos: UInt64, residentMemoryBytes: UInt64) {
        self.elapsedNanos = elapsedNanos
        self.residentMemoryBytes = residentMemoryBytes
    }
}

/// One symbol-table entry captured at pause time.
public struct SymbolSnapshot: Sendable {
    public let name: String
    public let typeName: String
    public let valuePreview: String   // truncated rendering, safe to print
    /// Current contents of a repository, projected to flat
    /// string-keyed rows. Nil for non-repository symbols.
    /// Lets the SOLARO repo card show a live table without
    /// having to parse `valuePreview` (see #284 step 3).
    public let records: [[String: String]]?

    public init(
        name: String,
        typeName: String,
        valuePreview: String,
        records: [[String: String]]? = nil
    ) {
        self.name = name
        self.typeName = typeName
        self.valuePreview = valuePreview
        self.records = records
    }
}
