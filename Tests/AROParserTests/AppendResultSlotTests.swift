// ============================================================
// AppendResultSlotTests.swift
// ARO Parser Tests - Append's documented form (GitLab #580)
// ============================================================
//
// `AppendAction`'s own docstring gives this as the primary form:
//
//     Append the <log-line> to the <file: "./logs/app.log">.
//
// and the implementation reads the content from the result slot:
//
//     } else if let value: String = context.resolve(result.base) {
//         content = value
//
// But the analyzer treated the slot as a *binding*, so the variable holding
// the content was being rebound and the immutability check rejected the
// statement before the action could run. The hint was not actionable either:
// `<log-line-updated>` is unbound, so following it appends the empty string.
//
// `store`, `write`, `emit`, `save`, `persist` and `send` already had the rule
// that their result slot is content to read; `append` was missing from it.

import Testing
@testable import AROParser

@Suite("Append's result slot is content (GitLab #580)")
struct AppendResultSlotTests {

    private func errors(_ source: String) -> [Diagnostic] {
        Compiler().compile(source).diagnostics.filter { $0.severity == .error }
    }

    // MARK: - The documented form

    @Test("The documented form compiles")
    func documentedFormCompiles() {
        #expect(errors("""
        (Application-Start: Append Demo) {
            Create the <line-one> with "first".
            Append the <line-one> to the <file: "./out.log">.
            Return an <OK: status> for the <a>.
        }
        """).isEmpty)
    }

    @Test("Appending twice from two bound names is fine")
    func twoAppends() {
        // Neither statement binds, so neither can collide.
        #expect(errors("""
        (Application-Start: Append Demo) {
            Create the <line-one> with "first".
            Create the <line-two> with "second".
            Append the <line-one> to the <file: "./out.log">.
            Append the <line-two> to the <file: "./out.log">.
            Return an <OK: status> for the <a>.
        }
        """).isEmpty)
    }

    @Test("Appending the same name twice is fine — it is a read, not a rebind")
    func sameNameTwice() {
        #expect(errors("""
        (Application-Start: Append Demo) {
            Create the <line> with "x".
            Append the <line> to the <file: "./a.log">.
            Append the <line> to the <file: "./b.log">.
            Return an <OK: status> for the <a>.
        }
        """).isEmpty)
    }

    // MARK: - The `with` form still binds

    @Test("The `with` form still binds its result")
    func withFormStillBinds() {
        // Content comes from the literal there, exactly as `AppendAction`
        // prefers `_literal_` over the result slot, so the slot is an output
        // and binds an `AppendResult`. Reading it afterwards must be valid.
        #expect(errors("""
        (Application-Start: Append Demo) {
            Append the <entry> to the <file: "./out.log"> with "third".
            Log <entry> to the <console>.
            Return an <OK: status> for the <a>.
        }
        """).isEmpty)
    }

    @Test("The `with` form still refuses to rebind an existing name")
    func withFormStillChecksImmutability() {
        // It binds, so the immutability rule still applies to it.
        let diagnostics = errors("""
        (Application-Start: Append Demo) {
            Create the <entry> with "x".
            Append the <entry> to the <file: "./out.log"> with "third".
            Return an <OK: status> for the <a>.
        }
        """)
        #expect(diagnostics.contains { $0.message.contains("Cannot rebind") }, "\(diagnostics)")
    }

    // MARK: - The sibling verbs keep their behaviour

    @Test("append joins the verbs that already read their result slot")
    func appendJoinsTheSet() {
        for verb in ["store", "write", "emit", "save", "persist", "send", "append"] {
            #expect(DataFlowAnalyzer.resultIsContentVerbs.contains(verb), "\(verb) missing")
        }
    }

    @Test("Write from a bound name still compiles, as it always did")
    func writeStillCompiles() {
        #expect(errors("""
        (Application-Start: Write Demo) {
            Create the <body> with "x".
            Write the <body> to the <file: "./out.txt">.
            Return an <OK: status> for the <w>.
        }
        """).isEmpty)
    }

    // MARK: - An unbound result slot is still a definition

    @Test("Appending an unbound name still binds it, so it is not an unknown read")
    func unboundResultStillBinds() {
        // Nothing is defined, so there is nothing to read — the slot is an
        // output and must not be reported as an external dependency.
        let diagnostics = Compiler().compile("""
        (Application-Start: Append Demo) {
            Append the <fresh> to the <file: "./out.log">.
            Return an <OK: status> for the <a>.
        }
        """).diagnostics
        #expect(!diagnostics.contains { $0.message.contains("not published") }, "\(diagnostics)")
    }
}
