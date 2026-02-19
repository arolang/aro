// ============================================================
// ExpressionTests.swift
// ARO Parser - Expression Parsing Tests (ARO-0002)
// ============================================================

import Testing
@testable import AROParser

// MARK: - Expression AST Tests

@Suite("Expression AST Tests")
struct ExpressionASTTests {

    @Test("LiteralExpression creation")
    func testLiteralExpressionCreation() {
        let span = SourceSpan.unknown
        let expr = LiteralExpression(value: .integer(42), span: span)
        #expect(expr.value == .integer(42))
    }

    @Test("ArrayLiteralExpression creation")
    func testArrayLiteralCreation() {
        let span = SourceSpan.unknown
        let elements: [any Expression] = [
            LiteralExpression(value: .integer(1), span: span),
            LiteralExpression(value: .integer(2), span: span)
        ]
        let expr = ArrayLiteralExpression(elements: elements, span: span)
        #expect(expr.elements.count == 2)
    }

    @Test("MapLiteralExpression creation")
    func testMapLiteralCreation() {
        let span = SourceSpan.unknown
        let entries = [
            MapEntry(key: "name", value: LiteralExpression(value: .string("test"), span: span), span: span)
        ]
        let expr = MapLiteralExpression(entries: entries, span: span)
        #expect(expr.entries.count == 1)
        #expect(expr.entries[0].key == "name")
    }

    @Test("BinaryExpression creation")
    func testBinaryExpressionCreation() {
        let span = SourceSpan.unknown
        let left = LiteralExpression(value: .integer(1), span: span)
        let right = LiteralExpression(value: .integer(2), span: span)
        let expr = BinaryExpression(left: left, op: .add, right: right, span: span)
        #expect(expr.op == .add)
    }

    @Test("UnaryExpression creation")
    func testUnaryExpressionCreation() {
        let span = SourceSpan.unknown
        let operand = LiteralExpression(value: .integer(42), span: span)
        let expr = UnaryExpression(op: .negate, operand: operand, span: span)
        #expect(expr.op == .negate)
    }

    @Test("BinaryOperator has all expected cases")
    func testBinaryOperatorCases() {
        // Arithmetic
        #expect(BinaryOperator.add.rawValue == "+")
        #expect(BinaryOperator.subtract.rawValue == "-")
        #expect(BinaryOperator.multiply.rawValue == "*")
        #expect(BinaryOperator.divide.rawValue == "/")
        #expect(BinaryOperator.modulo.rawValue == "%")
        #expect(BinaryOperator.concat.rawValue == "++")

        // Comparison
        #expect(BinaryOperator.equal.rawValue == "==")
        #expect(BinaryOperator.notEqual.rawValue == "!=")
        #expect(BinaryOperator.lessThan.rawValue == "<")
        #expect(BinaryOperator.greaterThan.rawValue == ">")
        #expect(BinaryOperator.lessEqual.rawValue == "<=")
        #expect(BinaryOperator.greaterEqual.rawValue == ">=")

        // Logical
        #expect(BinaryOperator.and.rawValue == "and")
        #expect(BinaryOperator.or.rawValue == "or")

        // Collection
        #expect(BinaryOperator.contains.rawValue == "contains")
        #expect(BinaryOperator.matches.rawValue == "matches")
    }

    @Test("UnaryOperator has all expected cases")
    func testUnaryOperatorCases() {
        #expect(UnaryOperator.negate.rawValue == "-")
        #expect(UnaryOperator.not.rawValue == "not")
    }
}

// MARK: - Expression Parser Tests

@Suite("Expression Parser Tests")
struct ExpressionParserTests {

    @Test("Parses integer literal expression")
    func testIntegerLiteral() throws {
        let source = "(Test: Demo) { Set the <x> to 42. }"
        let program = try Parser.parse(source)

        let featureSet = program.featureSets[0]
        let statement = featureSet.statements[0] as! AROStatement

        #expect(statement.expression != nil)
        if let literal = statement.expression as? LiteralExpression {
            #expect(literal.value == .integer(42))
        } else {
            Issue.record("Expected LiteralExpression")
        }
    }

    @Test("Parses float literal expression")
    func testFloatLiteral() throws {
        let source = "(Test: Demo) { Set the <pi> to 3.14. }"
        let program = try Parser.parse(source)

        let statement = program.featureSets[0].statements[0] as! AROStatement
        if let literal = statement.expression as? LiteralExpression {
            #expect(literal.value == .float(3.14))
        } else {
            Issue.record("Expected LiteralExpression")
        }
    }

