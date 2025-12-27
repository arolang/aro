// ============================================================
// StateGuard.swift
// ARO Runtime - State Guard Filtering for Event Handlers
// ============================================================

import Foundation

// MARK: - State Guard

/// Represents a state guard condition parsed from a Handler business activity.
/// Guards filter events based on entity field values from the event payload.
///
/// Syntax: `<field:value>` or `<field:value1,value2>` for OR logic
///
/// Examples:
/// - `Handler<status:paid>` - matches when status equals "paid"
/// - `Handler<status:paid,shipped>` - matches when status equals "paid" OR "shipped"
/// - `Handler<entity.status:active>` - matches nested field
public struct StateGuard: Sendable {
    /// The field path to check (e.g., "status", "entity.status")
    public let fieldPath: String

    /// Valid values (OR logic - matches if field equals any value)
    public let validValues: Set<String>

    /// Parse guard from angle bracket content like "status:paid" or "status:paid,shipped"
    public static func parse(_ content: String) -> StateGuard? {
        let parts = content.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return nil }

        let fieldPath = String(parts[0]).trimmingCharacters(in: .whitespaces)
        let values = parts[1]
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespaces).lowercased() }

        guard !fieldPath.isEmpty, !values.isEmpty else { return nil }

        return StateGuard(fieldPath: fieldPath, validValues: Set(values))
    }

    /// Check if a payload matches this guard
    public func matches(payload: [String: any Sendable]) -> Bool {
        guard let fieldValue = resolveFieldPath(fieldPath, in: payload) else {
            return false
        }

        // Convert to string for comparison
        let stringValue: String
        if let str = fieldValue as? String {
            stringValue = str.lowercased()
        } else {
            stringValue = String(describing: fieldValue).lowercased()
        }

        return validValues.contains(stringValue)
    }

    /// Resolve a dot-separated field path in a payload
    private func resolveFieldPath(_ path: String, in payload: [String: any Sendable]) -> (any Sendable)? {
        let components = path.split(separator: ".")
        var current: any Sendable = payload

        for component in components {
            guard let dict = current as? [String: any Sendable],
                  let next = dict[String(component)] else {
                return nil
            }
            current = next
        }
        return current
    }
}

// MARK: - State Guard Set

/// Collection of guards with AND logic.
/// All guards must match for the set to match.
///
/// Syntax: Semicolon-separated guards within angle brackets for AND logic
/// Example: `Handler<status:paid;tier:premium>` - both must match
public struct StateGuardSet: Sendable {
    public let guards: [StateGuard]

    public init(guards: [StateGuard]) {
        self.guards = guards
    }

    /// Parse all guards from a business activity string.
    /// Example: "UserCreated Handler<status:paid;tier:premium>" -> [guard1, guard2]
    public static func parse(from businessActivity: String) -> StateGuardSet {
        var guards: [StateGuard] = []

        // Find the angle bracket content
        guard let startIndex = businessActivity.firstIndex(of: "<"),
              let endIndex = businessActivity.firstIndex(of: ">"),
              startIndex < endIndex else {
            return StateGuardSet(guards: [])
        }

        let content = String(businessActivity[businessActivity.index(after: startIndex)..<endIndex])

        // Only parse as state guard if it contains a colon (field:value format)
        // This distinguishes from StateObserver's <from_to_target> syntax
        guard content.contains(":") else {
            return StateGuardSet(guards: [])
        }

        // Split by semicolon for AND logic
        let guardStrings = content.split(separator: ";")
        for guardString in guardStrings {
            if let guard_ = StateGuard.parse(String(guardString).trimmingCharacters(in: .whitespaces)) {
                guards.append(guard_)
            }
        }

        return StateGuardSet(guards: guards)
    }

    /// Check if all guards match (AND logic)
    public func allMatch(payload: [String: any Sendable]) -> Bool {
        guards.allSatisfy { $0.matches(payload: payload) }
    }

    /// Returns true if no guards are defined
    public var isEmpty: Bool { guards.isEmpty }

    /// Number of guards in the set
    public var count: Int { guards.count }
}
