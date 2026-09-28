// ============================================================
// AROValueKey.swift
// ARO Runtime — a hashable stand-in for a runtime value
// (GitLab #712)
// ============================================================
//
// `unique`, `intersect`, `difference`, `union` and
// `symmetric-difference` all have to answer "have I seen this
// value before?" over `[any Sendable]`, which is not `Hashable`.
// Both of them answered it by rendering each element to a string:
// `unique` ran `JSONSerialization` with `.sortedKeys` per element,
// the set operations built a recursive `String(describing:)`.
//
// So `unique` over 100 000 records serialised 100 000 JSON
// documents, and `intersect` built string keys for both operands
// — allocation and formatting work proportional to the data, for
// a question that is a hash lookup.
//
// This is that hash lookup. The value is walked once and turned
// into a `Hashable` case tree; no text is produced at any point.
//
// ## What counts as the same value
//
// The rule is `AROValueEquality`'s, which is the language's:
//
//   - numbers compare across `Int` and `Double`, so `1` and `1.0`
//     are one element;
//   - `Bool` is checked before the numeric cases, so `true` is
//     not `1`;
//   - a string is never a number, so `"1"` and `1` are two
//     elements.
//
// The last of those is a change for the set operations, which
// keyed on `String(describing:)` and therefore made `"1"`, `1`
// and `true` collide with `"1"`, `"1"` and `"true"` respectively
// — a list of strings could intersect a list of integers.
// `unique` already had this rule.
//
// A value of a type the runtime does not model falls back to
// `String(describing:)`, under its own case, so it can still be
// deduplicated and can never collide with a modelled value.

import Foundation

/// A runtime value, reduced to something a `Set` or `Dictionary` can hold.
public enum AROValueKey: Hashable, Sendable {
    case null
    case bool(Bool)
    /// `Int`, `Double` and the other numeric types all land here, so the
    /// numeric comparison is the language's rather than Swift's.
    case number(Double)
    case string(String)
    case list([AROValueKey])
    case record([String: AROValueKey])
    /// Anything the cases above do not model, rendered once.
    case opaque(String)

    /// The key for one runtime value.
    public init(_ value: any Sendable) {
        // Bool first: `Bool` is not an `Int` in Swift, but writing the numeric
        // cases first and relying on that is how the two get confused when a
        // value arrives boxed through `NSNumber` on Darwin.
        if let bool = value as? Bool { self = .bool(bool); return }
        if let int = value as? Int { self = .number(Double(int)); return }
        if let double = value as? Double { self = .number(double); return }
        if let string = value as? String { self = .string(string); return }
        if let array = value as? [any Sendable] {
            self = .list(array.map { AROValueKey($0) })
            return
        }
        if let dict = value as? [String: any Sendable] {
            self = .record(dict.mapValues { AROValueKey($0) })
            return
        }
        if let int64 = value as? Int64 { self = .number(Double(int64)); return }
        if let float = value as? Float { self = .number(Double(float)); return }
        if value is NSNull { self = .null; return }
        self = .opaque(String(describing: value))
    }
}
