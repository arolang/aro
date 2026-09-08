// ============================================================
// StoreInlinePayloadSessionTests.swift
// AROCLI — `Store … into <repo> with { … }` in live sessions (GitLab #515)
// ============================================================
//
// `Emit a <TicketOpened: event> with { id: 1 }.` has always taken an
// object literal. The same clause on Store was parsed, evaluated, bound
// to `_with_` — and then ignored, so the statement fell back to looking
// up a variable named after the result and died with "Cannot store the
// ticket into the ticket-repository". Everyone worked around it by
// binding the record with Create first.
//
// These tests run the documented shapes through the same session
// `aro repl --json` uses, which is where the gap is met first.

import Testing
import Foundation
import ARORuntime
@testable import AROCLI

@Suite("Store with an inline payload in a session (#515)", .serialized)
struct StoreInlinePayloadSessionTests {

    @Test("The payload is stored and the result binds the stored record")
    func inlinePayloadStoresAndBinds() async throws {
        let session = REPLSession(suppressLogPrefix: true)
        let result = try await session.executeStatement(
            "Store the <ticket> into the <s515a-repository> with { id: 1, state: \"new\" }.")
        #expect(result.isSuccess)

        // The result slot is usable afterwards — the point of the change.
        let bound = session.getVariable("ticket") as? [String: any Sendable]
        #expect(bound?["id"] as? Int == 1)
        #expect(bound?["state"] as? String == "new")

        _ = try await session.executeStatement(
            "Retrieve the <all> from the <s515a-repository>.")
        #expect((session.getVariable("all") as? [any Sendable])?.count == 1)
    }

    @Test("The identity field behaves exactly as for a Created record")
    func identityFieldMatchesCreateThenStore() async throws {
        let session = REPLSession(suppressLogPrefix: true)

        // Create-then-Store, the shape people had to write.
        _ = try await session.executeStatement(
            "Create the <a> with { id: \"k1\", n: 1 }.")
        _ = try await session.executeStatement(
            "Store the <a> into the <s515b-repository>.")

        // The inline payload, which must land the same way.
        _ = try await session.executeStatement(
            "Store the <b> into the <s515b-repository> with { id: \"k2\", n: 2 }.")

        _ = try await session.executeStatement(
            "Retrieve the <rowA> from the <s515b-repository> where <id> is \"k1\".")
        _ = try await session.executeStatement(
            "Retrieve the <rowB> from the <s515b-repository> where <id> is \"k2\".")
        #expect((session.getVariable("rowA") as? [String: any Sendable])?["n"] as? Int == 1)
        #expect((session.getVariable("rowB") as? [String: any Sendable])?["n"] as? Int == 2)

        // Storing the same id again upserts rather than appending — the
        // identity field drives storage identically for both spellings.
        _ = try await session.executeStatement(
            "Store the <c> into the <s515b-repository> with { id: \"k2\", n: 99 }.")
        _ = try await session.executeStatement(
            "Retrieve the <all> from the <s515b-repository>.")
        #expect((session.getVariable("all") as? [any Sendable])?.count == 2)
    }

    @Test("A payload for a name that is already bound is refused, and stores nothing")
    func payloadAndBoundNameConflict() async throws {
        let session = REPLSession(suppressLogPrefix: true)
        _ = try await session.executeStatement(
            "Create the <ticket> with { id: 9, state: \"old\" }.")

        let result = try await session.executeStatement(
            "Store the <ticket> into the <s515c-repository> with { id: 1, state: \"new\" }.")
        guard case .error(let message) = result else {
            Issue.record("expected an error, got \(result)")
            return
        }
        #expect(message.contains("already bound"))

        // The refusal comes before the write: a statement that failed left
        // nothing behind.
        _ = try await session.executeStatement(
            "Retrieve the <all> from the <s515c-repository>.")
        #expect((session.getVariable("all") as? [any Sendable])?.isEmpty == true)

        // And the original value is untouched.
        let bound = session.getVariable("ticket") as? [String: any Sendable]
        #expect(bound?["id"] as? Int == 9)
    }

    @Test("A payload alongside a <result: source> specifier is refused")
    func payloadAndSpecifierConflict() async throws {
        let session = REPLSession(suppressLogPrefix: true)
        _ = try await session.executeStatement("Create the <src> with { id: 9 }.")

        let result = try await session.executeStatement(
            "Store the <stored: src> into the <s515d-repository> with { id: 1 }.")
        guard case .error(let message) = result else {
            Issue.record("expected an error, got \(result)")
            return
        }
        #expect(message.contains("both name the value to store"))

        _ = try await session.executeStatement(
            "Retrieve the <all> from the <s515d-repository>.")
        #expect((session.getVariable("all") as? [any Sendable])?.isEmpty == true)
    }

    @Test("The payload does not leak into the next Store")
    func payloadIsStatementLocal() async throws {
        // `_with_` is a per-statement framework variable. If it survived the
        // statement, the plain Store below would store the payload again.
        let session = REPLSession(suppressLogPrefix: true)
        _ = try await session.executeStatement(
            "Store the <first> into the <s515e-repository> with { id: 1, state: \"new\" }.")
        _ = try await session.executeStatement(
            "Create the <second> with { id: 2, state: \"done\" }.")
        let result = try await session.executeStatement(
            "Store the <second> into the <s515e-repository>.")
        #expect(result.isSuccess)

        _ = try await session.executeStatement(
            "Retrieve the <row> from the <s515e-repository> where <id> is 2.")
        let row = session.getVariable("row") as? [String: any Sendable]
        #expect(row?["state"] as? String == "done")
    }

    @Test("A list payload stores one row per element, as a bound list does")
    func listPayloadFlattens() async throws {
        let session = REPLSession(suppressLogPrefix: true)
        let result = try await session.executeStatement(
            "Store the <rows> into the <s515f-repository> with [ { id: 1 }, { id: 2 } ].")
        #expect(result.isSuccess)

        _ = try await session.executeStatement(
            "Retrieve the <all> from the <s515f-repository>.")
        #expect((session.getVariable("all") as? [any Sendable])?.count == 2)
    }

    @Test("The bare and <result: source> spellings still work untouched")
    func existingSpellingsUnaffected() async throws {
        let session = REPLSession(suppressLogPrefix: true)
        _ = try await session.executeStatement("Create the <u> with { id: 1, name: \"Ada\" }.")

        let bare = try await session.executeStatement(
            "Store the <u> into the <s515g-repository>.")
        #expect(bare.isSuccess)

        let immutable = try await session.executeStatement(
            "Store the <kept: u> into the <s515h-repository>.")
        #expect(immutable.isSuccess)
        #expect((session.getVariable("kept") as? [String: any Sendable])?["name"] as? String == "Ada")
    }
}
