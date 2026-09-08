// ============================================================
// StoreInlinePayloadTests.swift
// AROParser — `Store … into <repo> with { … }` at check time (GitLab #515)
// ============================================================
//
// The parser always produced the `with` expression for this statement;
// what was missing was any notion that the payload *is* the value, and
// that the result slot therefore binds the stored record. Without that,
// `aro check` reported the record as an unresolved external dependency,
// and the conflict between a payload and an already-bound name was only
// discoverable by running the program.

import Testing
@testable import AROParser

@Suite("Store with an inline payload (#515)")
struct StoreInlinePayloadTests {

    private func diagnostics(_ source: String) -> [Diagnostic] {
        Compiler.compile(source).diagnostics
    }

    private func errors(_ source: String) -> [String] {
        diagnostics(source).filter { $0.severity == .error }.map(\.message)
    }

    private func warnings(_ source: String) -> [String] {
        diagnostics(source).filter { $0.severity == .warning }.map(\.message)
    }

    // MARK: - Parse shape

    @Test("The payload parses into the statement's with clause")
    func payloadReachesWithClause() throws {
        let result = Compiler.compile("""
        (Application-Start: T) {
            Store the <ticket> into the <ticket-repository> with { id: 1, state: "new" }.
            Return an <OK: status> for the <t>.
        }
        """)

        let featureSet = try #require(result.program.featureSets.first)
        let statement = try #require(featureSet.statements.first as? AROStatement)

        #expect(statement.action.verb.lowercased() == "store")
        #expect(statement.result.base == "ticket")
        #expect(statement.object.noun.base == "ticket-repository")
        #expect(statement.object.preposition == .into)

        // The clause the runtime reads as `_with_`.
        let withClause = try #require(statement.rangeModifiers.withClause)
        #expect(withClause is MapLiteralExpression)
    }

    // MARK: - The record is a defined symbol

    /// Names the analyzer considers defined inside the (single) feature set.
    private func definedSymbols(_ source: String) -> Set<String> {
        let analyzed = Compiler.compile(source).analyzedProgram
        guard let featureSet = analyzed.featureSets.first else { return [] }
        return Set(featureSet.symbolTable.allSymbols.keys)
    }

    @Test("The record the payload stores is defined, not an external dependency")
    func resultIsDefined() {
        let source = """
        (Application-Start: T) {
            Store the <ticket> into the <ticket-repository> with { id: 1, state: "new" }.
            Log <ticket> to the <console>.
            Return an <OK: status> for the <t>.
        }
        """
        #expect(errors(source).isEmpty)
        #expect(definedSymbols(source).contains("ticket"))

        let analyzed = Compiler.compile(source).analyzedProgram
        #expect(analyzed.featureSets.first?.dependencies.contains("ticket") != true)
    }

    @Test("The bare form still defines nothing — it stores a value, it makes none")
    func bareFormDefinesNothing() {
        // `Store the <ghost> into the <g-repository>.` reads <ghost>; it is not
        // a binding site, and this pins that #515 did not quietly turn every
        // Store into one.
        let source = """
        (Application-Start: T) {
            Store the <ghost> into the <g-repository>.
            Return an <OK: status> for the <t>.
        }
        """
        #expect(errors(source).isEmpty)
        #expect(!definedSymbols(source).contains("ghost"))
    }

    @Test("`to` spells the same statement")
    func toPrepositionAlsoBinds() {
        let source = """
        (Application-Start: T) {
            Store the <ticket> to the <ticket-repository> with { id: 1 }.
            Return an <OK: status> for the <t>.
        }
        """
        #expect(errors(source).isEmpty)
        #expect(definedSymbols(source).contains("ticket"))
    }

    // MARK: - Conflicts

    @Test("A payload for a name that is already bound is a check-time error")
    func payloadOnBoundNameIsAnError() {
        let messages = errors("""
        (Application-Start: T) {
            Create the <ticket> with { id: 9 }.
            Store the <ticket> into the <ticket-repository> with { id: 1 }.
            Return an <OK: status> for the <t>.
        }
        """)

        #expect(messages.contains { $0.contains("Cannot rebind variable 'ticket'") })
    }

    @Test("The immutable spelling with no payload is unaffected")
    func specifierFormStillChecks() {
        let source = """
        (Application-Start: T) {
            Create the <user> with { id: 1 }.
            Store the <stored: user> into the <user-repository>.
            Return an <OK: status> for the <t>.
        }
        """
        #expect(errors(source).isEmpty)
    }
}
