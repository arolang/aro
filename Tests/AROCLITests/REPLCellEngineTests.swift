// ============================================================
// REPLCellEngineTests.swift
// AROCLI — the shared cell engine's session-safety guarantees
// ============================================================

import Testing
import Foundation
@testable import AROCLI

@Suite("REPL cell engine", .serialized)
struct REPLCellEngineTests {

    @Test("Rebinding across cells errors cleanly instead of killing the process")
    func rebindAcrossCells() async {
        let session = REPLSession(suppressLogPrefix: true)
        let engine = REPLCellEngine(session: session)

        let first = await engine.executeCell("Compute the <volume> from 5.")
        #expect(first.error == nil)

        // Without the guard this fatalErrored in RuntimeContext.bind —
        // the whole kernel died.
        let second = await engine.executeCell("Compute the <volume> from 3.")
        #expect(second.error?.name == "ImmutabilityError")
        #expect(second.error?.value.contains("volume") == true)

        // The session survived and keeps working.
        let third = await engine.executeCell("Compute the <volume-updated> from <volume> + 1.")
        #expect(third.error == nil)
        #expect(session.getVariable("volume-updated") as? Int == 6)
    }

    @Test("Loop-body bindings may shadow session names (loop isolation)")
    func loopShadowingAllowed() async {
        let session = REPLSession(suppressLogPrefix: true)
        let engine = REPLCellEngine(session: session)

        _ = await engine.executeCell("Compute the <total> from 1 + 1.")
        _ = await engine.executeCell(
            "Create the <pairs> with [{ q: 2, p: 3 }, { q: 1, p: 5 }].")

        // <total> inside the loop lives in the loop's own scope —
        // rejecting it broke the CI notebook. Must run clean.
        let outcome = await engine.executeCell("""
        for each <pair> in <pairs> {
            Extract the <q> from the <pair: q>.
            Extract the <p> from the <pair: p>.
            Compute the <total> from <q> * <p>.
            Log <total> to the <console>.
        }
        """)
        #expect(outcome.error == nil)

        // Top-level rebinding stays blocked.
        let rebind = await engine.executeCell("Compute the <total> from 9.")
        #expect(rebind.error?.name == "ImmutabilityError")
    }

    @Test("Update-family verbs are exempt — Configure accumulates by contract")
    func updateVerbsExempt() async {
        let session = REPLSession(suppressLogPrefix: true)
        let engine = REPLCellEngine(session: session)

        let first = await engine.executeCell("Configure the <http-client: timeout> with 30.")
        #expect(first.error == nil)
        // A second Configure on the same category is ARO-0035's normal
        // accumulation — the guard used to flag it (GitLab #506).
        let second = await engine.executeCell("Configure the <http-client: retries> with 3.")
        #expect(second.error == nil)
        // Plain own-role rebinds stay guarded.
        _ = await engine.executeCell("Compute the <v> from 1.")
        let rebind = await engine.executeCell("Compute the <v> from 2.")
        #expect(rebind.error?.name == "ImmutabilityError")
    }

    @Test("Test verbs are exempt — assertions read, they do not bind")
    func testVerbsExempt() async {
        let session = REPLSession(suppressLogPrefix: true)
        let engine = REPLCellEngine(session: session)

        _ = await engine.executeCell("Compute the <total> from 40 + 2.")
        // Cross-cell Assert on an existing variable used to be flagged
        // as a rebind (GitLab #514).
        let pass = await engine.executeCell("Assert the <total> with 42.")
        #expect(pass.error == nil)
        let thenPass = await engine.executeCell("Then the <total> with 42.")
        #expect(thenPass.error == nil)
        // A failing assertion reports the assertion message, not a
        // struct dump and not a rebind error.
        let fail = await engine.executeCell("Assert the <total> with 99.")
        #expect(fail.error?.value.contains("Assertion failed") == true)
        #expect(fail.error?.value.contains("expected 99") == true)
    }

    @Test("The guard leaves effect statements alone")
    func effectsAreNotFlagged() async {
        let session = REPLSession(suppressLogPrefix: true)
        let engine = REPLCellEngine(session: session)

        _ = await engine.executeCell("Compute the <message> from \"hi\".")
        // `Log <message> …` has <message> in its result slot but binds
        // nothing — it must not be rejected as a rebind.
        let outcome = await engine.executeCell("Log <message> to the <console>.")
        #expect(outcome.error == nil)
    }

    @Test("reset() clears the definitions and the session")
    func resetClears() async {
        let session = REPLSession(suppressLogPrefix: true)
        let engine = REPLCellEngine(session: session)
        _ = await engine.executeCell("Compute the <n> from 1.")
        engine.reset()
        // The name is free again after reset.
        let outcome = await engine.executeCell("Compute the <n> from 2.")
        #expect(outcome.error == nil)
        #expect(session.getVariable("n") as? Int == 2)
    }
}

@Suite("REPL expression evaluation", .serialized)
struct REPLExpressionTests {

    @Test("Expressions evaluate repeatedly without rebinding anything")
    func repeatedEvaluation() async throws {
        let session = REPLSession(suppressLogPrefix: true)

        let first = try await session.evaluateExpression("2 + 3")
        guard case .value(let a) = first else {
            Issue.record("expected a value, got \(first)")
            return
        }
        #expect("\(a)" == "5")

        // The second evaluation used to die on the fixed-name rebind.
        let second = try await session.evaluateExpression("6 * 7")
        guard case .value(let b) = second else {
            Issue.record("expected a value, got \(second)")
            return
        }
        #expect("\(b)" == "42")

        // No expression residue leaks into the session.
        #expect(session.variableNames.isEmpty)
    }

    @Test("Expressions read the session's variables")
    func readsSessionVariables() async throws {
        let session = REPLSession(suppressLogPrefix: true)
        _ = try await session.executeStatement("Compute the <base> from 10.")
        let result = try await session.evaluateExpression("<base> * 4")
        guard case .value(let value) = result else {
            Issue.record("expected a value, got \(result)")
            return
        }
        #expect("\(value)" == "40")
    }
}
