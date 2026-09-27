// ============================================================
// WhereChainingTests.swift
// AROCLI — where-clause and/or chaining end to end (GitLab #498)
// ============================================================
//
// The repro from the issue, run through the same cell engine the
// REPL and Jupyter kernel use. Before #498 the `and` tail was
// swallowed into the first predicate's value expression and the
// statement died with "Undefined variable: qty"; these tests pin
// the parse AND the filtering semantics (and, or, parentheses,
// between, equivalence with chained single-predicate Filters, and
// the repository Retrieve path, which shares the condition tree).

import Testing
import Foundation
@testable import AROCLI

@Suite("Where chaining (#498)", .serialized)
struct WhereChainingTests {

    private static let orders =
        #"Compute the <orders> from [{ status: "paid", qty: 3 }, { status: "paid", qty: 1 }, { status: "open", qty: 5 }, { status: "open", qty: 1 }]."#

    private func qtys(_ value: Any?) -> [Int] {
        guard let rows = value as? [Any] else { return [] }
        return rows.compactMap { ($0 as? [String: Any])?["qty"] as? Int }
    }

    @Test("The issue's repro: and-chained Filter binds, no 'Undefined variable'")
    func andChainedFilter() async {
        let session = REPLSession()
        let engine = REPLCellEngine(session: session)

        _ = await engine.executeCell(Self.orders)
        let outcome = await engine.executeCell(
            #"Filter the <big-paid> from the <orders> where <status> == "paid" and <qty> > 2."#)
        #expect(outcome.error == nil)
        #expect(qtys(session.getVariable("big-paid")) == [3])
    }

    @Test("or keeps every row matching either side")
    func orChainedFilter() async {
        let session = REPLSession()
        let engine = REPLCellEngine(session: session)

        _ = await engine.executeCell(Self.orders)
        let outcome = await engine.executeCell(
            #"Filter the <either> from the <orders> where <status> == "paid" or <qty> > 4."#)
        #expect(outcome.error == nil)
        #expect(qtys(session.getVariable("either")) == [3, 1, 5])
    }

    @Test("Parentheses override and-over-or precedence")
    func parenthesizedFilter() async {
        let session = REPLSession()
        let engine = REPLCellEngine(session: session)

        _ = await engine.executeCell(Self.orders)
        // Without the parentheses this would be: paid or (open and qty>2).
        let outcome = await engine.executeCell(
            #"Filter the <mixed> from the <orders> where (<status> == "paid" or <status> == "open") and <qty> > 2."#)
        #expect(outcome.error == nil)
        #expect(qtys(session.getVariable("mixed")) == [3, 5])
    }

    @Test("and binds tighter than or")
    func precedenceMatchesARO0018() async {
        let session = REPLSession()
        let engine = REPLCellEngine(session: session)

        _ = await engine.executeCell(Self.orders)
        // qty>4 or (paid and qty>2) — NOT (qty>4 or paid) and qty>2,
        // which would drop the open/5 row.
        let outcome = await engine.executeCell(
            #"Filter the <prec> from the <orders> where <qty> > 4 or <status> == "paid" and <qty> > 2."#)
        #expect(outcome.error == nil)
        #expect(qtys(session.getVariable("prec")) == [3, 5])
    }

    @Test("An and-chain equals the same predicates as chained Filters")
    func chainedFilterEquivalence() async {
        let session = REPLSession()
        let engine = REPLCellEngine(session: session)

        _ = await engine.executeCell(Self.orders)
        _ = await engine.executeCell(
            #"Filter the <chained-a> from the <orders> where <status> == "paid"."#)
        _ = await engine.executeCell(
            #"Filter the <chained> from the <chained-a> where <qty> > 2."#)
        _ = await engine.executeCell(
            #"Filter the <combined> from the <orders> where <status> == "paid" and <qty> > 2."#)

        let chained = qtys(session.getVariable("chained"))
        let combined = qtys(session.getVariable("combined"))
        #expect(!chained.isEmpty)
        #expect(chained == combined)
    }

    @Test("between filters an inclusive range")
    func betweenFilter() async {
        let session = REPLSession()
        let engine = REPLCellEngine(session: session)

        _ = await engine.executeCell(Self.orders)
        let outcome = await engine.executeCell(
            "Filter the <ranged> from the <orders> where <qty> between 1 and 3.")
        #expect(outcome.error == nil)
        #expect(qtys(session.getVariable("ranged")) == [3, 1, 1])
    }

    @Test("Repository Retrieve shares the condition tree")
    func repositoryRetrieveChains() async {
        let session = REPLSession()
        let engine = REPLCellEngine(session: session)

        _ = await engine.executeCell(
            #"Compute the <o1> from { status: "paid", qty: 3 }."#)
        _ = await engine.executeCell("Store the <o1> into the <chain-order-repository>.")
        _ = await engine.executeCell(
            #"Compute the <o2> from { status: "paid", qty: 1 }."#)
        _ = await engine.executeCell("Store the <o2> into the <chain-order-repository>.")
        _ = await engine.executeCell(
            #"Compute the <o3> from { status: "open", qty: 5 }."#)
        _ = await engine.executeCell("Store the <o3> into the <chain-order-repository>.")

        let outcome = await engine.executeCell(
            #"Retrieve the <hits> from the <chain-order-repository> where <status> is "paid" and <qty> > 2."#)
        #expect(outcome.error == nil)
        // Exactly one match — Retrieve unwraps it to the entity itself.
        let hit = session.getVariable("hits") as? [String: Any]
        #expect(hit?["qty"] as? Int == 3)
        #expect(hit?["status"] as? String == "paid")
    }

    @Test("A malformed where clause is a parse error, not 'Undefined variable'")
    func malformedWhereFailsTheParse() async {
        let session = REPLSession()
        let engine = REPLCellEngine(session: session)

        _ = await engine.executeCell(Self.orders)
        let outcome = await engine.executeCell(
            "Filter the <x> from the <orders> where <qty> banana 3.")
        let message = "\(outcome.error?.value ?? "")"
        #expect(outcome.error != nil)
        #expect(!message.contains("Undefined variable"))
        #expect(message.contains("comparison operator"))
    }
}
