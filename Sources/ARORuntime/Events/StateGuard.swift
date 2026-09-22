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
            let text = String(guardString).trimmingCharacters(in: .whitespaces)
            // `dedupe:` is a declaration, not a field comparison — it names the
            // payload field that identifies an event, and is read by
            // `DedupeGuard`. Reading it as a state guard would ask every event
            // for a field called "dedupe" and so match nothing.
            if DedupeGuard.field(inGuardComponent: text) != nil { continue }
            if let guard_ = StateGuard.parse(text) {
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

// MARK: - Dedupe Guard

/// A handler's declaration that it wants each event seen once, identified by
/// one field of the payload: `Handler<dedupe:url>` (ARO-0007 §3.6).
///
/// The runtime used to do this for exactly one event name — an event called
/// `CrawlPage` whose payload happened to be keyed `data` had its `url`
/// de-duplicated, and nothing else could ask for the same thing. This is that
/// behaviour with the name taken out of it: any handler of any event can
/// declare the field that identifies its events, and a handler that declares
/// nothing sees every event.
public enum DedupeGuard: Sendable {
    /// The field named by a single `dedupe:<field>` guard component.
    static func field(inGuardComponent component: String) -> String? {
        let parts = component.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "dedupe" else {
            return nil
        }
        let field = parts[1].trimmingCharacters(in: .whitespaces)
        return field.isEmpty ? nil : field
    }

    /// The payload field a business activity declares as its identity, if any.
    /// Example: `"CrawlPage Handler<dedupe:url>"` -> `"url"`.
    public static func field(in businessActivity: String) -> String? {
        guard let startIndex = businessActivity.firstIndex(of: "<"),
              let endIndex = businessActivity.firstIndex(of: ">"),
              startIndex < endIndex else {
            return nil
        }
        let content = businessActivity[businessActivity.index(after: startIndex)..<endIndex]
        for component in content.split(separator: ";") {
            if let field = field(inGuardComponent: String(component).trimmingCharacters(in: .whitespaces)) {
                return field
            }
        }
        return nil
    }

    /// The identity of one event: the named field's value, rendered as a string.
    ///
    /// `Emit` shapes a payload in more than one way — an object literal is
    /// spread across the payload, a named variable is wrapped under its own
    /// name — so the field is looked up at the top level, then one level down
    /// through a nested dictionary. Dotted paths address a nested field
    /// directly, as state guards do. A payload that does not carry the field
    /// has no identity, and such an event is never dropped.
    public static func identity(
        ofField field: String,
        in payload: [String: any Sendable]
    ) -> String? {
        if let direct = resolve(path: field, in: payload) {
            return render(direct)
        }
        for (_, value) in payload.sorted(by: { $0.key < $1.key }) {
            guard let nested = value as? [String: any Sendable],
                  let found = resolve(path: field, in: nested) else { continue }
            return render(found)
        }
        return nil
    }

    private static func resolve(path: String, in payload: [String: any Sendable]) -> (any Sendable)? {
        var current: any Sendable = payload
        for component in path.split(separator: ".") {
            guard let dict = current as? [String: any Sendable],
                  let next = dict[String(component)] else { return nil }
            current = next
        }
        return current is [String: any Sendable] ? nil : current
    }

    private static func render(_ value: any Sendable) -> String {
        if let string = value as? String { return string }
        return String(describing: value)
    }
}