    @Test("Parses string literal expression")
    func testStringLiteral() throws {
        let source = "(Test: Demo) { Set the <msg> to \"hello\". }"
        let program = try Parser.parse(source)

        let statement = program.featureSets[0].statements[0] as! AROStatement
        if let literal = statement.expression as? LiteralExpression {
            #expect(literal.value == .string("hello"))
        } else {
            Issue.record("Expected LiteralExpression")
        }
    }

    @Test("Parses boolean literal expressions")
    func testBooleanLiterals() throws {
        let source = "(Test: Demo) { Set the <flag> to true. }"
        let program = try Parser.parse(source)

        let statement = program.featureSets[0].statements[0] as! AROStatement
        if let literal = statement.expression as? LiteralExpression {
            #expect(literal.value == .boolean(true))
        } else {
            Issue.record("Expected LiteralExpression")
        }
    }

    @Test("Parses variable reference expression")
    func testVariableReference() throws {
        let source = "(Test: Demo) { Set the <y> to <x>. }"
        let program = try Parser.parse(source)

        let statement = program.featureSets[0].statements[0] as! AROStatement
        if let varRef = statement.expression as? VariableRefExpression {
            #expect(varRef.noun.base == "x")
        } else {
            Issue.record("Expected VariableRefExpression")
        }
    }

    @Test("Parses addition expression")
    func testAdditionExpression() throws {
        let source = "(Test: Demo) { Compute the <sum> from 1 + 2. }"
        let program = try Parser.parse(source)

        let statement = program.featureSets[0].statements[0] as! AROStatement
        if let binary = statement.expression as? BinaryExpression {
            #expect(binary.op == .add)
        } else {
            Issue.record("Expected BinaryExpression")
        }
    }

    @Test("Parses multiplication expression")
    func testMultiplicationExpression() throws {
        let source = "(Test: Demo) { Compute the <product> from 3 * 4. }"
        let program = try Parser.parse(source)

        let statement = program.featureSets[0].statements[0] as! AROStatement
        if let binary = statement.expression as? BinaryExpression {
            #expect(binary.op == .multiply)
        } else {
            Issue.record("Expected BinaryExpression")
        }
    }

    @Test("Parses string concatenation expression")
    func testConcatExpression() throws {
        let source = "(Test: Demo) { Compute the <full> from \"a\" ++ \"b\". }"
        let program = try Parser.parse(source)

        let statement = program.featureSets[0].statements[0] as! AROStatement
        if let binary = statement.expression as? BinaryExpression {
            #expect(binary.op == .concat)
        } else {
            Issue.record("Expected BinaryExpression")
        }
    }

    @Test("Parses comparison expressions")
    func testComparisonExpressions() throws {
        // Use == instead of > to avoid angle bracket ambiguity
        let source = "(Test: Demo) { Validate the <result> for <x> == 10. }"
        let program = try Parser.parse(source)

        let statement = program.featureSets[0].statements[0] as! AROStatement
        if let binary = statement.expression as? BinaryExpression {
            #expect(binary.op == .equal)
        } else {
            Issue.record("Expected BinaryExpression")
        }
    }

    @Test("Parses greater than with numbers")
    func testGreaterThan() throws {
        // Use numeric comparison to avoid angle bracket issues
        let source = "(Test: Demo) { Validate the <result> for 15 > 10. }"
        let program = try Parser.parse(source)

        let statement = program.featureSets[0].statements[0] as! AROStatement
        if let binary = statement.expression as? BinaryExpression {
            #expect(binary.op == .greaterThan)
        } else {
            Issue.record("Expected BinaryExpression")
        }
    }

    @Test("Parses logical and expression")
    func testLogicalAndExpression() throws {
        let source = "(Test: Demo) { Validate the <ok> for true and false. }"
        let program = try Parser.parse(source)

        let statement = program.featureSets[0].statements[0] as! AROStatement
        if let binary = statement.expression as? BinaryExpression {
            #expect(binary.op == .and)
        } else {
            Issue.record("Expected BinaryExpression")
        }
    }

    @Test("Parses logical or expression")
    func testLogicalOrExpression() throws {
        let source = "(Test: Demo) { Validate the <ok> for true or false. }"
        let program = try Parser.parse(source)

        let statement = program.featureSets[0].statements[0] as! AROStatement
        if let binary = statement.expression as? BinaryExpression {
            #expect(binary.op == .or)
        } else {
            Issue.record("Expected BinaryExpression")
        }
    }

