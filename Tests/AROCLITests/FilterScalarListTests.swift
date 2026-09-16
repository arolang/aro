// ============================================================
// FilterScalarListTests.swift
// AROCLI — Filter over a list of scalars (GitLab #569)
// ============================================================
//
// `ResolvedWhereCondition.matchesElement` opened with
//
//     guard let dict = element as? [String: any Sendable] else { return false }
//
// so filtering a list of strings or numbers matched nothing and returned `[]`.
// No error, no warning, no `aro check` diagnostic — the program ran on with the
// wrong answer, the same failure shape as the invented-Compute-qualifier bug
// (#486).
//
// "Read a file, keep the lines that contain X, count them" is the first shape
// most people reach for after `Compute the <lines: lines>`, and it silently
// produced 0. `Book/AROByHallucination` Chapter 5 shipped exactly that snippet
// as a worked example, because the check passes and the run exits `[OK]`.

import Testing
import Foundation
@testable import AROCLI

@Suite("Filter over a scalar list (GitLab #569)", .serialized)
struct FilterScalarListTests {

    private func values(_ any: Any?) -> [String] {
        guard let rows = any as? [Any] else { return [] }
        return rows.map { "\($0)" }
    }

    // MARK: - The issue's repro

    @Test("Filtering a list of strings keeps the matching ones")
    func stringsAreFiltered() async {
        let session = REPLSession(suppressLogPrefix: true)
        let engine = REPLCellEngine(session: session)

        _ = await engine.executeCell(
            #"Create the <ls> with ["INFO ok", "ERROR bad", "ERROR worse"]."#)
        let outcome = await engine.executeCell(
            #"Filter the <errs> from the <ls> where <line> contains "ERROR"."#)

        #expect(outcome.error == nil)
        // Was [] — every element was rejected before the predicate ran.
        #expect(values(session.getVariable("errs")) == ["ERROR bad", "ERROR worse"])
    }

    @Test("The filtered list has the length the count reports")
    func lengthIsRight() async {
        let session = REPLSession(suppressLogPrefix: true)
        let engine = REPLCellEngine(session: session)

        _ = await engine.executeCell(
            #"Create the <ls> with ["INFO ok", "ERROR bad", "ERROR worse"]."#)
        _ = await engine.executeCell(
            #"Filter the <errs> from the <ls> where <line> contains "ERROR"."#)
        _ = await engine.executeCell("Compute the <n: length> from the <errs>.")

        #expect(session.getVariable("n") as? Int == 2)
    }

    @Test("The binding name is irrelevant for a scalar, and says so consistently")
    func anyBindingNameWorks() async {
        // Every name behaved identically before — that was the giveaway. They
        // still do, because a scalar carries no field to name.
        for name in ["line", "item", "value", "anything"] {
            let session = REPLSession(suppressLogPrefix: true)
            let engine = REPLCellEngine(session: session)
            _ = await engine.executeCell(#"Create the <ls> with ["a1", "b2"]."#)
            _ = await engine.executeCell(
                "Filter the <hits> from the <ls> where <\(name)> contains \"a\".")
            #expect(values(session.getVariable("hits")) == ["a1"], "failed for <\(name)>")
        }
    }

    // MARK: - Other operators and types

    @Test("Numbers compare, rather than matching on equality or not at all")
    func numbersCompare() async {
        let session = REPLSession(suppressLogPrefix: true)
        let engine = REPLCellEngine(session: session)

        _ = await engine.executeCell("Create the <ns> with [1, 5, 9].")
        _ = await engine.executeCell("Filter the <big> from the <ns> where <n> > 4.")
        _ = await engine.executeCell("Filter the <five> from the <ns> where <n> is 5.")

        #expect(values(session.getVariable("big")) == ["5", "9"])
        #expect(values(session.getVariable("five")) == ["5"])
    }

    @Test("An and/or tree applies to the element at every leaf")
    func booleanTreesApply() async {
        let session = REPLSession(suppressLogPrefix: true)
        let engine = REPLCellEngine(session: session)

        _ = await engine.executeCell(#"Create the <ws> with ["alpha", "beta", "gamma"]."#)
        _ = await engine.executeCell(
            #"Filter the <both> from the <ws> where <w> contains "a" and <w> contains "l"."#)
        _ = await engine.executeCell(
            #"Filter the <either> from the <ws> where <w> contains "lph" or <w> contains "bet"."#)

        #expect(values(session.getVariable("both")) == ["alpha"])
        #expect(values(session.getVariable("either")) == ["alpha", "beta"])
    }

    @Test("A predicate matching nothing still returns empty, not everything")
    func noMatchIsEmpty() async {
        let session = REPLSession(suppressLogPrefix: true)
        let engine = REPLCellEngine(session: session)

        _ = await engine.executeCell(#"Create the <ls> with ["a", "b"]."#)
        _ = await engine.executeCell(
            #"Filter the <none> from the <ls> where <x> contains "zzz"."#)

        #expect(values(session.getVariable("none")).isEmpty)
    }

    // MARK: - Records are untouched

    @Test("A record still filters on the named field")
    func recordsFilterOnTheField() async {
        let session = REPLSession(suppressLogPrefix: true)
        let engine = REPLCellEngine(session: session)

        _ = await engine.executeCell(
            #"Create the <rs> with [{ id: 1, tag: "red" }, { id: 2, tag: "blue" }]."#)
        _ = await engine.executeCell(#"Filter the <reds> from the <rs> where <tag> is "red"."#)

        let rows = session.getVariable("reds") as? [Any] ?? []
        #expect(rows.count == 1)
        #expect((rows.first as? [String: Any])?["id"] as? Int == 1)
    }

    @Test("A record predicate on a field it does not carry is still false")
    func missingFieldIsStillFalse() async {
        // The rule records have always followed must not change: a scalar
        // fallback applies to scalars, not to records missing a field.
        let session = REPLSession(suppressLogPrefix: true)
        let engine = REPLCellEngine(session: session)

        _ = await engine.executeCell(#"Create the <rs> with [{ id: 1 }, { id: 2 }]."#)
        _ = await engine.executeCell(#"Filter the <hits> from the <rs> where <nope> is "x"."#)

        #expect((session.getVariable("hits") as? [Any])?.isEmpty == true)
    }
}
