// ============================================================
// ResultTypeAnnotationTests.swift
// ARO Runtime - `as <Type>` result annotations (GitLab #475)
// ============================================================

import Foundation
import Testing
@testable import ARORuntime
@testable import AROParser

// MARK: - Parsing

@Suite("As-Type Parsing")
struct AsTypeParsingTests {

    private func statement(_ source: String) throws -> AROStatement {
        let program = try Parser.parse("""
        (Test: Test) {
            \(source)
        }
        """)
        return try #require(program.featureSets[0].statements[0] as? AROStatement)
    }

    @Test("as Type is recorded separately from the qualifier")
    func testAsTypeIsSeparate() throws {
        let aro = try statement("Compute the <n: length> as Integer from <s>.")

        // Regression: `as` used to overwrite typeAnnotation, discarding `length`
        // and silently changing the statement into an identity computation.
        #expect(aro.result.specifiers == ["length"])
        #expect(aro.result.asType == "Integer")
    }

    @Test("as Type without a qualifier leaves specifiers empty")
    func testAsTypeAlone() throws {
        let aro = try statement("Compute the <d> as Float from <x> / 2.")

        #expect(aro.result.specifiers.isEmpty)
        #expect(aro.result.asType == "Float")
    }

    @Test("A qualifier without as Type leaves asType nil")
    func testQualifierAlone() throws {
        let aro = try statement("Compute the <n: length> from <s>.")

        #expect(aro.result.specifiers == ["length"])
        #expect(aro.result.asType == nil)
    }

    @Test("asType reaches the ResultDescriptor")
    func testReachesDescriptor() throws {
        let aro = try statement("Compute the <n: length> as Float from <s>.")
        let descriptor = ResultDescriptor(from: aro.result)

        #expect(descriptor.specifiers == ["length"])
        #expect(descriptor.asType == "Float")
    }
}

// MARK: - Coercion

@Suite("Result Type Coercion")
struct ResultTypeCoercionTests {

    @Test("Float annotations are recognised")
    func testRecognisesFloat() {
        #expect(ResultTypeCoercion.requestsFloat("Float"))
        #expect(ResultTypeCoercion.requestsFloat("float"))
        #expect(ResultTypeCoercion.requestsFloat("Double"))
        #expect(!ResultTypeCoercion.requestsFloat("Integer"))
        #expect(!ResultTypeCoercion.requestsFloat(nil))
    }

    @Test("Integer annotations are recognised")
    func testRecognisesInteger() {
        #expect(ResultTypeCoercion.requestsInteger("Integer"))
        #expect(ResultTypeCoercion.requestsInteger("int"))
        #expect(!ResultTypeCoercion.requestsInteger("Float"))
    }

    @Test("Int widens to Double under as Float")
    func testWidening() {
        #expect(ResultTypeCoercion.coerce(4, to: "Float") as? Double == 4.0)
    }

    @Test("Double narrows to Int under as Integer only when lossless")
    func testLosslessNarrowing() {
        #expect(ResultTypeCoercion.coerce(4.0, to: "Integer") as? Int == 4)
        // 3.7 would have to be truncated — leave it alone rather than silently
        // dropping the fraction under an annotation.
        #expect(ResultTypeCoercion.coerce(3.7, to: "Integer") as? Double == 3.7)
    }

    @Test("Narrowing does not trap for out-of-range Doubles")
    func testNarrowingDoesNotTrap() {
        // Int(1e21) would trap; must fall through unchanged.
        #expect(ResultTypeCoercion.coerce(1e21, to: "Integer") as? Double == 1e21)
    }

    @Test("Numeric strings are converted")
    func testNumericStrings() {
        #expect(ResultTypeCoercion.coerce("2.5", to: "Float") as? Double == 2.5)
        #expect(ResultTypeCoercion.coerce("7", to: "Integer") as? Int == 7)
    }

    @Test("Non-numeric annotations leave the value untouched")
    func testNonNumericAnnotationIsInert() {
        // A schema name must not mangle the value.
        #expect(ResultTypeCoercion.coerce("hello", to: "User") as? String == "hello")
        #expect(ResultTypeCoercion.coerce(4, to: nil) as? Int == 4)
    }

    @Test("Non-numeric values are untouched by numeric annotations")
    func testNonNumericValueIsInert() {
        #expect(ResultTypeCoercion.coerce("abc", to: "Float") as? String == "abc")
    }
}

// MARK: - Evaluation

@Suite("Float-Mode Expression Evaluation")
struct FloatModeEvaluationTests {

    private func evaluate(_ source: String, mode: ExpressionEvaluator.NumericMode) async throws -> any Sendable {
        let program = try Parser.parse("""
        (Test: Test) {
            Compute the <r> from \(source).
            Return an <OK: status> with <r>.
        }
        """)
        let aro = try #require(program.featureSets[0].statements[0] as? AROStatement)
        let expression = try #require(aro.valueSource.asExpression)
        let context = RuntimeContext(featureSetName: "Test")
        return try await ExpressionEvaluator(numericMode: mode).evaluate(expression, context: context)
    }

    @Test("Integer division truncates in natural mode")
    func testNaturalDivision() async throws {
        #expect(try await evaluate("7 / 2", mode: .natural) as? Int == 3)
    }

    @Test("Integer division is exact in float mode")
    func testFloatDivision() async throws {
        #expect(try await evaluate("7 / 2", mode: .float) as? Double == 3.5)
    }

    @Test("Whole results stay Double in float mode")
    func testWholeStaysDouble() async throws {
        // Narrowing back to Int would discard the annotation again.
        #expect(try await evaluate("7 * 2", mode: .float) as? Double == 14.0)
        #expect(try await evaluate("2 + 3", mode: .float) as? Double == 5.0)
    }

    @Test("Whole results narrow to Int in natural mode")
    func testWholeNarrowsInNaturalMode() async throws {
        #expect(try await evaluate("7 * 2", mode: .natural) as? Int == 14)
    }

    @Test("Float mode propagates into sub-expressions")
    func testModePropagates() async throws {
        // The mode is stored on the evaluator, so nested evaluation inherits it.
        #expect(try await evaluate("7 / 2 + 1", mode: .float) as? Double == 4.5)
    }

    @Test("Division by zero is still reported in float mode")
    func testDivisionByZeroStillGuarded() async throws {
        await #expect(throws: ActionError.self) {
            _ = try await evaluate("7 / 0", mode: .float)
        }
    }

    @Test("Non-arithmetic expressions are unaffected by float mode")
    func testNonArithmeticUnaffected() async throws {
        #expect(try await evaluate("\"a\" ++ \"b\"", mode: .float) as? String == "ab")
        #expect(try await evaluate("3 < 5", mode: .float) as? Bool == true)
    }
}
