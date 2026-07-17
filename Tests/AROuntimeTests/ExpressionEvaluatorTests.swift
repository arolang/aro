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

// MARK: - Contains Operator Tests (Issue #296)

/// Behavioural tests for the `contains` binary operator.
///
/// `<a> contains <b>` dispatches on the runtime type of the left-hand side:
///   - `a` is a list/collection  -> element membership
///   - `a` is a string, `b` is a string -> substring match (Issue #296)
///   - `a` is a map, `b` is a string -> key membership
///   - other type combinations -> false
@Suite("Contains Operator Tests")
struct ContainsOperatorTests {

    let evaluator = ExpressionEvaluator()

    private let span = SourceSpan(at: SourceLocation())

    /// Build `<lhsVar> contains <rhsVar>` where both operands are variable refs
    /// resolved from the supplied context.
    private func containsExpr(lhs: String, rhs: String) -> BinaryExpression {
        let left = VariableRefExpression(noun: QualifiedNoun(base: lhs, span: span), span: span)
        let right = VariableRefExpression(noun: QualifiedNoun(base: rhs, span: span), span: span)
        return BinaryExpression(left: left, op: .contains, right: right, span: span)
    }

    private func evalContains(
        lhs: String, lhsValue: any Sendable,
        rhs: String, rhsValue: any Sendable
    ) async throws -> Bool {
        let context = RuntimeContext(featureSetName: "Test")
        context.bind(lhs, value: lhsValue)
        context.bind(rhs, value: rhsValue)
        let result = try await evaluator.evaluate(containsExpr(lhs: lhs, rhs: rhs), context: context)
        return (result as? Bool) ?? false
    }

    // MARK: String contains string (the new behaviour)

    @Test("String contains substring -> true")
    func testStringContainsSubstringTrue() async throws {
        let hit = try await evalContains(
            lhs: "url", lhsValue: "https://mastodon.social/@user",
            rhs: "domain", rhsValue: "mastodon.social"
        )
        #expect(hit == true)
    }

    @Test("String does not contain substring -> false")
    func testStringContainsSubstringFalse() async throws {
        let hit = try await evalContains(
            lhs: "url", lhsValue: "https://mastodon.social/@user",
            rhs: "domain", rhsValue: "example.com"
        )
        #expect(hit == false)
    }

    @Test("String contains itself -> true")
    func testStringContainsItself() async throws {
        let hit = try await evalContains(
            lhs: "a", lhsValue: "hello",
            rhs: "b", rhsValue: "hello"
        )
        #expect(hit == true)
    }

    @Test("String contains empty string -> true")
    func testStringContainsEmpty() async throws {
        let hit = try await evalContains(
            lhs: "a", lhsValue: "hello",
            rhs: "b", rhsValue: ""
        )
        #expect(hit == true)
    }

    // MARK: List contains element (existing behaviour, must be unchanged)

    @Test("List contains element -> true")
    func testListContainsElementTrue() async throws {
        let hit = try await evalContains(
            lhs: "roles", lhsValue: ["admin", "user"] as [any Sendable],
            rhs: "needle", rhsValue: "admin"
        )
        #expect(hit == true)
    }

    @Test("List does not contain element -> false")
    func testListContainsElementFalse() async throws {
        let hit = try await evalContains(
            lhs: "roles", lhsValue: ["admin", "user"] as [any Sendable],
            rhs: "needle", rhsValue: "root"
        )
        #expect(hit == false)
    }

    @Test("List membership does NOT do substring match on elements")
    func testListMembershipIsNotSubstring() async throws {
        // "adm" is a substring of the element "admin" but is not itself an
        // element, so list membership must return false.
        let hit = try await evalContains(
            lhs: "roles", lhsValue: ["admin", "user"] as [any Sendable],
            rhs: "needle", rhsValue: "adm"
        )
        #expect(hit == false)
    }

    @Test("List contains numeric element -> true")
    func testListContainsNumericElement() async throws {
        let hit = try await evalContains(
            lhs: "nums", lhsValue: [1, 2, 3] as [any Sendable],
            rhs: "needle", rhsValue: 2
        )
        #expect(hit == true)
    }

    // MARK: Map contains key

    @Test("Map contains key -> true")
    func testMapContainsKey() async throws {
        let hit = try await evalContains(
            lhs: "obj", lhsValue: ["name": "kris", "age": 40] as [String: any Sendable],
            rhs: "key", rhsValue: "name"
        )
        #expect(hit == true)
    }

    @Test("Map does not contain key -> false")
    func testMapMissingKey() async throws {
        let hit = try await evalContains(
            lhs: "obj", lhsValue: ["name": "kris"] as [String: any Sendable],
            rhs: "key", rhsValue: "email"
        )
        #expect(hit == false)
    }

    // MARK: Mismatched types

    @Test("Int LHS contains anything -> false (unsupported combination)")
    func testIntLhsIsFalse() async throws {
        let hit = try await evalContains(
            lhs: "n", lhsValue: 12345,
            rhs: "needle", rhsValue: "2"
        )
        #expect(hit == false)
    }

    @Test("String LHS with non-string RHS -> false")
    func testStringLhsNonStringRhs() async throws {
        let hit = try await evalContains(
            lhs: "a", lhsValue: "hello123",
            rhs: "b", rhsValue: 123
        )
        #expect(hit == false)
    }
}