    @Test("Parses unary negation expression")
    func testUnaryNegation() throws {
        // Note: The lexer combines -42 into a single negative integer token
        // So -42 becomes a literal, not a unary expression
        // To test unary negation, we need: -<x>
        let source = "(Test: Demo) { Set the <neg> to -<x>. }"
        let program = try Parser.parse(source)

        let statement = program.featureSets[0].statements[0] as! AROStatement
        if let unary = statement.expression as? UnaryExpression {
            #expect(unary.op == .negate)
            #expect(unary.operand is VariableRefExpression)
        } else {
            Issue.record("Expected UnaryExpression")
        }
    }

    @Test("Parses negative integer literal")
    func testNegativeIntegerLiteral() throws {
        let source = "(Test: Demo) { Set the <neg> to -42. }"
        let program = try Parser.parse(source)

        let statement = program.featureSets[0].statements[0] as! AROStatement
        if let literal = statement.expression as? LiteralExpression {
            #expect(literal.value == .integer(-42))
        } else {
            Issue.record("Expected LiteralExpression")
        }
    }

    @Test("Parses unary not expression")
    func testUnaryNot() throws {
        let source = "(Test: Demo) { Set the <neg> to not true. }"
        let program = try Parser.parse(source)

        let statement = program.featureSets[0].statements[0] as! AROStatement
        if let unary = statement.expression as? UnaryExpression {
            #expect(unary.op == .not)
        } else {
            Issue.record("Expected UnaryExpression")
        }
    }

    @Test("Parses grouped expression")
    func testGroupedExpression() throws {
        let source = "(Test: Demo) { Compute the <result> from (1 + 2) * 3. }"
        let program = try Parser.parse(source)

        let statement = program.featureSets[0].statements[0] as! AROStatement
        if let binary = statement.expression as? BinaryExpression {
            #expect(binary.op == .multiply)
            #expect(binary.left is GroupedExpression)
        } else {
            Issue.record("Expected BinaryExpression with grouped left")
        }
    }

    @Test("Parses array literal expression")
    func testArrayLiteralExpression() throws {
        let source = "(Test: Demo) { Set the <items> to [1, 2, 3]. }"
        let program = try Parser.parse(source)

        let statement = program.featureSets[0].statements[0] as! AROStatement
        if let array = statement.expression as? ArrayLiteralExpression {
            #expect(array.elements.count == 3)
        } else {
            Issue.record("Expected ArrayLiteralExpression")
        }
    }

    @Test("Parses map literal expression")
    func testMapLiteralExpression() throws {
        let source = "(Test: Demo) { Set the <config> to { name: \"test\", count: 5 }. }"
        let program = try Parser.parse(source)

        let statement = program.featureSets[0].statements[0] as! AROStatement
        if let map = statement.expression as? MapLiteralExpression {
            #expect(map.entries.count == 2)
            #expect(map.entries[0].key == "name")
            #expect(map.entries[1].key == "count")
        } else {
            Issue.record("Expected MapLiteralExpression")
        }
    }

    @Test("Parses member access expression")
    func testMemberAccessExpression() throws {
        let source = "(Test: Demo) { Extract the <name> from <user>.name. }"
        let program = try Parser.parse(source)

        let statement = program.featureSets[0].statements[0] as! AROStatement
        if let member = statement.expression as? MemberAccessExpression {
            #expect(member.member == "name")
        } else {
            Issue.record("Expected MemberAccessExpression")
        }
    }

    @Test("Parses subscript expression")
    func testSubscriptExpression() throws {
        let source = "(Test: Demo) { Extract the <first> from <items>[0]. }"
        let program = try Parser.parse(source)

        let statement = program.featureSets[0].statements[0] as! AROStatement
        if let subscript_ = statement.expression as? SubscriptExpression {
            if let indexLiteral = subscript_.index as? LiteralExpression {
                #expect(indexLiteral.value == .integer(0))
            }
        } else {
            Issue.record("Expected SubscriptExpression")
        }
    }

    @Test("Parses existence expression")
    func testExistenceExpression() throws {
        let source = "(Test: Demo) { Validate the <ok> for <user> exists. }"
        let program = try Parser.parse(source)

        let statement = program.featureSets[0].statements[0] as! AROStatement
        if let existence = statement.expression as? ExistenceExpression {
            #expect(existence.expression is VariableRefExpression)
        } else {
            Issue.record("Expected ExistenceExpression")
        }
    }

