// ============================================================
// ExpressionPrecedenceTests.swift
// AROCLI — comparison/logical precedence end to end (GitLab #520)
// ============================================================
//
// The parse-tree shapes are pinned in
// Tests/AROParserTests/ExpressionTests.swift; these run the same
// business rules through the interpreter, because the bug was only
// ever visible as a *runtime* type error at a distance:
//
//     Compute the <ok> from <n> >= 15 or <vip>.
//     → Type mismatch: Cannot convert Bool to number
//
// The parser had rewritten it into `<n> >= 15 or <n> >= <vip>`.

import Testing
import Foundation
import ARORuntime
@testable import AROCLI

@Suite("Expression precedence (GitLab #520)", .serialized)
struct ExpressionPrecedenceTests {

    /// Runs the shared setup bindings plus the given statements.
    private func run(_ statements: String...) async throws -> (REPLSession, [REPLResult]) {
        let session = REPLSession()
        var results: [REPLResult] = []
        for statement in [
            "Create the <n> with 20.",
            "Create the <vip> with true.",
            "Create the <plain> with false.",
            #"Create the <status> with "paid"."#
        ] + statements {
            results.append(try await session.executeStatement(statement))
        }
        return (session, results)
    }

    @Test("comparison or bare boolean — the issue's repro")
    func comparisonOrBool() async throws {
        let (session, results) = try await run("Compute the <ok> from <n> >= 15 or <vip>.")
        #expect(results.allSatisfy { $0.isSuccess })
        #expect(session.getVariable("ok") as? Bool == true)
    }

    @Test("a false comparison still consults the flag")
    func falseComparisonConsultsFlag() async throws {
        // The old rewrite made this `<n> >= 99 or <n> >= <vip>` — an error,
        // never the `or`'s actual answer.
        let (session, results) = try await run(
            "Compute the <ok> from <n> >= 99 or <vip>.",
            "Compute the <nope> from <n> >= 99 or <plain>."
        )
        #expect(results.allSatisfy { $0.isSuccess })
        #expect(session.getVariable("ok") as? Bool == true)
        #expect(session.getVariable("nope") as? Bool == false)
    }

    @Test("comparison and bare boolean")
    func comparisonAndBool() async throws {
        let (session, results) = try await run(
            "Compute the <yes> from <n> >= 15 and <vip>.",
            "Compute the <no> from <n> >= 15 and <plain>."
        )
        #expect(results.allSatisfy { $0.isSuccess })
        #expect(session.getVariable("yes") as? Bool == true)
        #expect(session.getVariable("no") as? Bool == false)
    }

    @Test("bare boolean or comparison, and comparison or comparison")
    func boolOrComparisonAndPairs() async throws {
        let (session, results) = try await run(
            "Compute the <a> from <vip> or <n> >= 99.",
            "Compute the <b> from <n> >= 15 or <n> < 5.",
            "Compute the <c> from <n> >= 18 and <n> < 65."
        )
        #expect(results.allSatisfy { $0.isSuccess })
        #expect(session.getVariable("a") as? Bool == true)
        #expect(session.getVariable("b") as? Bool == true)
        #expect(session.getVariable("c") as? Bool == true)
    }

    @Test("and binds tighter than or")
    func andBindsTighterThanOr() async throws {
        // false or (true and true) = true. Grouped the other way,
        // (false or true) and false would be false.
        let (session, results) = try await run(
            "Compute the <mixed> from <plain> or <n> >= 15 and <vip>.",
            "Compute the <other> from <vip> or <n> >= 15 and <plain>."
        )
        #expect(results.allSatisfy { $0.isSuccess })
        #expect(session.getVariable("mixed") as? Bool == true)
        #expect(session.getVariable("other") as? Bool == true)
    }

    @Test("not negates the whole comparison")
    func notOverComparison() async throws {
        let (session, results) = try await run(
            "Compute the <under> from not <n> >= 15.",
            "Compute the <over> from not <n> >= 99."
        )
        #expect(results.allSatisfy { $0.isSuccess })
        #expect(session.getVariable("under") as? Bool == false)
        #expect(session.getVariable("over") as? Bool == true)
    }

    @Test("arithmetic inside a comparison inside an or")
    func arithmeticInsideComparison() async throws {
        let (session, results) = try await run(
            "Compute the <ok> from <n> + 5 >= 15 or <plain>.",
            "Compute the <also> from <n> * 2 >= 15 and <n> - 1 < 100."
        )
        #expect(results.allSatisfy { $0.isSuccess })
        #expect(session.getVariable("ok") as? Bool == true)
        #expect(session.getVariable("also") as? Bool == true)
    }

    @Test("parentheses are now redundant, not load-bearing")
    func parenthesesStillWork() async throws {
        let (session, results) = try await run(
            "Compute the <bare> from <n> >= 15 or <vip>.",
            "Compute the <parens> from (<n> >= 15) or <vip>.",
            "Compute the <grouped> from <n> >= 15 and (<plain> or <vip>)."
        )
        #expect(results.allSatisfy { $0.isSuccess })
        #expect(session.getVariable("bare") as? Bool == true)
        #expect(session.getVariable("parens") as? Bool == true)
        #expect(session.getVariable("grouped") as? Bool == true)
    }

    @Test("when guards use the same grouping")
    func whenGuardsAgree() async throws {
        // A guard that fails skips the statement, so the binding never
        // appears — that absence is the assertion.
        let (session, results) = try await run(
            "Create the <hit> with true when <n> >= 15 or <vip>.",
            "Create the <miss> with true when <n> >= 99 or <plain>."
        )
        #expect(results.allSatisfy { $0.isSuccess })
        #expect(session.getVariable("hit") as? Bool == true)
        #expect(session.getVariable("miss") == nil)
    }

    @Test("`or` over a non-boolean operand is untouched")
    func orOverNonBooleanOperand() async throws {
        // A non-boolean on both sides of `or`. The left operand is a variable
        // reference, not a comparison, so the removed rewrite never applied
        // to it — this pins that it still parses and evaluates. (What `or`
        // *returns* for non-boolean operands — the value or a boolean — is a
        // separate question, unchanged here.)
        //
        // Both sides are variables: the literal spelling this used to carry,
        // `<settings: retries> or 3`, is rejected since GitLab #575 because
        // a literal's truthiness is fixed at parse time. That is a separate
        // check, and pinning it here would confuse the two.
        let (_, results) = try await run(
            "Create the <settings> with { retries: 5, backoff: 3 }.",
            "Create the <retries> with <settings: retries> or <settings: backoff>."
        )
        #expect(results.allSatisfy { $0.isSuccess })
    }

    @Test("a where clause chained with and/or still filters (GitLab #498)")
    func whereChainingUnaffected() async throws {
        let (session, results) = try await run(
            #"Create the <rows> with [{ status: "paid", qty: 5 }, { status: "paid", qty: 1 }, { status: "open", qty: 9 }]."#,
            #"Filter the <big-paid> from the <rows> where <status> == "paid" and <qty> > 2."#,
            "Compute the <how-many: length> from <big-paid>."
        )
        #expect(results.allSatisfy { $0.isSuccess })
        #expect(session.getVariable("how-many") as? Int == 1)
    }
}
