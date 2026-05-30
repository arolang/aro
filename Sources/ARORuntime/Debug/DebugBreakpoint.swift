// ============================================================
// DebugBreakpoint.swift
// ARO Runtime - Debug Breakpoints
// ============================================================
//
// Phase 1: location and verb breakpoints. Phase 3 (issue #229) extends
// this with conditional, event, repository, force-slow, and HTTP-path
// breakpoints. The enum cases are intentionally additive — new variants
// can be added without breaking existing frontends.

import Foundation

/// A breakpoint that pauses execution when matched.
///
/// Equality on the *kind* fields keeps the breakpoint set deduplicated; the
/// optional `id` is assigned by the controller and is informational only.
public enum DebugBreakpoint: Sendable, Hashable {
    /// Pause when a statement starts at the given file + line. `file` is the
    /// basename (e.g. `users.aro`); matching is on suffix so absolute and
    /// relative paths both work.
    case location(file: String, line: Int)

    /// Pause when the next statement uses the given verb (e.g. `Emit`).
    case verb(String)

    /// Pause at the given file + line only when `predicate` evaluates to a
    /// truthy value against the current symbol table. `predicate` is raw
    /// ARO expression source compiled lazily by the controller.
    case conditionalLocation(file: String, line: Int, predicate: String)

    /// Pause when an event with the given name is about to be published.
    case event(String)

    /// Pause on the first run-time error before the error message is built.
    /// Phase 3 wires this on caught exceptions in the statement dispatcher.
    case errorAny

    public var description: String {
        switch self {
        case .location(let file, let line):
            return "\(file):\(line)"
        case .verb(let v):
            return "verb \(v)"
        case .conditionalLocation(let file, let line, let pred):
            return "\(file):\(line) if \(pred)"
        case .event(let name):
            return "event \(name)"
        case .errorAny:
            return "any error"
        }
    }
}
