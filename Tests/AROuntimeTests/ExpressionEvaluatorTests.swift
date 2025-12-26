// ============================================================
// ExpressionEvaluatorTests.swift
// ARO Runtime - Expression Evaluator Unit Tests
// ============================================================

import Foundation
import Testing
@testable import ARORuntime
@testable import AROParser

// MARK: - Expression Evaluator Tests

@Suite("Expression Evaluator Tests")
struct ExpressionEvaluatorTests {

    let evaluator = ExpressionEvaluator()

    @Test("Evaluator can be instantiated")
    func testEvaluatorInit() {
        let evaluator = ExpressionEvaluator()
        #expect(evaluator != nil)
    }
}

// MARK: - Null Value Tests

@Suite("Null Value Tests")
struct NullValueTests {

    @Test("Null value description")
    func testNullDescription() {
        let null = NullValue.null
        #expect(null.description == "null")
    }

    @Test("Null values are equal")
    func testNullEquality() {
        #expect(NullValue.null == NullValue.null)
    }

    @Test("Null value singleton")
    func testNullSingleton() {
        let a = NullValue.null
        let b = NullValue.null
        #expect(a == b)
    }
}

// MARK: - Expression Error Tests

@Suite("Expression Error Tests")
struct ExpressionErrorTests {

    @Test("Undefined variable error description")
    func testUndefinedVariableError() {
        let error = ExpressionError.undefinedVariable("foo")
        #expect(error.description.contains("foo"))
        #expect(error.description.contains("Undefined"))
    }

    @Test("Undefined member error description")
    func testUndefinedMemberError() {
        let error = ExpressionError.undefinedMember("bar")
        #expect(error.description.contains("bar"))
        #expect(error.description.contains("member"))
    }

    @Test("Type mismatch error description")
    func testTypeMismatchError() {
        let error = ExpressionError.typeMismatch("Expected Int")
        #expect(error.description.contains("Type mismatch"))
        #expect(error.description.contains("Expected Int"))
    }

    @Test("Index out of bounds error description")
    func testIndexOutOfBoundsError() {
        let error = ExpressionError.indexOutOfBounds(10, count: 5)
        #expect(error.description.contains("10"))
        #expect(error.description.contains("5"))
    }

    @Test("Unsupported expression error description")
    func testUnsupportedExpressionError() {
        let error = ExpressionError.unsupportedExpression("CustomExpr")
        #expect(error.description.contains("CustomExpr"))
    }
}
