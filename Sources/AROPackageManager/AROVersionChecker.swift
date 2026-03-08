// ============================================================
// AROVersionChecker.swift
// ARO Package Manager - ARO Version Constraint Checking
// ============================================================

import Foundation

// MARK: - ARO Version Checker

/// Checks whether a running ARO version satisfies a semver constraint string.
///
/// Constraint syntax (same as npm / Cargo):
/// - `>=1.0.0`          — at least 1.0.0
/// - `<2.0.0`           — before 2.0.0
/// - `>=1.0.0 <2.0.0`  — range (space-separated, all must match)
/// - `^1.2.0`           — compatible with 1.x (same major, >= minor.patch)
/// - `~1.2.0`           — patch-compatible with 1.2.x (same major.minor)
/// - `1.2.0`            — exact match
/// - `v1.2.0`           — exact match (v prefix ignored)
public enum AROVersionChecker {

    /// Returns `true` when `version` satisfies the given `constraint`.
    ///
    /// - Parameters:
    ///   - version:    The running ARO version string (e.g. `"1.3.0"` or `"v1.3.0-dirty"`).
    ///   - constraint: A semver constraint expression (e.g. `">=1.0.0 <2.0.0"`).
    public static func satisfies(version: String, constraint: String) -> Bool {
        // Strip leading 'v' and any build metadata / pre-release from the
        // running version so comparisons work on plain semver triples.
        let clean = stripBuildMetadata(version)

        // A constraint may be a space-separated list of clauses — all must hold.
        let clauses = constraint.split(separator: " ").map { String($0).trimmingCharacters(in: .whitespaces) }
        return clauses.allSatisfy { clause in
            satisfiesSingle(version: clean, clause: clause)
        }
    }

    // MARK: - Private

    /// Evaluate one constraint clause against a cleaned version.
    private static func satisfiesSingle(version: String, clause: String) -> Bool {
        if clause.hasPrefix(">=") {
            return compare(version, String(clause.dropFirst(2))) >= 0
        } else if clause.hasPrefix("<=") {
            return compare(version, String(clause.dropFirst(2))) <= 0
        } else if clause.hasPrefix(">") {
            return compare(version, String(clause.dropFirst(1))) > 0
        } else if clause.hasPrefix("<") {
            return compare(version, String(clause.dropFirst(1))) < 0
        } else if clause.hasPrefix("^") {
            return isMajorCompatible(version, String(clause.dropFirst(1)))
        } else if clause.hasPrefix("~") {
            return isMinorCompatible(version, String(clause.dropFirst(1)))
        } else {
            // Exact match (strip leading 'v' from constraint too)
            let normalized = clause.hasPrefix("v") ? String(clause.dropFirst(1)) : clause
            return version == normalized
        }
    }

    /// Semver comparison: returns negative / zero / positive
    private static func compare(_ v1: String, _ v2: String) -> Int {
        let p1 = semverParts(v1)
        let p2 = semverParts(v2)
        let len = max(p1.count, p2.count)
        for i in 0..<len {
            let a = i < p1.count ? p1[i] : 0
            let b = i < p2.count ? p2[i] : 0
            if a != b { return a - b }
        }
        return 0
    }

    /// `^x.y.z` — same major, installed >= required
    private static func isMajorCompatible(_ installed: String, _ required: String) -> Bool {
        let i = semverParts(installed)
        let r = semverParts(required)
        guard !i.isEmpty, !r.isEmpty else { return false }
        return i[0] == r[0] && compare(installed, required) >= 0
    }

    /// `~x.y.z` — same major.minor, installed >= required
    private static func isMinorCompatible(_ installed: String, _ required: String) -> Bool {
        let i = semverParts(installed)
        let r = semverParts(required)
        guard i.count >= 2, r.count >= 2 else { return false }
        return i[0] == r[0] && i[1] == r[1] && compare(installed, required) >= 0
    }

    /// Parse a semver string into integer components (ignores pre-release / build metadata).
    private static func semverParts(_ version: String) -> [Int] {
        // Strip leading 'v' and any pre-release / build suffix (e.g. "-dirty", "+build")
        let clean = stripBuildMetadata(version)
        return clean.split(separator: ".").prefix(3).compactMap { Int($0) }
    }

    /// Remove pre-release and build metadata suffixes, and strip a leading `v`.
    private static func stripBuildMetadata(_ version: String) -> String {
        var s = version.hasPrefix("v") ? String(version.dropFirst(1)) : version
        // Drop everything after '-' or '+'
        if let dash = s.firstIndex(of: "-") { s = String(s[..<dash]) }
        if let plus = s.firstIndex(of: "+") { s = String(s[..<plus]) }
        return s
    }
}
