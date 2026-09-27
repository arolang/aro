// ============================================================
// AROVersionChecker.swift
// AROVersion — does this ARO satisfy a plugin's `aro-version`?
// GitLab #883
// ============================================================
//
// This lives in `AROVersion` — a leaf module with no dependencies — because
// three places ask the question and they must agree: `aro add` refuses an
// incompatible plugin at install, the plugin loader warns at load, and
// `aro check` reports it.
//
// It used to live in `AROPackageManager`, which `ARORuntime` cannot depend
// on, so the loader carried a second implementation of semver constraint
// matching. Two implementations of "does 1.3.0 satisfy ^1.2.0" is the shape
// of bug this project has fixed more than once (twelve HTTP status names
// against five, two role taxonomies disagreeing on 25 verbs): they do not
// diverge on the common cases, they diverge on the edges, and the edge is
// where somebody's plugin stops loading for no visible reason.

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
    /// Does the **running ARO** satisfy a plugin's `aro-version`?
    ///
    /// Distinct from `satisfies` because the two callers ask different
    /// questions about a non-semver string (GitLab #883). Here it is a
    /// development build: `AROVersion.version` is the literal `"dev"` for any
    /// un-stamped local build — the release pipeline overwrites it with the
    /// tag — and `"dev"` parses to no semver components, so every `>=`
    /// against it was false. `aro add` therefore refused **every** plugin
    /// declaring an `aro-version` when run from a `swift build`, which is
    /// every developer's machine, telling them the plugin needed a version
    /// of ARO they were arguably already past.
    ///
    /// For `DependencyResolver`, a non-semver string is a *branch or tag ref*
    /// — `main`, `1.0.0-beta` — which must match itself and nothing else. It
    /// keeps `satisfies`.
    ///
    /// The plugin loader's own copy of this logic had the development-build
    /// rule and the installer's did not, which is what made having two copies
    /// expensive rather than merely untidy.
    public static func runningVersionSatisfies(_ version: String, constraint: String) -> Bool {
        guard isSemver(version) else { return true }
        return satisfies(version: version, constraint: constraint)
    }

    public static func satisfies(version: String, constraint: String) -> Bool {
        // Strip leading 'v' and any build metadata / pre-release from the
        // running version so comparisons work on plain semver triples.
        let clean = stripBuildMetadata(version)

        // A constraint may be a space-separated list of clauses — all must hold.
        let clauses = constraint.split(separator: " ").map { String($0).trimmingCharacters(in: .whitespaces) }
        return clauses.allSatisfy { clause in
            satisfiesSingle(version: clean, raw: version, clause: clause)
        }
    }

    // MARK: - Private

    /// Evaluate one constraint clause against a cleaned version.
    ///
    /// `raw` is the version as it was given. Only the exact-match branch looks at
    /// it — see there.
    private static func satisfiesSingle(version: String, raw: String, clause: String) -> Bool {
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
            // Exact match. The strings are compared as written first, because a
            // dependency's `ref:` is not always a semver triple — it can be a
            // pre-release ("1.0.0-beta"), a branch ("main") or a commit hash, and
            // metadata-stripping reduces the two sides to different things
            // ("1.0.0-beta" to "1.0.0", the clause untouched). The dependency
            // resolver's own comparator did raw equality here before it was
            // folded into this one (GitLab #734), and it must keep matching.
            if raw == clause { return true }
            let normalized = clause.hasPrefix("v") ? String(clause.dropFirst(1)) : clause
            return raw == normalized || version == normalized
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

    /// Whether `version` looks like a semver triple at all.
    ///
    /// A git SHA from `git describe --always`, or the `"dev"` sentinel, is
    /// not one — and is a development build rather than an old release.
    private static func isSemver(_ version: String) -> Bool {
        let base = stripBuildMetadata(version)
        guard !base.isEmpty else { return false }
        return base.split(separator: ".").allSatisfy { Int($0) != nil }
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
