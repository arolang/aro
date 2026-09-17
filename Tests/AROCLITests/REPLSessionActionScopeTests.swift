// ============================================================
// REPLSessionActionScopeTests.swift
// AROCLI — an action defined at the prompt is callable (GitLab #576)
// ============================================================
//
// A statement is compiled as a program of one, and semantic analysis
// resolves `Application.<Name>` against the program it is given. The
// machinery for compiling the session's other definitions alongside it
// existed — `executeStatement(_:companions:)` — but the interactive prompt
// and piped stdin both went through the one-argument overload, which passed
// an empty list. So `Action` was the one business activity whose whole point
// is reuse, and the REPL was the one place it could not be reused.

import Testing
import Foundation
@testable import AROCLI

@Suite("Session-scoped user actions in the REPL (#576)", .serialized)
struct REPLSessionActionScopeTests {

    private let doubled = """
    (Doubled: Action takes <number>) {
        Extract the <n> from the <input: number>.
        Compute the <out> from <n> * 2.
        Return an <OK: status> with { value: <out> }.
    }
    """

    /// Define `source` as a feature set, then run `statements` — the
    /// define-then-call flow the issue reports, through the same
    /// single-argument entry point the prompt uses.
    private func defineThenRun(
        _ definition: String,
        named name: String,
        activity: String = "Action takes <number>",
        _ statements: String...
    ) async throws -> (REPLSession, [REPLResult]) {
        let session = REPLSession(suppressLogPrefix: true)
        _ = try await session.defineFeatureSet(
            name: name, activity: activity, source: definition
        )
        var results: [REPLResult] = []
        for statement in statements {
            results.append(try await session.executeStatement(statement))
        }
        return (session, results)
    }

    // MARK: - The issue's repro

    @Test("An action defined at the prompt is callable on the next line")
    func definedActionIsCallable() async throws {
        let (session, results) = try await defineThenRun(
            doubled, named: "Doubled",
            "Application.Doubled the <r> from 21.",
            "Extract the <v> from the <r: value>."
        )
        #expect(results.allSatisfy { $0.isSuccess })
        #expect(session.getVariable("v") as? Int == 42)
    }

    @Test("The object form works too — no `takes`, arguments via `with`")
    func objectFormIsCallable() async throws {
        let (session, results) = try await defineThenRun(
            """
            (SumTwo: Action) {
                Extract the <a> from the <input: a>.
                Extract the <b> from the <input: b>.
                Compute the <s> from <a> + <b>.
                Return an <OK: status> with { sum: <s> }.
            }
            """,
            named: "SumTwo", activity: "Action",
            "Application.SumTwo the <r> with { a: 3, b: 4 }.",
            "Extract the <s> from the <r: sum>."
        )
        #expect(results.allSatisfy { $0.isSuccess })
        #expect(session.getVariable("s") as? Int == 7)
    }

    @Test("A redefinition is what the next call reaches, not the old body")
    func redefinitionWins() async throws {
        let session = REPLSession(suppressLogPrefix: true)
        _ = try await session.defineFeatureSet(
            name: "D", activity: "Action takes <n>",
            source: """
            (D: Action takes <n>) {
                Extract the <x> from the <input: n>.
                Compute the <o> from <x> * 2.
                Return an <OK: status> with { v: <o> }.
            }
            """
        )
        _ = try await session.executeStatement("Application.D the <r1> from 10.")
        _ = try await session.executeStatement("Extract the <first> from the <r1: v>.")

        _ = try await session.defineFeatureSet(
            name: "D", activity: "Action takes <n>",
            source: """
            (D: Action takes <n>) {
                Extract the <x> from the <input: n>.
                Compute the <o> from <x> * 3.
                Return an <OK: status> with { v: <o> }.
            }
            """
        )
        _ = try await session.executeStatement("Application.D the <r2> from 10.")
        _ = try await session.executeStatement("Extract the <second> from the <r2: v>.")

        #expect(session.getVariable("first") as? Int == 20)
        #expect(session.getVariable("second") as? Int == 30)
    }

