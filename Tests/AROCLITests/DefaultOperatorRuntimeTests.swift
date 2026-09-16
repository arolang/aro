// ============================================================
// DefaultOperatorRuntimeTests.swift
// AROCLI — `default` returns a value, not a boolean (GitLab #547, #548)
// ============================================================
//
// The bug the issue reported was silent: `Create the <count> with
// <settings: retries> or 3.` — the spelling ARO-0047 and Book Chapter 23
// both taught — bound `true`, because `or` evaluates truthiness. Nothing
// complained; the wrong value only surfaced wherever it was used.
//
// These tests run the statements for real and check the *value*, which
// is the only thing that could have caught it. The falsy cases matter
// most: an explicit `false`, `0` or `""` is a value the author wrote, so
// it must win over the default — defaulting on falsiness is the classic
// footgun and ARO does not do it. Only a missing variable, a missing
// field, or `nil` falls through.

import Testing
import Foundation
import ARORuntime
@testable import AROCLI

@Suite("default operator, at runtime (#547)", .serialized)
struct DefaultOperatorRuntimeTests {

    private func run(_ statements: String...) async throws -> (REPLSession, [REPLResult]) {
        let session = REPLSession(suppressLogPrefix: true)
        var results: [REPLResult] = []
        for statement in statements {
            results.append(try await session.executeStatement(statement))
        }
        return (session, results)
    }

    // MARK: - The issue's repro

    @Test("A present field wins: the repro binds 5, not true")
    func presentFieldWins() async throws {
        let (session, results) = try await run(
            "Create the <settings> with { retries: 5 }.",
            "Create the <count> with <settings: retries> default 3."
        )
        #expect(results.allSatisfy { $0.isSuccess })
        #expect(session.getVariable("count") as? Int == 5)
    }

    @Test("A missing field falls through to the default")
    func missingFieldDefaults() async throws {
        let (session, results) = try await run(
            "Create the <settings> with { retries: 5 }.",
            "Create the <count> with <settings: timeout> default 3."
        )
        #expect(results.allSatisfy { $0.isSuccess })
        #expect(session.getVariable("count") as? Int == 3)
    }

    @Test("An unbound variable falls through to the default")
    func unboundVariableDefaults() async throws {
        let (session, results) = try await run(
            "Create the <count> with <never-bound> default 7."
        )
        #expect(results.allSatisfy { $0.isSuccess })
        #expect(session.getVariable("count") as? Int == 7)
    }

    // MARK: - Present-but-falsy values win

    @Test("`false` is a value: it wins over the default")
    func falseWins() async throws {
        let (session, results) = try await run(
            "Create the <flags> with { verbose: false }.",
            "Create the <verbose> with <flags: verbose> default true."
        )
        #expect(results.allSatisfy { $0.isSuccess })
        #expect(session.getVariable("verbose") as? Bool == false)
    }

    @Test("`0` is a value: it wins over the default")
    func zeroWins() async throws {
        let (session, results) = try await run(
            "Create the <limits> with { retries: 0 }.",
            "Create the <retries> with <limits: retries> default 9."
        )
        #expect(results.allSatisfy { $0.isSuccess })
        #expect(session.getVariable("retries") as? Int == 0)
    }

    @Test("An empty string is a value: it wins over the default")
    func emptyStringWins() async throws {
        let (session, results) = try await run(
            #"Create the <config> with { prefix: "" }."#,
            #"Create the <prefix> with <config: prefix> default "fallback"."#
        )
        #expect(results.allSatisfy { $0.isSuccess })
        #expect(session.getVariable("prefix") as? String == "")
    }

    // MARK: - Precedence, evaluated

    @Test("`<a> default 3 > 2` compares the defaulted value")
    func comparisonSeesTheDefaultedValue() async throws {
        let (session, results) = try await run(
            "Create the <s> with { n: 5 }.",
            "Create the <ok> with <s: missing> default 3 > 2."
        )
        #expect(results.allSatisfy { $0.isSuccess })
        #expect(session.getVariable("ok") as? Bool == true)
    }

