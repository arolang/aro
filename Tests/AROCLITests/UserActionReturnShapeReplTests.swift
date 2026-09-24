// ============================================================
// UserActionReturnShapeReplTests.swift
// AROCLI — a user-defined action's result at a REPL call site (GitLab #504)
// ============================================================
//
// The runtime suite pins what `Return` records; this pins what a caller
// actually binds one layer up, through the session the notebook kernel and
// `aro repl --json` drive. A returned list used to bind as its JSON text, so
// the value sitting in the session was a `String` and `length` counted its
// characters.

import Testing
import Foundation
import ARORuntime
@testable import AROCLI

@Suite("User-action return shapes in the REPL (GitLab #504)", .serialized)
struct UserActionReturnShapeReplTests {

    /// Run `statements` against one session, with `action` declared as a
    /// companion feature set — the shape the REPL uses to make a
    /// user-defined action callable (ARO-0081).
    private func run(
        action: String,
        _ statements: String...
    ) async throws -> (REPLSession, [REPLResult]) {
        let session = REPLSession()
        var results: [REPLResult] = []
        for statement in statements {
            results.append(try await session.executeStatement(statement, companions: [action]))
        }
        return (session, results)
    }

    @Test("A returned list binds as a list, not as its JSON text")
    func returnedListBindsAsList() async throws {
        let (session, results) = try await run(
            action: """
            (PaidOnly: Action takes <orders>) {
                Extract the <all> from the <input: orders>.
                Filter the <paid> from the <all> where <status> == "paid".
                Return an <OK: status> with { paid: <paid> }.
            }
            """,
            #"Create the <orders> with [{ id: 1, status: "paid" }, { id: 2, status: "open" }, { id: 3, status: "paid" }]."#,
            "Application.PaidOnly the <res> from <orders>.",
            "Extract the <paid-list> from the <res: paid>.",
            "Compute the <n: length> from <paid-list>."
        )
        #expect(results.allSatisfy { $0.isSuccess })
        #expect((session.getVariable("paid-list") as? [any Sendable])?.count == 2)
        // `length` over the JSON text counted its 51 characters.
        #expect(session.getVariable("n") as? Int == 2)
    }

    @Test("A returned nested record binds as a record")
    func returnedRecordBindsAsRecord() async throws {
        let (session, results) = try await run(
            action: """
            (Describe: Action takes <name>) {
                Extract the <n> from the <input: name>.
                Return an <OK: status> with { profile: { name: <n>, age: 36 } }.
            }
            """,
            #"Application.Describe the <res> from "Ada"."#,
            "Extract the <profile> from the <res: profile>.",
            "Extract the <who> from the <profile: name>."
        )
        #expect(results.allSatisfy { $0.isSuccess })
        #expect(session.getVariable("who") as? String == "Ada")
    }

    @Test("Scalars are untouched")
    func scalarsUntouched() async throws {
        let (session, results) = try await run(
            action: """
            (Doubler: Action takes <number>) {
                Extract the <n> from the <input: number>.
                Compute the <doubled> from <n> * 2.
                Return an <OK: status> with { doubled: <doubled> }.
            }
            """,
            "Application.Doubler the <res> from 21.",
            "Extract the <doubled> from the <res: doubled>."
        )
        #expect(results.allSatisfy { $0.isSuccess })
        #expect(session.getVariable("doubled") as? Int == 42)
    }
}