    @Test("An action that was never defined is still unknown")
    func undefinedActionStillFails() async throws {
        let (_, results) = try await defineThenRun(
            doubled, named: "Doubled",
            "Application.Tripled the <r> from 21."
        )
        guard case .error(let message) = try #require(results.first) else {
            Issue.record("expected the call to fail, got \(results.first!)")
            return
        }
        #expect(message.contains("Application.Tripled"))
    }

    // MARK: - Definition order

    @Test("Companion sources are offered in definition order, not dictionary order")
    func companionOrderIsStable() async throws {
        let session = REPLSession(suppressLogPrefix: true)
        for name in ["Alpha", "Beta", "Gamma"] {
            _ = try await session.defineFeatureSet(
                name: name, activity: "Action takes <n>",
                source: """
                (\(name): Action takes <n>) {
                    Extract the <x> from the <input: n>.
                    Return an <OK: status> with { v: <x> }.
                }
                """
            )
        }
        let sources = session.companionSources
        #expect(sources.count == 3)
        #expect(sources[0].contains("(Alpha:"))
        #expect(sources[1].contains("(Beta:"))
        #expect(sources[2].contains("(Gamma:"))
    }

    // MARK: - `:invoke`

    @Test("`:invoke` hands an action its JSON object as `input`")
    func invokeBindsInputForActions() async throws {
        let session = REPLSession(suppressLogPrefix: true)
        _ = try await session.defineFeatureSet(
            name: "Doubled", activity: "Action takes <number>", source: doubled
        )
        // An action written for a file reads `input.number`. `:invoke` binds
        // both shapes (GitLab #578), so the Extract resolves here and the
        // ordinary feature set below still sees its keys at top level.
        let result = try await session.invokeFeatureSet(
            named: "Doubled", input: ["number": 21]
        )
        guard case .value(let value) = result else {
            Issue.record("expected a value, got \(result)")
            return
        }
        #expect((value as? Int) == 42)
    }

    @Test("`:invoke` still binds an ordinary feature set's keys directly")
    func invokeBindsKeysForNonActions() async throws {
        // A feature set invoked by hand stands in for whatever would have
        // triggered it, and for anything that is not an action that means
        // the object's fields are the names its statements use. Unchanged.
        let session = REPLSession(suppressLogPrefix: true)
        _ = try await session.defineFeatureSet(
            name: "Calculate Area", activity: "Geometry",
            source: """
            (Calculate Area: Geometry) {
                Compute the <area> from <width> * <height>.
                Return an <OK: status> with <area>.
            }
            """
        )
        let result = try await session.invokeFeatureSet(
            named: "Calculate Area", input: ["width": 3, "height": 4]
        )
        guard case .value(let value) = result else {
            Issue.record("expected a value, got \(result)")
            return
        }
        #expect((value as? Int) == 12)
    }

    @Test("Clearing the session drops the definitions and their order")
    func clearDropsDefinitions() async throws {
        let session = REPLSession(suppressLogPrefix: true)
        _ = try await session.defineFeatureSet(
            name: "Doubled", activity: "Action takes <number>", source: doubled
        )
        #expect(!session.companionSources.isEmpty)

        session.clear()
        #expect(session.companionSources.isEmpty)
    }
}

// MARK: - Piped stdin

/// `StdinScriptRunner`'s own documentation promised that piped source behaves
/// "identical to pasting the same lines into an interactive `aro repl`". It
/// handed the whole source to `executeStatement`, which wraps its input in
/// one feature set — so a definition in piped source was a feature set nested
/// inside another and failed to parse.
@Suite("Piped stdin defines and calls (#576)", .serialized)
struct StdinScriptRunnerActionTests {

    @Test("A definition followed by a call runs")
    func definitionThenCall() async {
        let result = await StdinScriptRunner.run(source: """
        (Tri: Action takes <n>) {
            Extract the <x> from the <input: n>.
            Compute the <o> from <x> * 3.
            Return an <OK: status> with { v: <o> }.
        }
        Application.Tri the <r> from 7.
        Extract the <v> from the <r: v>.
        """)
        guard case .success = result else {
            Issue.record("expected success, got \(result)")
            return
        }
    }

    @Test("The documented one-liner still works")
    func oneLinerStillWorks() async {
        let result = await StdinScriptRunner.run(
            source: #"Log "Hi" to the <console>."#
        )
        guard case .success = result else {
            Issue.record("expected success, got \(result)")
            return
        }
    }

    @Test("Empty and whitespace-only input is empty, not an error")
    func emptyInput() async {
        for source in ["", "   \n\n  "] {
            guard case .empty = await StdinScriptRunner.run(source: source) else {
                Issue.record("expected .empty for \(source.debugDescription)")
                return
            }
        }
    }

    @Test("A comment-only script is not an error")
    func commentOnly() async {
        let result = await StdinScriptRunner.run(source: "(* nothing to do *)\n")
        if case .failure(let message) = result {
            Issue.record("expected no failure, got: \(message)")
        }
    }
}
