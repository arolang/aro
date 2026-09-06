// ============================================================
// SleepAction.swift
// ARO Runtime - Sleep / Delay Action (ARO-0054)
// ============================================================

import Foundation
import AROParser

/// Suspends the current feature set for a specified duration without
/// blocking the event loop.
///
/// Because `Task.sleep` is cooperative, only the current Swift Task is
/// suspended. The thread is returned to the pool and other concurrent
/// feature sets (e.g., parallel HTTP request handlers) continue running
/// freely. Two simultaneous requests each carrying a `Sleep` statement
/// will sleep in parallel — their durations do **not** add up.
///
/// ## Syntax
/// ```aro
/// (* Literal duration — bare numbers are SECONDS *)
/// Sleep the <pause> for 30 seconds.
/// Sleep the <pause> for 500 milliseconds.
///
/// (* Suffix units, spaced or not (GitLab #502) *)
/// Sleep the <pause> for 300ms.
/// Sleep the <pause> for 1.5s.
/// Sleep the <pause> for 2m.
///
/// (* Variable duration *)
/// Sleep the <pause> for <reset-at> seconds.
///
/// (* Alternative preposition *)
/// Sleep the <pause> with 5.
/// ```
///
/// ## Result
/// Binds a dictionary `{ slept: N }` (where N is the duration in whole
/// seconds, or milliseconds when the `ms`/`milliseconds` unit is used)
/// to the result variable.
///
/// ## Supported time units (via `object.base`)
/// The vocabulary is `DurationUnitCatalog` (AROParser) — the same table
/// the parser and the check-time lint read, so the three cannot drift:
/// - `second`, `seconds`, `s`            → ×1
/// - `minute`, `minutes`, `min`, `m`     → ×60
/// - `hour`, `hours`, `h`                → ×3600
/// - `millisecond`, `milliseconds`, `ms` → ×0.001
/// - *(no unit, numeric literal only)*   → ×1 (treated as seconds)
///
/// A bare unitless literal above 60 draws an `aro check` warning
/// (GitLab #502): `Sleep … with 300.` sleeps five minutes, which reads
/// like milliseconds to anyone from ecosystems where it would be.
public struct SleepAction: ActionImplementation {
    public static let role: ActionRole = .own
    public static let verbs: Set<String> = ["sleep", "delay", "pause"]
    public static let validPrepositions: Set<Preposition> = [.for, .with]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {

        // Resolve the numeric duration.
        // Parser places the literal/expression value into _for_, _with_,
        // _expression_, or _literal_ depending on syntax; try each in order.
        let rawValue: Double
        if let v = context.resolveAny("_for_") as? Int {
            rawValue = Double(v)
        } else if let v = context.resolveAny("_for_") as? Double {
            rawValue = v
        } else if let v = context.resolveAny("_with_") as? Int {
            rawValue = Double(v)
        } else if let v = context.resolveAny("_with_") as? Double {
            rawValue = v
        } else if let v = context.resolveAny("_expression_") as? Int {
            rawValue = Double(v)
        } else if let v = context.resolveAny("_expression_") as? Double {
            rawValue = v
        } else if let v = context.resolveAny("_literal_") as? Int {
            rawValue = Double(v)
        } else if let v = context.resolveAny("_literal_") as? Double {
            rawValue = v
        } else if let v = context.resolveAny(object.base) as? Int {
            // Variable duration: `Sleep the <pause> for <reset-at> seconds.`
            rawValue = Double(v)
        } else if let v = context.resolveAny(object.base) as? Double {
            rawValue = v
        } else if let v = context.resolveAny(object.base) as? String, let parsed = Double(v) {
            rawValue = parsed
        } else {
            rawValue = 1.0
        }

        // Apply the time-unit multiplier carried in object.base.
        // When the parser sees "for 30 seconds" (or "for 300ms" — the
        // suffix lexes as literal + identifier), the unit word becomes
        // object.base. The vocabulary is DurationUnitCatalog, shared
        // with the parser and the check-time lint (GitLab #502).
        let multiplier = DurationUnitCatalog.multiplier(for: object.base) ?? 1.0
        let durationSeconds = rawValue * multiplier

        // Cooperative sleep — suspends this Task only; the thread is released
        // so other concurrent Tasks (HTTP handlers, event handlers) run freely.
        try? await Task.sleep(nanoseconds: UInt64(max(0, durationSeconds) * 1_000_000_000))

        // Bind result: { slept: N } where N mirrors the raw value provided
        // (e.g., 30 for "30 seconds", 500 for "500 milliseconds").
        let sleptValue = Int(rawValue)
        let resultDict: [String: any Sendable] = ["slept": sleptValue]
        context.bind(result.base, value: resultDict)
        return resultDict
    }
}
