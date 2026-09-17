// ============================================================
// BareWhereFieldSessionTests.swift
// AROCLI — bare where fields filter, end to end (GitLab #545)
// ============================================================
//
// Parsing the bare field is only half the promise: `where status =
// "active"` has to select the same rows as `where <status> =
// "active"`, or the proposals would merely compile rather than be
// true. These run both spellings through the cell engine the REPL and
// the Jupyter kernel share, and compare the rows that come back.

import Testing
import Foundation
@testable import AROCLI

@Suite("Bare where fields (#545)", .serialized)
struct BareWhereFieldSessionTests {

    private static let orders =
        #"Compute the <orders> from [{ status: "paid", qty: 3 }, { status: "paid", qty: 1 }, { status: "open", qty: 5 }, { status: "open", qty: 1 }]."#

    private func qtys(_ value: Any?) -> [Int] {
        guard let rows = value as? [Any] else { return [] }
        return rows.compactMap { ($0 as? [String: Any])?["qty"] as? Int }
    }

    @Test("ARO-0019 §2.1's example filters, it does not just parse")
    func bareFilterActuallyFilters() async {
        let session = REPLSession(suppressLogPrefix: true)
        let engine = REPLCellEngine(session: session)

        _ = await engine.executeCell(Self.orders)
        let outcome = await engine.executeCell(
            #"Filter the <paid> from the <orders> where status = "paid"."#)
        #expect(outcome.error == nil)
        #expect(qtys(session.getVariable("paid")) == [3, 1])
    }

    @Test("Bare and bracketed spellings select the same rows")
    func spellingsSelectTheSameRows() async {
        let session = REPLSession(suppressLogPrefix: true)
        let engine = REPLCellEngine(session: session)

        _ = await engine.executeCell(Self.orders)
        _ = await engine.executeCell(
            #"Filter the <bare> from the <orders> where status = "open"."#)
        _ = await engine.executeCell(
            #"Filter the <angled> from the <orders> where <status> = "open"."#)

        let bare = qtys(session.getVariable("bare"))
        #expect(bare == [5, 1])
        #expect(bare == qtys(session.getVariable("angled")))
    }

    @Test("Bare fields chain with and/or and parentheses")
    func bareChaining() async {
        let session = REPLSession(suppressLogPrefix: true)
        let engine = REPLCellEngine(session: session)

        _ = await engine.executeCell(Self.orders)

        let anded = await engine.executeCell(
            #"Filter the <big-paid> from the <orders> where status == "paid" and qty > 2."#)
        #expect(anded.error == nil)
        #expect(qtys(session.getVariable("big-paid")) == [3])

        let ored = await engine.executeCell(
            #"Filter the <either> from the <orders> where status == "paid" or qty > 4."#)
        #expect(ored.error == nil)
        #expect(qtys(session.getVariable("either")) == [3, 1, 5])

        let grouped = await engine.executeCell(
            #"Filter the <mixed> from the <orders> where (status == "paid" or status == "open") and qty > 2."#)
        #expect(grouped.error == nil)
        #expect(qtys(session.getVariable("mixed")) == [3, 5])
    }

    @Test("A bare field mixes with a bracketed one in the same condition")
    func mixedSpellings() async {
        let session = REPLSession(suppressLogPrefix: true)
        let engine = REPLCellEngine(session: session)

        _ = await engine.executeCell(Self.orders)
        let outcome = await engine.executeCell(
            #"Filter the <mix> from the <orders> where status == "paid" and <qty> > 2."#)
        #expect(outcome.error == nil)
        #expect(qtys(session.getVariable("mix")) == [3])
    }

    @Test("between works from a bare field")
    func bareBetween() async {
        let session = REPLSession(suppressLogPrefix: true)
        let engine = REPLCellEngine(session: session)

        _ = await engine.executeCell(Self.orders)
        let outcome = await engine.executeCell(
            "Filter the <ranged> from the <orders> where qty between 1 and 3.")
        #expect(outcome.error == nil)
        #expect(qtys(session.getVariable("ranged")) == [3, 1, 1])
    }

    @Test("ARO-0003/ARO-0006: repository Retrieve where id = <id>")
    func bareRepositoryRetrieve() async {
        let session = REPLSession(suppressLogPrefix: true)
        let engine = REPLCellEngine(session: session)

        _ = await engine.executeCell(#"Compute the <u1> from { id: 1, name: "Ada" }."#)
        _ = await engine.executeCell("Store the <u1> into the <bare-user-repository>.")
        _ = await engine.executeCell(#"Compute the <u2> from { id: 2, name: "Grace" }."#)
        _ = await engine.executeCell("Store the <u2> into the <bare-user-repository>.")
        _ = await engine.executeCell("Compute the <uid> from 2.")

        let outcome = await engine.executeCell(
            "Retrieve the <user> from the <bare-user-repository> where id = <uid>.")
        #expect(outcome.error == nil)
        let user = session.getVariable("user") as? [String: Any]
        #expect(user?["name"] as? String == "Grace")
    }

    @Test("A bare field resolves even when a binding shares its name (GitLab #573)")
    func bareFieldBeatsASameNamedBinding() async {
        // The idiomatic repository query, and the reason #573 argued for the
        // bare form: with brackets, `where <id> = <id>` reads as a tautology
        // rather than a filter. Bare, it reads as what it is — the *field*
        // `id` against the *binding* `<id>` — and the two must not be confused
        // for each other when they share a name.
        let session = REPLSession(suppressLogPrefix: true)
        let engine = REPLCellEngine(session: session)

        _ = await engine.executeCell(#"Compute the <u1> from { id: 1, name: "Ada" }."#)
        _ = await engine.executeCell("Store the <u1> into the <collide573-repository>.")
        _ = await engine.executeCell(#"Compute the <u2> from { id: 2, name: "Grace" }."#)
        _ = await engine.executeCell("Store the <u2> into the <collide573-repository>.")
        _ = await engine.executeCell("Compute the <id> from 2.")

        let outcome = await engine.executeCell(
            "Retrieve the <user> from the <collide573-repository> where id is <id>.")
        #expect(outcome.error == nil)
        // Grace, not Ada: the predicate compared the field to the binding's
        // value, not the field to itself.
        #expect((session.getVariable("user") as? [String: Any])?["name"] as? String == "Grace")
    }

    @Test("Delete's single-predicate guard takes a bare field")
    func bareDelete() async {
        let session = REPLSession(suppressLogPrefix: true)
        let engine = REPLCellEngine(session: session)

        _ = await engine.executeCell(#"Compute the <d1> from { id: 1, status: "open" }."#)
        _ = await engine.executeCell("Store the <d1> into the <bare-del-repository>.")
        _ = await engine.executeCell(#"Compute the <d2> from { id: 2, status: "cancelled" }."#)
        _ = await engine.executeCell("Store the <d2> into the <bare-del-repository>.")

        let outcome = await engine.executeCell(
            #"Delete the <gone> from the <bare-del-repository> where status = "cancelled"."#)
        #expect(outcome.error == nil)

        _ = await engine.executeCell("Retrieve the <left> from the <bare-del-repository>.")
        let ids = (session.getVariable("left") as? [Any])?
            .compactMap { ($0 as? [String: Any])?["id"] as? Int }
        #expect(ids == [1])
    }
}
