// ============================================================
// GlobMatcher.swift
// ARO Runtime - fnmatch(3) glob matching for directory listings
// ARO-0036 §6.2: List ... matching "<glob>"
// ============================================================
//
// GitLab #518. `List` had no pattern filter, so people filtered the
// listing afterwards with `Filter … contains` — substring matching, so
// `*.csv` also kept `report.csvx`. The `matching` clause needs real glob
// semantics, and the three hand-rolled glob-to-regex converters that were
// already in the tree did not have them:
//
//   * they matched case-INSENSITIVELY, so `*.md` kept `README.MD`;
//   * they passed `[` and `]` through to the regex engine unescaped in one
//     place and escaped them in another, so `[0-9].txt` meant two different
//     things depending on which code path ran;
//   * they escaped nothing else, so a literal `+` or `(` in a pattern was
//     read as a regex quantifier or group.
//
// This is now the one matcher every listing path calls.

import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Matches a directory entry's *name* against a shell glob pattern.
///
/// Semantics are POSIX `fnmatch(3)` with no flags:
/// - `*` matches any run of characters, including none;
/// - `?` matches exactly one character;
/// - `[abc]`, `[a-z]`, `[!a-z]` match one character from a set;
/// - `\` escapes the next metacharacter;
/// - everything else is literal, and matching is **case-sensitive**;
/// - the match is anchored: the whole name must be consumed.
///
/// No flags means no `FNM_PATHNAME` (irrelevant — only the last path
/// component is ever matched) and no `FNM_PERIOD`, so a leading dot is not
/// special and `*` sees dotfiles. A glob filters *entries*, so it applies to
/// directories exactly as it does to files.
public enum GlobMatcher {

    /// True when `name` matches `pattern`. An empty pattern matches everything.
    public static func matches(_ name: String, pattern: String) -> Bool {
        guard !pattern.isEmpty else { return true }
        #if canImport(Darwin) || canImport(Glibc)
        return pattern.withCString { p in
            name.withCString { n in
                fnmatch(p, n, 0) == 0
            }
        }
        #else
        return matchesPortable(name, pattern: pattern)
        #endif
    }

    /// Convenience for the optional-pattern call sites: a `nil` or empty
    /// pattern keeps every entry.
    public static func matches(_ name: String, pattern: String?) -> Bool {
        guard let pattern = pattern else { return true }
        return matches(name, pattern: pattern)
    }

    /// Pure-Swift `fnmatch(3)`, used where libc has none (Windows).
    ///
    /// Kept `public` so the test suite can hold it against the platform
    /// `fnmatch` on the platforms that have one — two implementations of the
    /// same contract drift the moment nothing compares them.
    public static func matchesPortable(_ name: String, pattern: String) -> Bool {
        let n = Array(name), p = Array(pattern)
        // Iterative backtracking over `*`: O(n·m) worst case, no recursion,
        // so a pathological pattern cannot blow the stack.
        var ni = 0, pi = 0
        var starPi = -1, starNi = 0

        while ni < n.count {
            if pi < p.count, let advance = matchOne(p, &pi, n[ni]), advance {
                ni += 1
            } else if pi < p.count, p[pi] == "*" {
                starPi = pi
                pi += 1
                starNi = ni
            } else if starPi >= 0 {
                // Backtrack: let the last `*` swallow one more character.
                pi = starPi + 1
                starNi += 1
                ni = starNi
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    /// Tries to match a single character at `p[pi]`. Returns nil when the
    /// element is not a single-character matcher (i.e. it is `*`), true/false
    /// for match/no-match; `pi` is advanced past the element only on a match.
    private static func matchOne(_ p: [Character], _ pi: inout Int, _ ch: Character) -> Bool? {
        switch p[pi] {
        case "*":
            return nil
        case "?":
            pi += 1
            return true
        case "[":
            guard let (set, negated, next) = parseBracket(p, from: pi) else {
                // Unterminated `[` is a literal `[`, as in fnmatch(3).
                if ch == "[" { pi += 1; return true }
                return false
            }
            let inSet = set.contains { $0.contains(ch) }
            guard inSet != negated else { return false }
            pi = next
            return true
        case "\\" where pi + 1 < p.count:
            guard ch == p[pi + 1] else { return false }
            pi += 2
            return true
        default:
            guard ch == p[pi] else { return false }
            pi += 1
            return true
        }
    }

    /// Parses `[...]` starting at `start`, returning the ranges it accepts,
    /// whether it is negated, and the index just past the closing `]`.
    private static func parseBracket(
        _ p: [Character], from start: Int
    ) -> (ranges: [ClosedRange<Character>], negated: Bool, next: Int)? {
        var i = start + 1
        var negated = false
        if i < p.count, p[i] == "!" || p[i] == "^" { negated = true; i += 1 }
        var ranges: [ClosedRange<Character>] = []
        // A `]` in the first position is a literal `]`, as in fnmatch(3).
        var first = true
        while i < p.count {
            if p[i] == "]" && !first { return (ranges, negated, i + 1) }
            first = false
            let lo = p[i]
            if i + 2 < p.count, p[i + 1] == "-", p[i + 2] != "]" {
                let hi = p[i + 2]
                if lo <= hi { ranges.append(lo...hi) }
                i += 3
            } else {
                ranges.append(lo...lo)
                i += 1
            }
        }
        return nil  // unterminated
    }
}
