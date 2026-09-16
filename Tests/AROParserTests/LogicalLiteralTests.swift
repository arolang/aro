// ============================================================
// LogicalLiteralTests.swift
// AROParser — `or`/`and` over a non-boolean literal (GitLab #575)
// ============================================================
//
// `Create the <port> with <params: port> or 8080.` is the fallback
// shape people reach for, and several editions of the docs taught it.
// `or` is boolean, so it binds `true` — for a parameter that *was*
// passed as much as one that wasn't. `aro check` passed it and the
// program exited `[OK]`, so the wrong value only surfaced wherever it
// was finally used.
//
// A non-boolean literal under `and`/`or` has a truthiness fixed at
// parse time, so it can only pin the result or contribute nothing.
// Either way it is dead weight, which is what makes it an error.

import Testing
@testable import AROParser

@Suite("Logical operators over non-boolean literals (#575)")
struct LogicalLiteralTests {

    private func diagnose(_ statement: String) -> [Diagnostic] {
        Compiler.compile("""
        (Application-Start: T) {
            Extract the <params> from the <parameter>.
            \(statement)
            Log "x" to the <console>.
            Return an <OK: status> for the <t>.
        }
        """).diagnostics
    }

    private func errors(_ statement: String) -> [Diagnostic] {
        diagnose(statement).filter { $0.severity == .error }
    }

    // MARK: - The shape the issue reported

    @Test("`or 8080` is rejected and names `default`")
    func orIntegerLiteral() throws {
        let found = errors("Create the <port> with <params: port> or 8080.")
        let first = try #require(found.first)
        #expect(found.count == 1)
        #expect(first.message.contains("`or` is a boolean operator"))
        #expect(first.message.contains("constantly true"))
        #expect(first.hints.contains { $0.contains("<params: port> default 8080") })
    }

    @Test("`or \"0.0.0.0\"` — a string fallback is rejected the same way")
    func orStringLiteral() throws {
        let found = errors(#"Create the <host> with <params: host> or "0.0.0.0"."#)
        let first = try #require(found.first)
        #expect(first.message.contains("constantly true"))
        #expect(first.hints.contains { $0.contains(#"default "0.0.0.0""#) })
    }

    // MARK: - A falsy literal pins nothing, so it is named differently

    @Test("`or \"\"` is redundant rather than constant, and says so")
    func orFalsyLiteral() throws {
        let found = errors(#"Create the <prefix> with <params: prefix> or ""."#)
        let first = try #require(found.first)
        #expect(first.message.contains("does nothing"))
        #expect(first.message.contains("<params: prefix>"))
        // Still the mistaken-default shape, so still worth naming `default`.
        #expect(first.hints.contains { $0.contains("default") })
    }

    @Test("`and 0` makes the expression constantly false")
    func andFalsyLiteral() throws {
        let found = errors("Create the <mask> with <params: mask> and 0.")
        let first = try #require(found.first)
        #expect(first.message.contains("`and` is a boolean operator"))
        #expect(first.message.contains("constantly false"))
        // `default` is an `or`-shaped misreading; `and` gets no such hint.
        #expect(!first.hints.contains { $0.contains("use `default`") })
    }

    @Test("`and 1` is redundant")
    func andTruthyLiteral() throws {
        let found = errors("Create the <mask> with <params: mask> and 1.")
        #expect(found.first?.message.contains("does nothing") == true)
    }

    // MARK: - What must stay legal

    @Test("`default` — the operator that actually does this — is clean")
    func defaultOperatorIsClean() {
        #expect(errors("Create the <port> with <params: port> default 8080.").isEmpty)
    }

    @Test("Boolean logic over variables is untouched")
    func booleanVariablesClean() {
        #expect(errors("Create the <r> with <params: a> or <params: b>.").isEmpty)
        #expect(errors("Create the <r> with <params: a> and <params: b>.").isEmpty)
    }

    @Test("Boolean literals are left alone — redundant, but not a mistaken default")
    func booleanLiteralsClean() {
        #expect(errors("Create the <r> with <params: a> or true.").isEmpty)
        #expect(errors("Create the <r> with <params: a> and false.").isEmpty)
    }

    // A bare `<x> > 10` does not parse in a value position at all, so these
    // use the parenthesised form the parser does accept.
    @Test("A comparison against a literal is not a logical operand")
    func comparisonsClean() {
        #expect(errors("Create the <big> with (<params: n> > 10).").isEmpty)
        #expect(errors(#"Create the <named> with (<params: n> == "x")."#).isEmpty)
    }

    @Test("Comparisons combined with `or` stay legal — the operands are booleans")
    func combinedComparisonsClean() {
        #expect(errors("Create the <r> with ((<params: n> > 10) or (<params: m> < 2)).").isEmpty)
    }

    // MARK: - Reach

    @Test("A guard condition is checked too")
    func guardConditionChecked() {
        let found = errors("Log \"hi\" to the <console> when <params: v> or 1.")
        #expect(found.count == 1)
    }

    @Test("A nested logical node is found, not just the outermost")
    func nestedChecked() throws {
        let found = errors("Create the <r> with <params: a> and (<params: b> or 5).")
        let first = try #require(found.first)
        #expect(first.message.contains("constantly true"))
    }

    @Test("A literal behind parentheses is the same mistake")
    func parenthesisedLiteral() throws {
        let found = errors("Create the <port> with <params: port> or (8080).")
        let first = try #require(found.first)
        #expect(first.message.contains("constantly true"))
    }
}
