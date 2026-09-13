// ============================================================
// ComputeFormatPatternTests.swift
// AROCLI — `Compute … format … with "pattern"` (GitLab #577)
// ============================================================
//
// `opFormat` read its pattern from `_expression_` — which is the statement's
// *object*, `<date>`, not its `with` clause. The `as? String` cast therefore
// failed on every call and the code fell back to `DateFormatPattern.fullDate`,
// so whatever pattern you asked for you got "January 15, 2026". No
// diagnostic; `aro check` green.
//
// `opDistance` reads `_to_` and `opIntersect` reads `_with_`; `format` was the
// outlier among the clause-taking qualifiers.

import Testing
import Foundation
@testable import AROCLI

@Suite("Compute format honours its pattern (GitLab #577)", .serialized)
struct ComputeFormatPatternTests {

    /// Formats the issue's fixed instant with `pattern`, or with none.
    private func formatted(_ pattern: String?) async -> String? {
        let session = REPLSession(suppressLogPrefix: true)
        let engine = REPLCellEngine(session: session)
        _ = await engine.executeCell(
            #"Compute the <d: date> from "2026-01-15T10:30:00Z"."#)
        let statement = pattern.map {
            "Compute the <out: format> from <d> with \"\($0)\"."
        } ?? "Compute the <out: format> from <d>."
        _ = await engine.executeCell(statement)
        return session.getVariable("out") as? String
    }

    // MARK: - The issue's three patterns

    @Test("A day-month-year pattern is honoured")
    func dayMonthYear() async {
        #expect(await formatted("dd.MM.yyyy") == "15.01.2026")
    }

    @Test("A time-only pattern is honoured")
    func timeOnly() async {
        #expect(await formatted("HH:mm:ss") == "10:30:00")
    }

    @Test("The long pattern is honoured — and is not the answer to everything")
    func longPattern() async {
        // This one happens to equal the default, which is why the bug was easy
        // to miss: the first example in the issue looked right.
        #expect(await formatted("MMMM dd, yyyy") == "January 15, 2026")
    }

    @Test("Three different patterns give three different answers")
    func patternsDiffer() async {
        let a = await formatted("MMMM dd, yyyy")
        let b = await formatted("dd.MM.yyyy")
        let c = await formatted("HH:mm:ss")

        // All three were identical before.
        #expect(Set([a, b, c].compactMap { $0 }).count == 3, "\(String(describing: [a, b, c]))")
    }

    // MARK: - The default still applies

    @Test("With no pattern, the documented default is used")
    func defaultPattern() async {
        #expect(await formatted(nil) == "January 15, 2026")
    }

    @Test("An empty pattern falls back to the default rather than emitting nothing")
    func emptyPattern() async {
        #expect(await formatted("") == "January 15, 2026")
    }

    // MARK: - Shapes worth pinning

    @Test("A year-only pattern works, so the match is not just on length")
    func yearOnly() async {
        #expect(await formatted("yyyy") == "2026")
    }

    @Test("A pattern with literal text in it survives")
    func patternWithLiteralText() async {
        let out = await formatted("yyyy-MM-dd")
        #expect(out == "2026-01-15", "\(String(describing: out))")
    }
}
