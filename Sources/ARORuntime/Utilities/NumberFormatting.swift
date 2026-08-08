// ============================================================
// NumberFormatting.swift
// ARO Runtime - Numeric rendering for human-facing output
// ============================================================

import Foundation

/// Renders numbers for human-facing output (console, `Return` bodies, string
/// coercion).
///
/// Every `Double` used to be formatted with a hardcoded `"%.2f"`, so `Log <pi>`
/// printed `3.14` for `3.14159265` and `1.0 / 3.0` printed `0.33` — with no
/// indication that anything had been dropped (GitLab #474). Two decimals is a
/// currency convention that had been applied to the general numeric case.
///
/// ## Why 15 significant digits and not shortest-round-trip
///
/// The obvious replacement is Swift's default description, the shortest string
/// that round-trips back to the same `Double`. It is exact, but it surfaces
/// binary floating-point artifacts in ordinary arithmetic:
///
///     0.1 + 0.2   ->  0.30000000000000004
///     0.7 * 3     ->  2.0999999999999996
///     1.1 + 2.2   ->  3.3000000000000003
///
/// For a language whose purpose is expressing business features, that is the
/// wrong default: the reader's question is "what is the total", not "how does
/// IEEE 754 represent it". So output is rendered at 15 significant digits.
///
/// 15 is not arbitrary — it is `DBL_DIG`, the largest precision at which
/// decimal → `Double` → decimal is *guaranteed* to round-trip. Any decimal a user
/// could have typed with 15 or fewer significant digits comes back unchanged;
/// only artifacts introduced by the arithmetic itself are absorbed.
///
/// The trade-off runs the other way: `Double` → decimal → `Double` needs up to 17
/// digits, so a value carrying more than 15 significant digits displays rounded
/// and two very close Doubles can print identically. That is a display choice, not
/// a change to the arithmetic — the stored value is untouched, and the JSON path
/// (`Write`, HTTP response bodies) serialises at full precision, so nothing is
/// lost where it matters.
///
/// 16 digits was considered and rejected: it also yields `0.3` for `0.1 + 0.2`,
/// but reintroduces `9.95` → `9.949999999999999`.
enum AroNumberFormatting {

    /// Significant digits for human-facing output. `DBL_DIG` — see the type note.
    private static let significantDigits = 15

    /// `value` rendered for a human reader.
    ///
    /// - Whole values render without a fractional part: `3.0` → `"3"`.
    /// - Everything else uses 15 significant digits with trailing zeros removed:
    ///   `0.1 + 0.2` → `"0.3"`, `1.0 / 3.0` → `"0.333333333333333"`.
    /// - Non-finite values get readable names rather than `inf` / `nan`.
    static func string(for value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }

        // Whole values first, so large magnitudes render in full rather than as
        // exponent notation: 1e16 is "10000000000000000", not "1e+16".
        //
        // `Int(exactly:)` rather than `Int(_:)`: the latter traps for magnitudes
        // outside Int's range, so `1e21` would crash the process on a value that
        // is merely large. Out-of-range values fall through below.
        if value == value.rounded(), let exact = Int(exactly: value.rounded()) {
            return String(exact)
        }

        // `%g` already strips trailing zeros, so 3.5 stays "3.5" rather than
        // becoming "3.50000000000000".
        return String(format: "%.\(significantDigits)g", value)
    }
}
