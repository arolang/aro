// ============================================================
// UpdateIntoRepositorySessionTests.swift
// AROCLI — `Update … into <repository>` in live sessions (GitLab #505)
// ============================================================
//
// Chapter 46's accumulator pattern is Store once, then
// `Update the <upd> into the <acc-repository> [where …]` per element.
// UpdateAction had no repository path at all — `into` was not even a
// valid preposition for it — so the statement failed with the generic
// "Cannot update the upd into the acc-repository" everywhere, and
// interactive sessions (where people meet the pattern first) had to
// fall back to Store-per-item + aggregate on read. These tests run
// the documented shapes through the same session `aro repl --json`
// uses; UpdateIntoRepositoryTests in ARORuntimeTests would be the
// place for storage-level coverage.

import Testing
import Foundation
import ARORuntime
@testable import AROCLI

@Suite("Update into repository in a session (#505)", .serialized)
struct UpdateIntoRepositorySessionTests {

    @Test("Update with a where clause replaces the matching row's fields")
    func updateWithWhereClause() async throws {
        let session = REPLSession()
        _ = try await session.executeStatement(
            "Create the <init> with { id: \"c1\", total: 0 }.")
        _ = try await session.executeStatement(
            "Store the <seeded: init> into the <acc-repository>.")
        _ = try await session.executeStatement(
            "Create the <upd> with { id: \"c1\", total: 5 }.")
        let result = try await session.executeStatement(
            "Update the <changed: upd> into the <acc-repository> where <id> is \"c1\".")
        #expect(result.isSuccess)

        _ = try await session.executeStatement(
            "Retrieve the <row> from the <acc-repository> where <id> is \"c1\".")
        let row = session.getVariable("row") as? [String: any Sendable]
        #expect(row?["total"] as? Int == 5)

        // Still exactly one row — Update replaced, it did not insert.
        _ = try await session.executeStatement(
            "Retrieve the <rows> from the <acc-repository>.")
        #expect((session.getVariable("rows") as? [any Sendable])?.count == 1)
    }

    @Test("Update without a where clause matches by the value's id")
    func updateByIdentityField() async throws {
        let session = REPLSession()
        _ = try await session.executeStatement(
            "Create the <init> with { id: \"acc\", sum: 0, count: 0 }.")
        _ = try await session.executeStatement(
            "Store the <seeded: init> into the <sum-repository>.")
        _ = try await session.executeStatement(
            "Create the <upd> with { id: \"acc\", sum: 10, count: 4 }.")
        let result = try await session.executeStatement(
            "Update the <changed: upd> into the <sum-repository>.")
        #expect(result.isSuccess)

        _ = try await session.executeStatement(
            "Retrieve the <row> from the <sum-repository> where <id> is \"acc\".")
        let row = session.getVariable("row") as? [String: any Sendable]
        #expect(row?["sum"] as? Int == 10)
        #expect(row?["count"] as? Int == 4)
    }

    @Test("Update merges — fields the update omits survive")
    func partialUpdatePreservesOtherFields() async throws {
        let session = REPLSession()
        _ = try await session.executeStatement(
            "Create the <init> with { id: \"u1\", name: \"Ada\", role: \"admin\" }.")
        _ = try await session.executeStatement(
            "Store the <seeded: init> into the <user-repository>.")
        _ = try await session.executeStatement(
            "Create the <patch> with { role: \"owner\" }.")
        let result = try await session.executeStatement(
            "Update the <changed: patch> into the <user-repository> where <id> is \"u1\".")
        #expect(result.isSuccess)

        _ = try await session.executeStatement(
            "Retrieve the <row> from the <user-repository> where <id> is \"u1\".")
        let row = session.getVariable("row") as? [String: any Sendable]
        #expect(row?["role"] as? String == "owner")
        #expect(row?["name"] as? String == "Ada")
    }

