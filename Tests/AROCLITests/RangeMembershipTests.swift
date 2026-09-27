// ============================================================
// RangeMembershipTests.swift
// AROCLI — `when <date> in <range>` (GitLab #558)
// ============================================================
//
// ARO-0041 §7 specifies range membership in a guard, and ARO-0042 the
// collection form. `where <field> in <list>` had `in` as a `WhereOperator`,
// and `contains` had it with the operands the other way round — but
// `when <order-date> in <sale-period>` did not parse at all:
//
//     error: Expected '.', but got the keyword 'in'
//
// The runtime could already answer it: `containsValue` has handled
// `ARODateRange` membership in either operand order since ARO-0041. Only the
// surface syntax was missing, so `in` becomes a binary operator and evaluates
// through the code that was already there.

import Testing
import Foundation
import ARORuntime
@testable import AROCLI

@Suite("Range and collection membership in a guard (GitLab #558)", .serialized)
struct RangeMembershipTests {

    private func run(_ statements: String...) async throws -> (REPLSession, [REPLResult]) {
        let session = REPLSession()
        var results: [REPLResult] = []
        for statement in statements {
            results.append(try await session.executeStatement(statement))
        }
        return (session, results)
    }

    // MARK: - The issue's shape

    @Test("A date inside a date-range satisfies the guard")
    func dateInsideRange() async throws {
        let (session, results) = try await run(
            #"Compute the <period-start: date> from "2026-01-01T00:00:00Z"."#,
            #"Compute the <period-end: date> from "2026-12-31T00:00:00Z"."#,
            "Create the <sale-period: date-range> from <period-start> to <period-end>.",
            #"Compute the <order-date: date> from "2026-06-01T00:00:00Z"."#,
            """
            when <order-date> in <sale-period> {
                Compute the <inside> from true.
            }
            """
        )
        #expect(results.allSatisfy { $0.isSuccess })
        #expect(session.getVariable("inside") as? Bool == true)
    }

    @Test("A date outside the range skips the block")
    func dateOutsideRange() async throws {
        let (session, results) = try await run(
            #"Compute the <period-start: date> from "2020-01-01T00:00:00Z"."#,
            #"Compute the <period-end: date> from "2020-12-31T00:00:00Z"."#,
            "Create the <period: date-range> from <period-start> to <period-end>.",
            #"Compute the <later: date> from "2026-06-01T00:00:00Z"."#,
            """
            when <later> in <period> {
                Compute the <ran> from true.
            }
            """
        )
        #expect(results.allSatisfy { $0.isSuccess })
        #expect(session.getVariable("ran") == nil, "the block must not run")
    }

    // MARK: - As an expression, not only a guard

    @Test("Membership is a value, so it can be computed")
    func membershipIsAValue() async throws {
        let (session, results) = try await run(
            #"Compute the <period-start: date> from "2026-01-01T00:00:00Z"."#,
            #"Compute the <period-end: date> from "2026-12-31T00:00:00Z"."#,
            "Create the <period: date-range> from <period-start> to <period-end>.",
            #"Compute the <mid: date> from "2026-06-01T00:00:00Z"."#,
            #"Compute the <out: date> from "2030-06-01T00:00:00Z"."#,
            "Compute the <a> from <mid> in <period>.",
            "Compute the <b> from <out> in <period>."
        )
        #expect(results.allSatisfy { $0.isSuccess })
        #expect(session.getVariable("a") as? Bool == true)
        #expect(session.getVariable("b") as? Bool == false)
    }

    // MARK: - Collections (ARO-0042)

    @Test("A collection member satisfies the guard")
    func collectionMembership() async throws {
        let (session, results) = try await run(
            #"Create the <tags> with ["red", "green"]."#,
            #"Compute the <hit> from "red" in <tags>."#,
            #"Compute the <miss> from "blue" in <tags>."#
        )
        #expect(results.allSatisfy { $0.isSuccess })
        #expect(session.getVariable("hit") as? Bool == true)
        #expect(session.getVariable("miss") as? Bool == false)
    }

    @Test("`in` is the inverse of `contains`")
    func inverseOfContains() async throws {
        let (session, results) = try await run(
            #"Create the <tags> with ["red"]."#,
            #"Compute the <a> from "red" in <tags>."#,
            #"Compute the <b> from <tags> contains "red"."#
        )
        #expect(results.allSatisfy { $0.isSuccess })
        #expect(session.getVariable("a") as? Bool == true)
        #expect(session.getVariable("b") as? Bool == true)
    }

    // MARK: - Composition

    @Test("`not` composes with membership")
    func notComposes() async throws {
        let (session, results) = try await run(
            #"Create the <tags> with ["red"]."#,
            #"Compute the <a> from not "blue" in <tags>."#
        )
        #expect(results.allSatisfy { $0.isSuccess })
        #expect(session.getVariable("a") as? Bool == true)
    }

    @Test("Membership sits at comparison precedence, so `and` groups around it")
    func precedenceGroupsWithComparisons() async throws {
        let (session, results) = try await run(
            #"Create the <tags> with ["red"]."#,
            #"Create the <others> with ["blue"]."#,
            #"Compute the <a> from "red" in <tags> and "blue" in <others>."#,
            #"Compute the <b> from "red" in <tags> and "red" in <others>."#
        )
        #expect(results.allSatisfy { $0.isSuccess })
        #expect(session.getVariable("a") as? Bool == true)
        #expect(session.getVariable("b") as? Bool == false)
    }

    // MARK: - `in` as a delimiter is untouched

    @Test("for each still reads its own `in`")
    func forEachStillParses() async throws {
        // `in` is a lexer keyword because of this header. Giving it an infix
        // precedence must not let an expression swallow it — every delimiter
        // use consumes it with `expect(.in)` before expression parsing starts.
        // (Loop bindings stay inside the body, so this asserts the header
        // parses and the loop runs, not that `n` escapes.)
        let (_, results) = try await run(
            #"Create the <items> with [1, 2, 3]."#,
            """
            for each <n> in <items> {
                Log <n> to the <console>.
            }
            """
        )
        #expect(results.allSatisfy { $0.isSuccess })
    }

    @Test("A list literal collection in for each still parses")
    func forEachLiteralStillParses() async throws {
        let (_, results) = try await run(
            """
            for each <n> in [1, 2] {
                Compute the <seen> from <n>.
            }
            """
        )
        #expect(results.allSatisfy { $0.isSuccess })
    }
}
