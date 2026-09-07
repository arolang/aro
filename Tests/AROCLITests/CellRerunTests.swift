// ============================================================
// CellRerunTests.swift
// AROCLI — re-running a cell is not a rebind (GitLab #544)
// ============================================================
//
// Fix a typo in a cell, press ⇧⏎ again: the notebook's core loop.
// It used to fail with "Cannot rebind immutable variable", and the
// only way out was Restart Kernel — which throws away every other
// binding in the session.
//
// Immutability is a property of a program. A cell run twice is not
// two statements binding the same name; it is one statement
// evaluated again. So a re-run releases the bindings THAT cell made,
// and nothing else: a different cell binding the same name is still
// refused, which is the case the guard exists for (#503/#506/#514).

import Testing
import Foundation
@testable import AROCLI

@Suite("Cell re-run", .serialized)
struct CellRerunTests {

    private func engine() -> REPLCellEngine {
        REPLCellEngine(session: REPLSession(suppressLogPrefix: true))
    }

    @Test("The same cell runs twice")
    func rerunSameCell() async {
        let engine = engine()
        let first = await engine.executeCell("Compute the <total> from 40 + 2.", cellID: "c1")
        #expect(first.error == nil)
        #expect(engine.session.getVariable("total") as? Int == 42)

        let second = await engine.executeCell("Compute the <total> from 40 + 3.", cellID: "c1")
        #expect(second.error == nil, "re-running a cell must not be refused")
        #expect(engine.session.getVariable("total") as? Int == 43,
                "the fresh run's value wins")
    }

    @Test("A different cell binding the same name is still refused")
    func otherCellStillGuarded() async {
        let engine = engine()
        _ = await engine.executeCell("Compute the <total> from 1 + 1.", cellID: "c1")
        let other = await engine.executeCell("Compute the <total> from 2 + 2.", cellID: "c2")
        #expect(other.error?.name == "ImmutabilityError",
                "cross-cell rebinding is what the guard is for")
        #expect(engine.session.getVariable("total") as? Int == 2, "the first cell's value stands")
    }

    @Test("Without a cell id the session-wide rule is unchanged")
    func plainReplUnchanged() async {
        // A terminal REPL line has no cell identity, and each line is
        // a new statement in the session's program.
        let engine = engine()
        _ = await engine.executeCell("Compute the <total> from 1 + 1.")
        let again = await engine.executeCell("Compute the <total> from 2 + 2.")
        #expect(again.error?.name == "ImmutabilityError")
    }

    @Test("A re-run only releases what that cell bound")
    func releasesOnlyItsOwn() async {
        let engine = engine()
        _ = await engine.executeCell("Compute the <base> from 10.", cellID: "c1")
        _ = await engine.executeCell("Compute the <derived> from <base> * 2.", cellID: "c2")
        #expect(engine.session.getVariable("derived") as? Int == 20)

        // Re-running c2 must not disturb c1's binding.
        let rerun = await engine.executeCell("Compute the <derived> from <base> * 3.", cellID: "c2")
        #expect(rerun.error == nil)
        #expect(engine.session.getVariable("base") as? Int == 10)
        #expect(engine.session.getVariable("derived") as? Int == 30)
    }

    @Test("A cell binding several names re-runs all of them")
    func multipleBindings() async {
        let engine = engine()
        let source = """
        Compute the <a> from 1.
        Compute the <b> from 2.
        """
        _ = await engine.executeCell(source, cellID: "c1")
        let rerun = await engine.executeCell("""
        Compute the <a> from 10.
        Compute the <b> from 20.
        """, cellID: "c1")
        #expect(rerun.error == nil)
        #expect(engine.session.getVariable("a") as? Int == 10)
        #expect(engine.session.getVariable("b") as? Int == 20)
    }

    @Test("A cell that binds fewer names on re-run leaves no ghost")
    func shrinkingCell() async {
        let engine = engine()
        _ = await engine.executeCell("""
        Compute the <kept> from 1.
        Compute the <dropped> from 2.
        """, cellID: "c1")
        #expect(engine.session.getVariable("dropped") as? Int == 2)

        let rerun = await engine.executeCell("Compute the <kept> from 5.", cellID: "c1")
        #expect(rerun.error == nil)
        #expect(engine.session.getVariable("kept") as? Int == 5)
        // The name the cell no longer binds is gone with it, so a
        // later cell may use it — the session reflects the cells as
        // they are now, not as they once were.
        #expect(engine.session.getVariable("dropped") == nil)
    }

    @Test("reset() forgets the ledger")
    func resetClearsLedger() async {
        let engine = engine()
        _ = await engine.executeCell("Compute the <total> from 1.", cellID: "c1")
        engine.reset()
        let after = await engine.executeCell("Compute the <total> from 2.", cellID: "c1")
        #expect(after.error == nil)
        #expect(engine.session.getVariable("total") as? Int == 2)
    }
}
