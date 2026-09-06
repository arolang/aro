// ============================================================
// DurationUnitCatalog.swift
// AROParser — the duration units a Sleep operand may carry
// ============================================================
//
// GitLab #502. `Sleep the <pause> with 300.` sleeps five minutes:
// two prepositions, no unit in the syntax, and a large bare number
// reads like milliseconds to anyone arriving from ecosystems where
// it would be. The failure mode is a mysterious hang — the least
// debuggable symptom there is.
//
// The fix is a unit vocabulary shared by everything that touches a
// Sleep duration:
//
//   - the parser consumes a unit word after a duration expression
//     (`for 300ms`, `for 2s`, `for 2 minutes`) and stores it as the
//     object base,
//   - `SleepAction` maps that base to a seconds multiplier,
//   - `CodeQualityValidator` warns on a bare literal over
//     `bareLiteralWarningThreshold` seconds, and must NOT warn when
//     a unit is spelled out.
//
// One table, three readers — the same arrangement as
// `ComputeQualifierCatalog` vs. `ComputeAction.builtInQualifiers`,
// and for the same reason: two hand-maintained copies drift.
// `SleepActionTests` asserts the runtime resolves every spelling
// listed here.
//
// The short suffixes follow ARO-0041 §2.3 (`s` seconds, `m` minutes,
// `h` hours); `ms` extends the vocabulary downward because sleeps,
// unlike date offsets, are routinely sub-second. Suffixes bind with
// or without a space — `300ms` lexes as the literal `300` followed
// by the identifier `ms`, so both spellings arrive here identically.

/// The unit words accepted after a duration operand, and their
/// multipliers to seconds.
public enum DurationUnitCatalog {

    /// Multiplier to seconds for every accepted unit spelling.
    public static let multipliers: [String: Double] = [
        "millisecond": 0.001, "milliseconds": 0.001, "ms": 0.001,
        "second": 1, "seconds": 1, "s": 1,
        "minute": 60, "minutes": 60, "min": 60, "m": 60,
        "hour": 3600, "hours": 3600, "h": 3600,
    ]

    /// Every accepted unit word. The parser consults this to decide
    /// whether the identifier after a duration expression is a unit.
    public static let unitNames: Set<String> = Set(multipliers.keys)

    /// True when `word` is a duration unit (exact, lowercase match —
    /// the same way the lexer delivers identifiers).
    public static func isUnit(_ word: String) -> Bool {
        unitNames.contains(word)
    }

    /// The seconds multiplier for a unit word, or nil when the word
    /// is not a unit.
    public static func multiplier(for unit: String) -> Double? {
        multipliers[unit]
    }

    /// A bare, unitless Sleep literal above this many seconds draws a
    /// check-time warning (GitLab #502): beyond a minute, "I meant
    /// milliseconds" becomes the likelier reading of the source.
    public static let bareLiteralWarningThreshold: Double = 60
}
