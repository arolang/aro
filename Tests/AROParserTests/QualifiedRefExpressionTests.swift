// ============================================================
// QualifiedRefExpressionTests.swift
// ARO Parser — qualified refs as expression operands (GitLab #496)
// ============================================================
//
// `Compute the <line-total> from <item: qty> * <item: price>.` used to
// die with "Expected '.', but got *": the object-position dispatch saw
// `<identifier: ...>` and committed to the system-object interpretation
// before looking at what followed the reference. The expression grammar
// itself has parsed qualified nouns all along (string interpolation
// relies on it), so the fix is routing: a qualified ref followed by a
// binary operator is an expression operand.

import Testing
@testable import AROParser

@Suite("Qualified refs in expressions (#496)")
struct QualifiedRefExpressionTests {

    // MARK: - The repro from the issue

    @Test("Qualified refs multiply: <item: qty> * <item: price>")
    func qualifiedTimesQualified() throws {
        let source = """
        (Test: Demo) { Compute the <line-total> from <item: qty> * <item: price>. }
        """
        let program = try Parser.parse(source)
        let statement = program.featureSets[0].statements[0] as! AROStatement

        let binary = try #require(statement.expression as? BinaryExpression)
        #expect(binary.op == .multiply)

        let left = try #require(binary.left as? VariableRefExpression)
        #expect(left.noun.base == "item")
        #expect(left.noun.specifiers == ["qty"])

        let right = try #require(binary.right as? VariableRefExpression)
        #expect(right.noun.base == "item")
        #expect(right.noun.specifiers == ["price"])
    }

    @Test("Qualified ref with a literal operand: <item: qty> * 2")
    func qualifiedTimesLiteral() throws {
        let source = "(Test: Demo) { Compute the <doubled> from <item: qty> * 2. }"
        let program = try Parser.parse(source)
        let statement = program.featureSets[0].statements[0] as! AROStatement

        let binary = try #require(statement.expression as? BinaryExpression)
        #expect(binary.op == .multiply)
        let left = try #require(binary.left as? VariableRefExpression)
        #expect(left.noun.specifiers == ["qty"])
    }

    @Test("Qualified ref mixed with a bare ref: <item: price> - <discount>")
    func qualifiedMinusBare() throws {
        let source = "(Test: Demo) { Compute the <net> from <item: price> - <discount>. }"
        let program = try Parser.parse(source)
        let statement = program.featureSets[0].statements[0] as! AROStatement

        let binary = try #require(statement.expression as? BinaryExpression)
        #expect(binary.op == .subtract)
        let right = try #require(binary.right as? VariableRefExpression)
        #expect(right.noun.base == "discount")
        #expect(right.noun.specifiers.isEmpty)
    }

    @Test("Precedence holds across qualified refs")
    func precedence() throws {
        let source = """
        (Test: Demo) { Compute the <total> from <item: base> + <item: qty> * <item: price>. }
        """
        let program = try Parser.parse(source)
        let statement = program.featureSets[0].statements[0] as! AROStatement

        // + at the root, * bound tighter on the right.
        let add = try #require(statement.expression as? BinaryExpression)
        #expect(add.op == .add)
        let mul = try #require(add.right as? BinaryExpression)
        #expect(mul.op == .multiply)
    }

    @Test("Multi-segment property path as operand: <order: customer.tier>")
    func propertyPathOperand() throws {
        let source = """
        (Test: Demo) { Compute the <label> from <order: customer.tier> ++ "!". }
        """
        let program = try Parser.parse(source)
        let statement = program.featureSets[0].statements[0] as! AROStatement

        let binary = try #require(statement.expression as? BinaryExpression)
        #expect(binary.op == .concat)
        let left = try #require(binary.left as? VariableRefExpression)
        #expect(left.noun.base == "order")
        #expect(left.noun.specifiers == ["customer", "tier"])
    }

    @Test("Comparison operators route to the expression too")
    func comparisonOperand() throws {
        let source = "(Test: Demo) { Compute the <cheap> from <item: price> <= 100. }"
        let program = try Parser.parse(source)
        let statement = program.featureSets[0].statements[0] as! AROStatement

        let binary = try #require(statement.expression as? BinaryExpression)
        #expect(binary.op == .lessEqual)
    }

    @Test("when guard accepts a qualified ref")
    func whenGuardQualifiedRef() throws {
        let source = """
        (Test: Demo) { Return an <OK: status> for the <check> when <record: active>. }
        """
        let program = try Parser.parse(source)
        let statement = program.featureSets[0].statements[0] as! AROStatement

        let condition = try #require(statement.whenCondition as? VariableRefExpression)
        #expect(condition.noun.base == "record")
        #expect(condition.noun.specifiers == ["active"])
    }

    // MARK: - System-object interpretation must survive

    @Test("Bare qualified object noun still parses as object")
    func systemObjectUnchanged() throws {
        let source = "(Test: Demo) { Extract the <data> from <request: body>. }"
        let program = try Parser.parse(source)
        let statement = program.featureSets[0].statements[0] as! AROStatement

        #expect(statement.expression == nil)
        #expect(statement.object.noun.base == "request")
        #expect(statement.object.noun.specifiers == ["body"])
    }

    @Test("Qualified object with a trailing with-clause stays an object")
    func objectWithClauseUnchanged() throws {
        // Note: a simple (non-hyphenated) base — the system-object lookahead
        // only ever fired for `< identifier :`, so hyphenated bases like
        // `<user-repository: users>` took the expression path before this
        // change too (pre-existing, unchanged here).
        let source = """
        (Test: Demo) { Retrieve the <user> from <sessions: users> with <id>. }
        """
        let program = try Parser.parse(source)
        let statement = program.featureSets[0].statements[0] as! AROStatement

        // The `with <id>` clause surfaces as the statement expression;
        // what matters is that the object stayed a noun.
        #expect(statement.object.noun.base == "sessions")
        #expect(statement.object.noun.specifiers == ["users"])
    }

    @Test("Literal qualifier object stays an object: <file: \"path\">")
    func literalQualifierObjectUnchanged() throws {
        let source = "(Test: Demo) { Write the <report> to <file: \"out.txt\">. }"
        let program = try Parser.parse(source)
        let statement = program.featureSets[0].statements[0] as! AROStatement

        #expect(statement.object.noun.base == "file")
        #expect(statement.object.noun.specifiers == ["out.txt"])
    }

    @Test("Generic annotation in the qualifier does not confuse the scan")
    func genericAnnotationStillObject() throws {
        // The scan tracks angle depth, so List<User>'s brackets must not
        // make it think the reference closed early.
        let source = "(Test: Demo) { Extract the <users> from <response: List<User>>. }"
        let program = try Parser.parse(source)
        let statement = program.featureSets[0].statements[0] as! AROStatement

        #expect(statement.expression == nil)
        #expect(statement.object.noun.base == "response")
    }
}
