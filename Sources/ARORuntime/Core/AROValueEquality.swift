// ============================================================
// AROValueEquality.swift
// ARO Runtime — one deep comparison for ARO values
// GitLab #640
// ============================================================
//
// `any Sendable` has no `==`, so every place that needs to compare two ARO
// values grew its own. `RepositoryStorage` wrote a careful recursive one;
// `match` compared `String(describing:)` of the two sides, which is not a
// comparison at all — Swift's `Dictionary` description has no defined order,
// so `match <obj> { case { a: 1, b: 2 } … }` matched or failed depending on
// how the hash seed came out that run, and `[1, 2]` never matched `[1.0, 2.0]`.
//
// One implementation, so the two cannot disagree again.

import Foundation

public enum AROValueEquality {

    /// Structural equality for two ARO values.
    ///
    /// Numbers compare across `Int`/`Double` — `1` and `1.0` are the same
    /// number, and which of the two a value is depends on whether it came from
    /// a literal, JSON, a CSV column or an arithmetic result, none of which the
    /// author chose. Everything else compares within its own type.
    ///
    /// An unrecognised type is **not equal**, deliberately. Falling back to
    /// `String(describing:)` is what produced the bug this file exists to fix:
    /// it invents equality between things that merely print alike, and its
    /// answer changes with the Swift version.
    public static func equal(_ lhs: any Sendable, _ rhs: any Sendable) -> Bool {
        if let l = lhs as? String,  let r = rhs as? String  { return l == r }
        if let l = lhs as? Bool,    let r = rhs as? Bool    { return l == r }
        if let l = lhs as? UUID,    let r = rhs as? UUID    { return l == r }
        if let l = lhs as? Date,    let r = rhs as? Date    { return l == r }

        // Numbers, across Int/Double. Checked after Bool so `true` does not
        // compare equal to `1`.
        if let l = numeric(lhs), let r = numeric(rhs) { return l == r }

        if let l = lhs as? [String: any Sendable],
           let r = rhs as? [String: any Sendable] {
            guard l.count == r.count else { return false }
            for (key, lhsValue) in l {
                guard let rhsValue = r[key], equal(lhsValue, rhsValue) else { return false }
            }
            return true
        }

        if let l = lhs as? [any Sendable], let r = rhs as? [any Sendable] {
            guard l.count == r.count else { return false }
            return zip(l, r).allSatisfy { equal($0.0, $0.1) }
        }

        return false
    }

    /// A value as a number, when it is one. `Bool` is excluded by the caller.
    private static func numeric(_ value: any Sendable) -> Double? {
        if let i = value as? Int    { return Double(i) }
        if let d = value as? Double { return d }
        if let f = value as? Float  { return Double(f) }
        return nil
    }
}
