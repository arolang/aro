// ============================================================
// Extractable.swift
// ARO Runtime - Property extraction protocol (Issue #161)
// ============================================================

/// Protocol for runtime types that expose named properties to the Extract action.
///
/// Conforming types provide a single `property(_ name:)` entry point. This
/// eliminates the per-type `as?` cast chains in `ExtractAction.extractProperty`
/// and makes adding a new extractable type a one-line conformance declaration.
///
/// ## Adding a new extractable type
/// 1. Implement `func property(_ name: String) -> (any Sendable)?` on your type.
/// 2. Add `extension MyType: Extractable {}` — no changes to `ExtractAction`.
public protocol Extractable: Sendable {
    /// Return the value of the named property, or `nil` if the property
    /// does not exist on this type.
    func property(_ name: String) -> (any Sendable)?
}

// MARK: - Conformances
//
// The property(_:) methods already exist on all four types with exactly the
// right signature — these extensions add zero new code.

extension ARODate:       Extractable {}
extension ARODateRange:  Extractable {}
extension ARORecurrence: Extractable {}
extension DateDistance:  Extractable {}
