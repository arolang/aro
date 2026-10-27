// ============================================================
// RangeValue.swift
// ARO-0089 — the one place range arithmetic lives
// ============================================================
//
// `1->10` is an expression, so it is evaluated in two places:
// `ExpressionEvaluator` under `aro run`, and `evaluateExpressionJSON` in the
// C-ABI bridge under `aro build`. Both call this type rather than counting for
// themselves — the two modes disagreeing about what `1->10` contains is the
// divergence class GitLab #838 and #903 are about, and a shared
// `count`/`elements` is how it is avoided here (GitLab #546).
//
// A range materialises everywhere except the `for each` collection slot,
// which iterates it from the two endpoints and therefore costs O(1) memory
// in both modes. See ARO-0089 §3.3 and its "Implementation status" section.

import Foundation

/// An ascending span of integers — ARO-0089 §3.
///
/// **Both endpoints are included**, always: `1->10` has ten elements. There is
/// no exclusive-bound form to carry a flag for (§2.1), so an exclusive upper
/// bound is `1->(<n> - 1)`, written out where a reader can see it.
///
/// A descending span (`10->1`) is **empty**, not reversed and not an error
/// (§3.2), so a computed pair of endpoints degrades to "nothing to do" rather
/// than running backwards.
public struct AROIntRange: Sendable, Equatable, CustomStringConvertible {
    public let lower: Int
    public let upper: Int

    public init(lower: Int, upper: Int) {
        self.lower = lower
        self.upper = upper
    }

    /// `max(0, upper - lower + 1)` (§3.3).
    ///
    /// Arithmetic, not a traversal — which is what makes `length` free on a
    /// range the consumer has not already materialised.
    public var count: Int {
        // Clamped before the addition: `Int.min->Int.max` overflows a plain
        // `upper - lower + 1`, and a range nobody can iterate to the end of
        // is not worth a trap.
        guard upper >= lower else { return 0 }
        let span = upper.subtractingReportingOverflow(lower)
        if span.overflow { return Int.max }
        let inclusive = span.partialValue.addingReportingOverflow(1)
        return inclusive.overflow ? Int.max : inclusive.partialValue
    }

    public var isEmpty: Bool { count == 0 }

    /// The elements, in order. O(n) — the materialising path.
    public var elements: [Int] {
        guard count > 0 else { return [] }
        return Array(lower...(lower + count - 1))
    }

    /// The elements boxed as the runtime's value type.
    public var sendableElements: [any Sendable] {
        elements.map { $0 as any Sendable }
    }

    /// Iterate without materialising: the loop driver both modes use.
    public func forEachElement(_ body: (Int) throws -> Void) rethrows {
        guard count > 0 else { return }
        for i in lower...(lower + count - 1) { try body(i) }
    }

    /// The element at `index`, or nil past the end. The compiled for-each
    /// walks a range through this (`aro_array_get_next`), so iteration there
    /// costs two registers rather than an allocation.
    public func element(at index: Int) -> Int? {
        guard index >= 0, index < count else { return nil }
        return lower + index
    }

    /// `1->10` — the source spelling, used in diagnostics.
    public var description: String {
        "\(lower)->\(upper)"
    }
}