    @Test("Parses type check expression")
    func testTypeCheckExpression() throws {
        let source = "(Test: Demo) { Validate the <ok> for <value> is String. }"
        let program = try Parser.parse(source)

        let statement = program.featureSets[0].statements[0] as! AROStatement
        if let typeCheck = statement.expression as? TypeCheckExpression {
            #expect(typeCheck.typeName == "String")
        } else {
            Issue.record("Expected TypeCheckExpression")
        }
    }
}

// MARK: - Operator Precedence Tests

@Suite("Operator Precedence Tests")
struct OperatorPrecedenceTests {

    @Test("Multiplication has higher precedence than addition")
    func testMulOverAdd() throws {
        let source = "(Test: Demo) { Compute the <result> from 1 + 2 * 3. }"
        let program = try Parser.parse(source)

        let statement = program.featureSets[0].statements[0] as! AROStatement
        if let binary = statement.expression as? BinaryExpression {
            #expect(binary.op == .add)
            // Right operand should be the multiplication
            if let right = binary.right as? BinaryExpression {
                #expect(right.op == .multiply)
            } else {
                Issue.record("Expected right to be multiplication")
            }
        }
    }

    @Test("And has higher precedence than or")
    func testAndOverOr() throws {
        let source = "(Test: Demo) { Validate the <ok> for true or false and true. }"
        let program = try Parser.parse(source)

        let statement = program.featureSets[0].statements[0] as! AROStatement
        if let binary = statement.expression as? BinaryExpression {
            #expect(binary.op == .or)
            // Right operand should be the and
            if let right = binary.right as? BinaryExpression {
                #expect(right.op == .and)
            } else {
                Issue.record("Expected right to be and")
            }
        }
    }

    @Test("Parentheses override precedence")
    func testParenthesesOverride() throws {
        let source = "(Test: Demo) { Compute the <result> from (1 + 2) * 3. }"
        let program = try Parser.parse(source)

        let statement = program.featureSets[0].statements[0] as! AROStatement
        if let binary = statement.expression as? BinaryExpression {
            #expect(binary.op == .multiply)
            // Left should be grouped expression
            #expect(binary.left is GroupedExpression)
        }
    }

    @Test("Comparison has lower precedence than arithmetic")
    func testComparisonPrecedence() throws {
        let source = "(Test: Demo) { Validate the <ok> for 1 + 2 > 2. }"
        let program = try Parser.parse(source)

        let statement = program.featureSets[0].statements[0] as! AROStatement
        if let binary = statement.expression as? BinaryExpression {
            #expect(binary.op == .greaterThan)
            // Left should be the addition
            if let left = binary.left as? BinaryExpression {
                #expect(left.op == .add)
            } else {
                Issue.record("Expected left to be addition")
            }
        }
    }
}

// MARK: - Expression in Statement Tests

@Suite("Expression in Statement Tests")
struct ExpressionInStatementTests {

    @Test("Expression with 'to' preposition")
    func testToPreposition() throws {
        let source = "(Test: Demo) { Set the <x> to 10 + 5. }"
        let program = try Parser.parse(source)

        let statement = program.featureSets[0].statements[0] as! AROStatement
        #expect(statement.object.preposition == .to)
        #expect(statement.expression != nil)
    }

    @Test("Expression with 'from' preposition")
    func testFromPreposition() throws {
        let source = "(Test: Demo) { Compute the <result> from <a> * <b>. }"
        let program = try Parser.parse(source)

        let statement = program.featureSets[0].statements[0] as! AROStatement
        #expect(statement.object.preposition == .from)
        #expect(statement.expression != nil)
    }

    @Test("Expression with 'for' preposition")
    func testForPreposition() throws {
        let source = "(Test: Demo) { Validate the <ok> for <x> > 0. }"
        let program = try Parser.parse(source)

        let statement = program.featureSets[0].statements[0] as! AROStatement
        #expect(statement.expression != nil)
    }

    @Test("Statement without expression still works")
    func testNoExpression() throws {
        let source = "(Test: Demo) { Extract the <user> from the <request>. }"
        let program = try Parser.parse(source)

        let statement = program.featureSets[0].statements[0] as! AROStatement
        #expect(statement.expression == nil)
        #expect(statement.object.noun.base == "request")
    }
}
