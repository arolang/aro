// ============================================================
// MapFieldProjectionTests.swift
// AROParser — `Map … with <field>` (GitLab #465)
// ============================================================
//
// ARO-0019 §2.1 writes field projection as
// `Map the <names> from the <active-users> with name.`, and
// ARO-0051 and ARO-0086 use the same shape. None of it parsed: a
// bare identifier is not an expression start, so the with-clause
// was skipped and the statement died on "Expected '.', but got
// identifier(name)".
//
// It desugars into the specifier form that already worked, so the
// two spellings cannot drift apart — a test below asserts they
// produce the same AST.

import Testing
@testable import AROParser

@Suite("Map field projection (#465)")
struct MapFieldProjectionTests {

    private func mapStatement(_ line: String) throws -> AROStatement {
        let program = try Parser.parse("""
        (Project: Test Activity) {
            \(line)
        }
        """)
        return try #require(program.featureSets[0].statements[0] as? AROStatement)
    }

    @Test("The spec's own example parses")
    func specExampleParses() throws {
        // Verbatim from ARO-0019 §2.1.
        let program = try Parser.parse("""
        (Process Users: List Example) {
            Retrieve the <users> from the <user-repository>.
            Filter the <active-users> from the <users> where status = "active".
            Map the <names> from the <active-users> with name.
            Return an <OK: status> with <names>.
        }
        """)
        #expect(program.featureSets[0].statements.count == 4)
    }

    @Test("The field lands in the result specifier")
    func fieldBecomesSpecifier() throws {
        let statement = try mapStatement(
            "Map the <names> from the <users> with name.")
        #expect(statement.result.base == "names")
        #expect(statement.result.specifiers.contains("name"))
    }

    @Test("Both spellings produce the same projection")
    func spellingsAgree() throws {
        // The desugaring's whole point: one implementation, so the
        // documented spelling and the specifier spelling cannot
        // answer differently.
        let withClause = try mapStatement(
            "Map the <names> from the <users> with name.")
        let specifier = try mapStatement(
            "Map the <names: name> from the <users>.")
        #expect(withClause.result.base == specifier.result.base)
        #expect(withClause.result.specifiers == specifier.result.specifiers)
        #expect(withClause.object.noun.base == specifier.object.noun.base)
    }

    // MARK: - Regression surface

    @Test("A with-clause carrying a real expression is untouched")
    func expressionWithClauseUnaffected() throws {
        // `with { … }` and `with <var>` are values, not field names,
        // and every other verb depends on that reading.
        let statement = try mapStatement(
            "Map the <rows> from the <users> with <config>.")
        #expect(!statement.result.specifiers.contains("config"))
    }

    @Test("Other verbs keep their with-clause meaning", arguments: [
        "Create the <u> with { name: \"a\" }.",
        "Emit a <Thing: event> with <payload>.",
        "Compute the <o: replace> from <t> with { find: \"-\", replace: \"_\" }.",
    ])
    func otherVerbsUnaffected(line: String) throws {
        let statement = try mapStatement(line)
        #expect(statement.action.verb.isEmpty == false)
    }

    @Test("The desugaring is scoped to Map")
    func scopedToMap() throws {
        // Everywhere else a bare identifier after `with` stays the
        // parse error it has always been, rather than silently
        // becoming a result specifier. The parser records it as an
        // ErrorStatement instead of throwing, so that is what to
        // assert.
        let program = try Parser.parse("""
        (Project: Test Activity) {
            Filter the <y> from the <x> with name.
        }
        """)
        let first = program.featureSets[0].statements[0]
        #expect(first is ErrorStatement)
        #expect(!(first is AROStatement))
    }

    @Test("Map without any with-clause is unchanged")
    func plainMapUnaffected() throws {
        let statement = try mapStatement("Map the <rows> from the <users>.")
        #expect(statement.result.specifiers.isEmpty)
    }
}
