// ============================================================
// REPLRebindSurvivalTests.swift
// AROCLI - A rebind must error the cell, not kill the session (GitLab #495)
// ============================================================
//
// The per-cell analyzer cannot see an earlier cell's binding, so a rebind
// across cells reaches the runtime's immutability backstop. That backstop
// used to be a fatalError — one accidental rebind took the REPL, the JSON
// server, and the Jupyter kernel down with SIGTRAP. These tests prove the
// contract now: the offending statement reports an ARO error, the earlier
// binding survives untouched, and the session keeps executing.

import Foundation
import Testing
@testable import AROCLI

@Suite("REPL rebind survival (GitLab #495)", .serialized)
struct REPLRebindSurvivalTests {

    @Test("Rebinding across cells errors and the session survives")
    func rebindAcrossCells() async throws {
        let session = REPLSession(suppressLogPrefix: true)

        _ = try await session.executeStatement("Compute the <v> from 5.")
        #expect(session.getVariable("v") as? Int == 5)

        let second = try await session.executeStatement("Compute the <v> from 6.")
        guard case .error(let message) = second else {
            Issue.record("expected an error, got \(second)")
            return
        }
        #expect(message.contains("Cannot rebind immutable variable 'v'"))
        #expect(message.contains("Create a new variable instead"))

        // The refused write left the original value in place…
        #expect(session.getVariable("v") as? Int == 5)

        // …and the session is still alive and computing.
        _ = try await session.executeStatement("Compute the <w> from <v> * 2.")
        #expect(session.getVariable("w") as? Int == 10)
    }

    @Test("Match-arm rebind of a session variable errors, session survives")
    func matchArmRebind() async throws {
        let session = REPLSession(suppressLogPrefix: true)

        _ = try await session.executeStatement("Compute the <mode> from 5.")

        // A top-level pre-guard can only see result descriptors of top-level
        // statements; the rebind hides inside a match arm and reaches the
        // runtime backstop.
        let block = """
        match <mode> {
            case 5 {
                Compute the <mode> from 99.
            }
        }
        """
        let result = try await session.executeStatement(block)
        guard case .error(let message) = result else {
            Issue.record("expected an error, got \(result)")
            return
        }
        #expect(message.contains("Cannot rebind immutable variable 'mode'"))

        // Original binding intact, session alive.
        #expect(session.getVariable("mode") as? Int == 5)
        _ = try await session.executeStatement("Compute the <next> from <mode> + 1.")
        #expect(session.getVariable("next") as? Int == 6)
    }
}
