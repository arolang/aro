// ============================================================
// ConstantFolderOverflowTests.swift
// AROCompiler Tests - Constant folding must not trap on overflow (GitLab #472)
// ============================================================

import XCTest
@testable import AROCompiler
@testable import AROParser

/// The compile-time folder sees only constant subtrees and returns `nil` for
/// anything it cannot fold. An overflowing integer expression must take that
/// path — folding it would trap the compiler, so the expression is instead left
/// for the runtime, which reports it as a normal error.
final class ConstantFolderOverflowTests: XCTestCase {

    private let span = SourceSpan(at: SourceLocation())

    private func binary(_ lhs: Int, _ op: BinaryOperator, _ rhs: Int) -> BinaryExpression {
        BinaryExpression(
            left: LiteralExpression(value: .integer(lhs), span: span),
            op: op,
            right: LiteralExpression(value: .integer(rhs), span: span),
            span: span
        )
    }

    // MARK: - Overflow declines to fold

    func testAdditionOverflowIsNotFolded() {
        XCTAssertNil(ConstantFolder.evaluate(binary(Int.max, .add, 1)))
    }

    func testSubtractionOverflowIsNotFolded() {
        XCTAssertNil(ConstantFolder.evaluate(binary(Int.min, .subtract, 1)))
    }

    func testMultiplicationOverflowIsNotFolded() {
        XCTAssertNil(ConstantFolder.evaluate(binary(Int.max, .multiply, 2)))
    }

    func testDivisionOverflowIsNotFolded() {
        // Int.min / -1 has no representable quotient.
        XCTAssertNil(ConstantFolder.evaluate(binary(Int.min, .divide, -1)))
    }

    func testModuloOverflowIsNotFolded() {
        XCTAssertNil(ConstantFolder.evaluate(binary(Int.min, .modulo, -1)))
    }

    func testNegatingIntMinIsNotFolded() {
        let expr = UnaryExpression(
            op: .negate,
            operand: LiteralExpression(value: .integer(Int.min), span: span),
            span: span
        )

        XCTAssertNil(ConstantFolder.evaluate(expr))
    }

    func testDivisionByZeroIsStillNotFolded() {
        XCTAssertNil(ConstantFolder.evaluate(binary(1, .divide, 0)))
    }

    // MARK: - Non-overflowing expressions still fold

    func testOrdinaryArithmeticStillFolds() {
        XCTAssertEqual(ConstantFolder.evaluate(binary(2, .add, 3)), .integer(5))
        XCTAssertEqual(ConstantFolder.evaluate(binary(10, .subtract, 4)), .integer(6))
        XCTAssertEqual(ConstantFolder.evaluate(binary(6, .multiply, 7)), .integer(42))
        XCTAssertEqual(ConstantFolder.evaluate(binary(80, .divide, 3)), .integer(26))
        XCTAssertEqual(ConstantFolder.evaluate(binary(7, .modulo, 3)), .integer(1))
    }

    func testBoundaryValuesStillFold() {
        XCTAssertEqual(ConstantFolder.evaluate(binary(Int.max, .add, 0)), .integer(Int.max))
        XCTAssertEqual(ConstantFolder.evaluate(binary(Int.min, .subtract, 0)), .integer(Int.min))
        XCTAssertEqual(ConstantFolder.evaluate(binary(Int.max, .multiply, 1)), .integer(Int.max))
    }

    func testNegationStillFolds() {
        let expr = UnaryExpression(
            op: .negate,
            operand: LiteralExpression(value: .integer(42), span: span),
            span: span
        )

        XCTAssertEqual(ConstantFolder.evaluate(expr), .integer(-42))
    }

    func testFoldLeavesOverflowingExpressionIntact() {
        // `fold` returns the original expression when `evaluate` declines.
        let expr = binary(Int.max, .multiply, 2)

        XCTAssertTrue(ConstantFolder.fold(expr) is BinaryExpression)
    }

    func testFoldCollapsesFoldableExpression() {
        XCTAssertTrue(ConstantFolder.fold(binary(2, .multiply, 3)) is LiteralExpression)
    }
}
