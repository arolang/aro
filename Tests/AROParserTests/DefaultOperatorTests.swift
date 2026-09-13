// ============================================================
// DefaultOperatorTests.swift
// ARO Parser — the value-returning `default` operator (GitLab #547)
// ============================================================
//
// ARO-0047 and Book Chapter 23 taught `Create the <port> with
// <params: port> or 8080.` as the way to default a missing parameter.
// `or` is a boolean operator, so that binds `true`, never 8080 — the
// documentation promised something no program could get.
//
// `default` is the spelling that can be true. It reuses the word the
// query grammar already uses for a fallback (ARO-0018), leaves `or`
// strictly boolean, and — being value-returning — needs its own rung in
// the precedence table: tighter than a comparison, looser than
// arithmetic, so `<a> default 3 > 2` compares the defaulted value and
// `<a> default 1 + 2` defaults to three.

import Testing
@testable import AROParser

@Suite("The `default` operator (#547)")
struct DefaultOperatorTests {

    // MARK: - Shape

    @Test("`<params: count> default 3` is one binary expression")
    func parsesAsBinaryExpression() throws {
        let source = "(Test: Demo) { Create the <count> with <params: count> default 3. }"
        let program = try Parser.parse(source)
        let statement = try #require(program.featureSets[0].statements[0] as? AROStatement)

        let binary = try #require(statement.expression as? BinaryExpression)
        #expect(binary.op == .defaulting)

        let left = try #require(binary.left as? VariableRefExpression)
        #expect(left.noun.base == "params")
        #expect(left.noun.specifiers == ["count"])

        let right = try #require(binary.right as? LiteralExpression)
        #expect(right.value == .integer(3))

        // The statement-level ARO-0018 modifier must NOT have claimed it:
        // that is what bound the whole record and dropped the fallback.
        #expect(statement.queryModifiers.defaultValue == nil)
    }

    @Test("`default` is not a reserved word — a variable may still be called that")
    func defaultRemainsAName() throws {
        let source = "(Test: Demo) { Create the <default> with 3. }"
        let program = try Parser.parse(source)
        let statement = try #require(program.featureSets[0].statements[0] as? AROStatement)
        #expect(statement.result.base == "default")
    }

    // MARK: - Precedence

    @Test("Binds tighter than comparison: `<a> default 3 > 2` compares the default")
    func bindsTighterThanComparison() throws {
        let source = "(Test: Demo) { Create the <ok> with <s: n> default 3 > 2. }"
        let program = try Parser.parse(source)
        let statement = try #require(program.featureSets[0].statements[0] as? AROStatement)

        let comparison = try #require(statement.expression as? BinaryExpression)
        #expect(comparison.op == .greaterThan)

        let defaulted = try #require(comparison.left as? BinaryExpression)
        #expect(defaulted.op == .defaulting)
    }

    @Test("Binds tighter than `and`: `<x> default 1 and <y>`")
    func bindsTighterThanAnd() throws {
        let source = "(Test: Demo) { Create the <ok> with <x: n> default 1 and <y>. }"
        let program = try Parser.parse(source)
        let statement = try #require(program.featureSets[0].statements[0] as? AROStatement)

        let conjunction = try #require(statement.expression as? BinaryExpression)
        #expect(conjunction.op == .and)

        let defaulted = try #require(conjunction.left as? BinaryExpression)
        #expect(defaulted.op == .defaulting)
    }

    @Test("Binds looser than arithmetic: `<a> default 1 + 2` defaults to three")
    func bindsLooserThanArithmetic() throws {
        let source = "(Test: Demo) { Create the <n> with <s: n> default 1 + 2. }"
        let program = try Parser.parse(source)
        let statement = try #require(program.featureSets[0].statements[0] as? AROStatement)

        let defaulted = try #require(statement.expression as? BinaryExpression)
        #expect(defaulted.op == .defaulting)

        let sum = try #require(defaulted.right as? BinaryExpression)
        #expect(sum.op == .add)
    }

    @Test("Chains left-associatively: `<a> default <b> default 42`")
    func chainsLeftAssociatively() throws {
        let source = "(Test: Demo) { Create the <n> with <s: a> default <s: b> default 42. }"
        let program = try Parser.parse(source)
        let statement = try #require(program.featureSets[0].statements[0] as? AROStatement)

        let outer = try #require(statement.expression as? BinaryExpression)
        #expect(outer.op == .defaulting)
        let inner = try #require(outer.left as? BinaryExpression)
        #expect(inner.op == .defaulting)
        let fallback = try #require(outer.right as? LiteralExpression)
        #expect(fallback.value == .integer(42))
    }

    // MARK: - The query modifier keeps its meaning (ARO-0018)

    @Test("`where … default …` is still the query's fallback, not the operator")
    func whereClauseDefaultStaysAModifier() throws {
        let source = """
        (Test: Demo) { Extract the <who> from the <user-repository> where <id> is 99 default "nobody". }
        """
        let program = try Parser.parse(source)
        let statement = try #require(program.featureSets[0].statements[0] as? AROStatement)

        #expect(statement.queryModifiers.whereCondition != nil)
        #expect(statement.queryModifiers.defaultValue != nil)
    }

    @Test("A framework address keeps its object reading: `<file: …> default …`")
    func systemObjectStaysAnObject() throws {
        // `<file: "notes.md">` is an address an action resolves, not a value an
        // expression can read. Routed through the expression grammar it would
        // find no variable named `file` and hand back the default every time.
        let source = """
        (Test: Demo) { Read the <content> from the <file: "notes.md"> default "missing". }
        """
        let program = try Parser.parse(source)
        let statement = try #require(program.featureSets[0].statements[0] as? AROStatement)

        #expect(statement.object.noun.base == "file")
        #expect(statement.queryModifiers.defaultValue != nil)
    }

    @Test("`<parameter: port> default 8080` is an expression — both evaluators read it")
    func parameterIsReadableInAnExpression() throws {
        let source = "(Test: Demo) { Create the <port> with <parameter: port> default 8080. }"
        let program = try Parser.parse(source)
        let statement = try #require(program.featureSets[0].statements[0] as? AROStatement)

        let binary = try #require(statement.expression as? BinaryExpression)
        #expect(binary.op == .defaulting)
        let left = try #require(binary.left as? VariableRefExpression)
        #expect(left.noun.base == "parameter")
    }

    @Test("A repository fallback without a where-clause is still a modifier")
    func objectDefaultStaysAModifier() throws {
        let source = """
        (Test: Demo) { Extract the <who> from the <user-repository> default "nobody". }
        """
        let program = try Parser.parse(source)
        let statement = try #require(program.featureSets[0].statements[0] as? AROStatement)
        #expect(statement.queryModifiers.defaultValue != nil)
    }
}