    @Test("The immutable pattern binds the fresh name to the updated row")
    func immutablePatternBindsResult() async throws {
        let session = REPLSession()
        _ = try await session.executeStatement(
            "Create the <init> with { id: \"c1\", total: 1 }.")
        _ = try await session.executeStatement(
            "Store the <seeded: init> into the <bind-repository>.")
        _ = try await session.executeStatement(
            "Create the <upd> with { id: \"c1\", total: 2 }.")
        _ = try await session.executeStatement(
            "Update the <after: upd> into the <bind-repository>.")
        let after = session.getVariable("after") as? [String: any Sendable]
        #expect(after?["total"] as? Int == 2)
    }

    @Test("No matching entry is an error — Update never inserts")
    func noMatchErrors() async throws {
        let session = REPLSession()
        _ = try await session.executeStatement(
            "Create the <init> with { id: \"c1\", total: 0 }.")
        _ = try await session.executeStatement(
            "Store the <seeded: init> into the <miss-repository>.")
        _ = try await session.executeStatement(
            "Create the <upd> with { id: \"c1\", total: 5 }.")
        let result = try await session.executeStatement(
            "Update the <changed: upd> into the <miss-repository> where <id> is \"ghost\".")
        guard case .error(let message) = result else {
            Issue.record("expected an error, got \(result)")
            return
        }
        #expect(message.contains("miss-repository"))

        // The row is untouched.
        _ = try await session.executeStatement(
            "Retrieve the <row> from the <miss-repository> where <id> is \"c1\".")
        let row = session.getVariable("row") as? [String: any Sendable]
        #expect(row?["total"] as? Int == 0)
    }

    @Test("`into` a non-repository target keeps the pre-#505 refusal")
    func intoNonRepositoryErrors() async throws {
        let session = REPLSession()
        _ = try await session.executeStatement(
            "Create the <v> with { a: 1 }.")
        let result = try await session.executeStatement(
            "Update the <changed: v> into the <plain-thing>.")
        guard case .error(let message) = result else {
            Issue.record("expected an error, got \(result)")
            return
        }
        #expect(message.contains("plain-thing"))
    }

    @Test("Chapter 46 accumulator: repeated Update accumulates across cells")
    func accumulatorPattern() async throws {
        let session = REPLSession()
        _ = try await session.executeStatement(
            "Create the <init> with { id: \"acc\", sum: 0, count: 0 }.")
        _ = try await session.executeStatement(
            "Store the <seeded: init> into the <agg-repository>.")

        for (step, value) in [1, 2, 3, 4].enumerated() {
            _ = try await session.executeStatement(
                "Retrieve the <cur\(step)> from the <agg-repository> where <id> is \"acc\".")
            _ = try await session.executeStatement(
                "Extract the <prev-sum\(step)> from the <cur\(step): sum>.")
            _ = try await session.executeStatement(
                "Extract the <prev-count\(step)> from the <cur\(step): count>.")
            _ = try await session.executeStatement(
                "Compute the <new-sum\(step)> from <prev-sum\(step)> + \(value).")
            _ = try await session.executeStatement(
                "Compute the <new-count\(step)> from <prev-count\(step)> + 1.")
            _ = try await session.executeStatement(
                "Create the <upd\(step)> with { id: \"acc\", sum: <new-sum\(step)>, count: <new-count\(step)> }.")
            let result = try await session.executeStatement(
                "Update the <after\(step): upd\(step)> into the <agg-repository>.")
            #expect(result.isSuccess)
        }

        _ = try await session.executeStatement(
            "Retrieve the <final> from the <agg-repository> where <id> is \"acc\".")
        let final = session.getVariable("final") as? [String: any Sendable]
        #expect(final?["sum"] as? Int == 10)
        #expect(final?["count"] as? Int == 4)

        // Accumulation, not append: one row after four updates.
        _ = try await session.executeStatement(
            "Retrieve the <all> from the <agg-repository>.")
        #expect((session.getVariable("all") as? [any Sendable])?.count == 1)
    }
}
