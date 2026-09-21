// ============================================================
// EditDistance.swift
// ARO Parser - Levenshtein distance for "did you mean" hints
// ============================================================

import Foundation

/// Levenshtein distance, shared by every "did you mean" diagnostic.
///
/// The parser, the runtime and the language server all rank candidate names
/// by edit distance. They each used to carry their own copy of the same
/// algorithm — four two-row variants and one full-matrix variant, all
/// computing the same number — so a suggestion could only be tuned in one
/// place at a time. There is one implementation now; the thresholds and the
/// ordering stay with each caller, because those differ on purpose.
public enum EditDistance {
    /// Plain Levenshtein distance over `Character`s, two-row variant.
    ///
    /// Insertion, deletion and substitution each cost 1. Comparison is
    /// case-sensitive: callers that want a case-insensitive match lowercase
    /// both sides first, as they always have.
    public static func levenshtein(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }

        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)

        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                let substitution = previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1)
                current[j] = Swift.min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            swap(&previous, &current)
        }
        return previous[y.count]
    }
}
