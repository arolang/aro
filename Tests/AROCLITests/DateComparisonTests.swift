// ============================================================
// DateComparisonTests.swift
// AROCLI — Chapter 42 §42.8 as written (GitLab #516)
// ============================================================
//
// The Language Guide has always shown temporal comparison as
//
//     when <booking-date> before <deadline> {
//         Log "Booking accepted" to the <console>.
//     }
//
// and neither half of that parsed: `before`/`after` were not
// operators, and `when` was only a statement suffix, never a block.
// The book is the layer that documents the language, so the code
// moved to meet it rather than the other way round.

import Testing
import Foundation
import ARORuntime
@testable import AROCLI

@Suite("Date comparisons", .serialized)
struct DateComparisonTests {

    private func run(_ statements: String...) async throws -> (REPLSession, [REPLResult]) {
        let session = REPLSession(suppressLogPrefix: true)
        var results: [REPLResult] = []
        for statement in statements {
            results.append(try await session.executeStatement(statement))
        }
        return (session, results)
    }

    // MARK: - The book's own examples

    @Test("Chapter 42's booking example runs as printed")
    func bookingExample() async throws {
        let (session, results) = try await run(
            #"Create the <booking-date> with "2026-01-01T00:00:00Z"."#,
            #"Create the <deadline> with "2026-06-01T00:00:00Z"."#,
            """
            when <booking-date> before <deadline> {
                Compute the <accepted> from true.
            }
            """
        )
        #expect(results.allSatisfy { $0.isSuccess })
        #expect(session.getVariable("accepted") as? Bool == true)
    }

    @Test("A false guard skips the block")
    func falseGuardSkips() async throws {
        let (session, results) = try await run(
            #"Create the <past> with "2020-01-01T00:00:00Z"."#,
            #"Create the <future> with "2030-01-01T00:00:00Z"."#,
            """
            when <past> after <future> {
                Compute the <ran> from true.
            }
            """
        )
        #expect(results.allSatisfy { $0.isSuccess })
        #expect(session.getVariable("ran") == nil, "the block must not run")
    }

    // MARK: - The operators

    @Test("before and after order two instants")
    func operatorsOrderInstants() async throws {
        let (session, results) = try await run(
            #"Create the <early> with "2026-01-01T00:00:00Z"."#,
            #"Create the <late> with "2026-06-01T00:00:00Z"."#,
            "Compute the <a> from <early> before <late>.",
            "Compute the <b> from <early> after <late>.",
            "Compute the <c> from <late> after <early>."
        )
        #expect(results.allSatisfy { $0.isSuccess })
        #expect(session.getVariable("a") as? Bool == true)
        #expect(session.getVariable("b") as? Bool == false)
        #expect(session.getVariable("c") as? Bool == true)
    }

    @Test("They work as a statement-suffix guard too")
    func suffixGuard() async throws {
        let (session, results) = try await run(
            #"Create the <early> with "2026-01-01T00:00:00Z"."#,
            #"Create the <late> with "2026-06-01T00:00:00Z"."#,
            "Compute the <flag> from true when <early> before <late>."
        )
        #expect(results.allSatisfy { $0.isSuccess })
        #expect(session.getVariable("flag") as? Bool == true)
    }

    @Test("They compose with and/or at the comparison rung")
    func composesWithLogicals() async throws {
        let (session, results) = try await run(
            #"Create the <early> with "2026-01-01T00:00:00Z"."#,
            #"Create the <late> with "2026-06-01T00:00:00Z"."#,
            "Compute the <both> from <early> before <late> and <late> after <early>."
        )
        #expect(results.allSatisfy { $0.isSuccess })
        #expect(session.getVariable("both") as? Bool == true)
    }

    // MARK: - The when block, independent of dates

    @Test("A when block groups statements under one condition")
    func blockGroupsStatements() async throws {
        let (session, results) = try await run(
            "Create the <n> with 5.",
            """
            when <n> > 3 {
                Compute the <first> from 1.
                Compute the <second> from 2.
            }
            """
        )
        #expect(results.allSatisfy { $0.isSuccess })
        #expect(session.getVariable("first") as? Int == 1)
        #expect(session.getVariable("second") as? Int == 2)
    }

    @Test("What the block binds is visible after it")
    func bindingsEscapeTheBlock() async throws {
        // A guarded block groups statements; it does not introduce a
        // scope, so this reads the same as putting the guard on each.
        let (session, results) = try await run(
            "Create the <n> with 5.",
            """
            when <n> > 3 {
                Compute the <inside> from 42.
            }
            """,
            "Compute the <doubled> from <inside> * 2."
        )
        #expect(results.allSatisfy { $0.isSuccess })
        #expect(session.getVariable("doubled") as? Int == 84)
    }

    @Test("`before` and `after` are still ordinary names")
    func wordsAreNotReserved() async throws {
        // The first cut of this feature made them lexer keywords, which
        // silently broke every program with a variable called <after> —
        // including one of this repo's own tests. They are recognised in
        // operator position only (GitLab #516, and #497 for why).
        let (session, results) = try await run(
            "Create the <before> with 1.",
            "Create the <after> with 2.",
            "Compute the <delta> from <after> - <before>.",
            #"Create the <before-tax> with 100."#
        )
        #expect(results.allSatisfy { $0.isSuccess })
        #expect(session.getVariable("delta") as? Int == 1)
        #expect(session.getVariable("before-tax") as? Int == 100)
    }

    @Test("`When the <x> …` is still ARO-0015's test statement")
    func testStatementStillParses() async throws {
        // The block form must not swallow the Given/When/Then syntax:
        // there `When` is the action verb and an article follows it.
        // Adding the block broke every test suite in the repo until
        // this one token of lookahead was put back.
        let session = REPLSession(suppressLogPrefix: true)
        let defined = try await session.defineFeatureSet(
            name: "length-of-hello",
            activity: "String Utils Test",
            statements: [
                #"Given the <text> with "hello"."#,
                "When the <len> from the <get-length>.",
                "Then the <len> with 5."
            ])
        guard case .error(let message) = defined else { return }
        Issue.record("the Given/When/Then form must still parse: \(message)")
    }

    @Test("A date compared with a non-date is an error, not a silent false")
    func mismatchedComparisonErrors() async throws {
        let (_, results) = try await run(
            #"Create the <date> with "2026-01-01T00:00:00Z"."#,
            #"Create the <word> with "banana"."#,
            "Compute the <oops> from <date> before <word>."
        )
        // "banana" is not a date and not a number: the comparison
        // cannot answer, and says so rather than guessing.
        guard case .error = results[2] else {
            Issue.record("expected an error, got \(results[2])")
            return
        }
    }
}