    @Test("Arithmetic binds tighter: `default 1 + 2` defaults to three")
    func arithmeticBindsTighter() async throws {
        let (session, results) = try await run(
            "Create the <s> with { n: 5 }.",
            "Create the <n> with <s: missing> default 1 + 2."
        )
        #expect(results.allSatisfy { $0.isSuccess })
        #expect(session.getVariable("n") as? Int == 3)
    }

    @Test("Defaults chain: the first present value wins")
    func defaultsChain() async throws {
        let (session, results) = try await run(
            "Create the <s> with { b: 2 }.",
            "Create the <n> with <s: a> default <s: b> default 42."
        )
        #expect(results.allSatisfy { $0.isSuccess })
        #expect(session.getVariable("n") as? Int == 2)
    }

    @Test("`or` stays boolean — it is a condition, not a fallback")
    func orRemainsBoolean() async throws {
        // Both operands non-boolean, so this pins what `or` *returns*: the
        // truthiness of the two, never either value. Written with variables
        // on both sides because a literal operand is now rejected outright
        // (GitLab #575) — see `orOverALiteralIsRejected` below.
        let (session, results) = try await run(
            "Create the <settings> with { retries: 5, backoff: 3 }.",
            "Create the <truthy> with <settings: retries> or <settings: backoff>."
        )
        #expect(results.allSatisfy { $0.isSuccess })
        #expect(session.getVariable("truthy") as? Bool == true)
    }

    @Test("`or` over a literal is rejected rather than silently binding true")
    func orOverALiteralIsRejected() async throws {
        // The completion of this issue's story (GitLab #575). #547 gave the
        // language `default` and documented that `or` is not it, in three
        // places — but `<settings: retries> or 3` still compiled, passed
        // `aro check`, exited `[OK]` and bound `true`. A non-boolean literal
        // under `or` has a truthiness fixed at parse time, so it can only pin
        // the result; there is no program that wants it.
        let (_, results) = try await run(
            "Create the <settings> with { retries: 5 }.",
            "Create the <truthy> with <settings: retries> or 3."
        )
        guard case .error(let message) = try #require(results.last) else {
            Issue.record("expected the statement to be rejected, got \(results.last!)")
            return
        }
        #expect(message.contains("`or` is a boolean operator"))
        #expect(message.contains("constantly true"))
        // The `default` suggestion rides on the diagnostic's hints, which the
        // REPL does not print; `LogicalLiteralTests` covers those.
    }

    // MARK: - Empty literals (#548)

    @Test("`[]` and `{}` bind an empty list and an empty record")
    func emptyLiteralsBind() async throws {
        let (session, results) = try await run(
            "Create the <items> with [].",
            "Create the <record> with {}."
        )
        #expect(results.allSatisfy { $0.isSuccess })
        #expect((session.getVariable("items") as? [any Sendable])?.isEmpty == true)
        #expect((session.getVariable("record") as? [String: any Sendable])?.isEmpty == true)
    }

    @Test("An empty list is a value, so it wins over a default")
    func emptyListIsAValue() async throws {
        let (session, results) = try await run(
            "Create the <holder> with { items: [] }.",
            "Create the <items> with <holder: items> default [1, 2]."
        )
        #expect(results.allSatisfy { $0.isSuccess })
        #expect((session.getVariable("items") as? [any Sendable])?.isEmpty == true)
    }

    @Test("`empty` is a usable name")
    func emptyIsAUsableName() async throws {
        let (session, results) = try await run(
            "Create the <empty> with [].",
            "Create the <flags> with { empty: true }."
        )
        #expect(results.allSatisfy { $0.isSuccess })
        #expect((session.getVariable("empty") as? [any Sendable])?.isEmpty == true)
    }
}
