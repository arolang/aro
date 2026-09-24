// ============================================================
// RepositoryWhereOperatorTests.swift
// AROCLI — a single where predicate honours its operator (GitLab #565)
// ============================================================
//
// `Retrieve … where <qty> > 2.` on a repository silently matched on
// *equality*: the repository branch of `ExtractAction` read `_where_field_`
// and `_where_value_` and called `storage.retrieve(where:equals:)` without
// ever reading `_where_op_`. `aro check` was green, the program exited `[OK]`,
// and the rows were wrong — the failure mode ARO-0018 §2.2 was meant to close.
//
// The asymmetry is what made it invisible: chaining a second predicate built a
// condition tree, which goes through `matchesElement` and honours the
// operator, so the same predicate returned the right rows as soon as anything
// was `and`-ed onto it. These tests compare the three spellings the issue puts
// side by side, and sweep the operators ARO-0018 §2.1 lists.

import Testing
import Foundation
@testable import AROCLI

@Suite("Repository where operators (GitLab #565)", .serialized)
struct RepositoryWhereOperatorTests {

    /// A fresh repository per test — the storage is process-wide.
    private func seed(_ engine: REPLCellEngine, repo: String) async {
        _ = await engine.executeCell(#"Compute the <r1> from { id: 1, qty: 5, tag: "red" }."#)
        _ = await engine.executeCell("Store the <r1> into the <\(repo)>.")
        _ = await engine.executeCell(#"Compute the <r2> from { id: 2, qty: 1, tag: "blue" }."#)
        _ = await engine.executeCell("Store the <r2> into the <\(repo)>.")
    }

    /// The `id`s a retrieve bound, whether it unwrapped a single row or not.
    private func ids(_ value: Any?) -> [Int] {
        if let row = value as? [String: Any], let id = row["id"] as? Int { return [id] }
        guard let rows = value as? [Any] else { return [] }
        return rows.compactMap { ($0 as? [String: Any])?["id"] as? Int }
    }

    // MARK: - The issue's three spellings must agree

    @Test("A lone `>` predicate returns the matching row, not nothing")
    func loneGreaterThan() async {
        let session = REPLSession()
        let engine = REPLCellEngine(session: session)
        await seed(engine, repo: "op565a-repository")

        let outcome = await engine.executeCell(
            "Retrieve the <one> from the <op565a-repository> where <qty> > 2.")
        #expect(outcome.error == nil)
        // Was [] — the operator was dropped and 5 == 2 is false.
        #expect(ids(session.getVariable("one")) == [1])
    }

    @Test("Lone, chained and Filter spellings give the same answer")
    func threeSpellingsAgree() async {
        let session = REPLSession()
        let engine = REPLCellEngine(session: session)
        await seed(engine, repo: "op565b-repository")

        _ = await engine.executeCell(
            "Retrieve the <lone> from the <op565b-repository> where <qty> > 2.")
        _ = await engine.executeCell(
            "Retrieve the <chained> from the <op565b-repository> where <qty> > 2 and <id> > 0.")
        _ = await engine.executeCell(
            "Retrieve the <all> from the <op565b-repository>.")
        _ = await engine.executeCell(
            "Filter the <filtered> from the <all> where <qty> > 2.")

        let lone = ids(session.getVariable("lone"))
        #expect(lone == [1])
        #expect(lone == ids(session.getVariable("chained")))
        #expect(lone == ids(session.getVariable("filtered")))
    }

    @Test("`>=` matches the boundary and everything above it")
    func greaterEqualIncludesBoundary() async {
        let session = REPLSession()
        let engine = REPLCellEngine(session: session)
        await seed(engine, repo: "op565c-repository")

        let outcome = await engine.executeCell(
            "Retrieve the <rows> from the <op565c-repository> where <qty> >= 1.")
        #expect(outcome.error == nil)
        // Was [2] alone — an equality match on the literal 1.
        #expect(ids(session.getVariable("rows")).sorted() == [1, 2])
    }

    // MARK: - The operators ARO-0018 §2.1 lists

    @Test("`<` compares rather than equates")
    func lessThan() async {
        let session = REPLSession()
        let engine = REPLCellEngine(session: session)
        await seed(engine, repo: "op565d-repository")
        _ = await engine.executeCell(
            "Retrieve the <rows> from the <op565d-repository> where <qty> < 3.")
        #expect(ids(session.getVariable("rows")) == [2])
    }

    @Test("`is not` excludes rather than includes")
    func isNot() async {
        let session = REPLSession()
        let engine = REPLCellEngine(session: session)
        await seed(engine, repo: "op565e-repository")
        _ = await engine.executeCell(
            #"Retrieve the <rows> from the <op565e-repository> where <tag> is not "red"."#)
        // Dropping the operator here returned the *matching* row — the one
        // answer that is not merely empty but actively inverted.
        #expect(ids(session.getVariable("rows")) == [2])
    }

    @Test("`in` tests membership")
    func membership() async {
        let session = REPLSession()
        let engine = REPLCellEngine(session: session)
        await seed(engine, repo: "op565f-repository")
        _ = await engine.executeCell(
            #"Retrieve the <rows> from the <op565f-repository> where <tag> in ["blue"]."#)
        #expect(ids(session.getVariable("rows")) == [2])
    }

    @Test("`contains` tests substrings")
    func contains() async {
        let session = REPLSession()
        let engine = REPLCellEngine(session: session)
        await seed(engine, repo: "op565g-repository")
        _ = await engine.executeCell(
            #"Retrieve the <rows> from the <op565g-repository> where <tag> contains "re"."#)
        #expect(ids(session.getVariable("rows")) == [1])
    }

    // MARK: - Equality keeps the storage fast path

    @Test("`is` still matches exactly, and still unwraps a single row")
    func equalityUnchanged() async {
        let session = REPLSession()
        let engine = REPLCellEngine(session: session)
        await seed(engine, repo: "op565h-repository")

        let outcome = await engine.executeCell(
            "Retrieve the <row> from the <op565h-repository> where <id> is 2.")
        #expect(outcome.error == nil)
        let row = session.getVariable("row") as? [String: Any]
        #expect(row?["id"] as? Int == 2)
        #expect(row?["tag"] as? String == "blue")
    }

    @Test("A retrieve with no where clause still returns everything")
    func noWhereClause() async {
        let session = REPLSession()
        let engine = REPLCellEngine(session: session)
        await seed(engine, repo: "op565i-repository")
        _ = await engine.executeCell("Retrieve the <rows> from the <op565i-repository>.")
        #expect(ids(session.getVariable("rows")).sorted() == [1, 2])
    }

    @Test("A non-equality predicate that matches nothing returns empty, not everything")
    func noMatchIsEmpty() async {
        let session = REPLSession()
        let engine = REPLCellEngine(session: session)
        await seed(engine, repo: "op565j-repository")
        _ = await engine.executeCell(
            "Retrieve the <rows> from the <op565j-repository> where <qty> > 99.")
        #expect(ids(session.getVariable("rows")).isEmpty)
    }
}
