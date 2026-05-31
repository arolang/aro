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

    public init(
        reason: Reason,
        featureSetName: String,
        businessActivity: String,
        file: String,
        line: Int,
        column: Int,
        statementSummary: String,
        verb: String?,
        symbols: [SymbolSnapshot]
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
    }
}

/// One symbol-table entry captured at pause time.
public struct SymbolSnapshot: Sendable {
    public let name: String
    public let typeName: String
    public let valuePreview: String   // truncated rendering, safe to print

    public init(name: String, typeName: String, valuePreview: String) {
        self.name = name
        self.typeName = typeName
        self.valuePreview = valuePreview
    }
}
