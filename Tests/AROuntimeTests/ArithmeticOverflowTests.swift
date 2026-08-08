// ============================================================
// ArithmeticOverflowTests.swift
// ARO Runtime - Integer overflow reporting (GitLab #472)
// ============================================================

import Foundation
import Testing
@testable import ARORuntime
@testable import AROParser

/// Evaluates an ARO expression source string through the interpreter.
private func evaluate(_ source: String) async throws -> any Sendable {
    let program = try Parser.parse("""
    (Test: Test) {
        Compute the <r> from \(source).
        Return an <OK: status> with <r>.
    }
    """)
    let statement = try #require(program.featureSets[0].statements[0] as? AROStatement)
    let expression = try #require(statement.valueSource.asExpression)
    let context = RuntimeContext(featureSetName: "Test")
    return try await ExpressionEvaluator().evaluate(expression, context: context)
}

// MARK: - Overflow Is Reported, Not Trapped

@Suite("Integer Overflow Reporting")
struct IntegerOverflowReportingTests {

    @Test("Addition overflow throws instead of trapping")
    func testAdditionOverflow() async throws {
        await #expect(throws: ActionError.self) {
            _ = try await evaluate("9223372036854775807 + 1")
        }
    }

    @Test("Subtraction overflow throws")
    func testSubtractionOverflow() async throws {
        await #expect(throws: ActionError.self) {
            _ = try await evaluate("-9223372036854775808 - 1")
        }
    }

    @Test("Multiplication overflow throws")
    func testMultiplicationOverflow() async throws {
        await #expect(throws: ActionError.self) {
            _ = try await evaluate("9223372036854775807 * 2")
        }
    }

    @Test("Int.min / -1 overflow throws")
    func testDivisionOverflow() async throws {
        await #expect(throws: ActionError.self) {
            _ = try await evaluate("-9223372036854775808 / -1")
        }
    }

    @Test("Int.min % -1 overflow throws")
    func testModuloOverflow() async throws {
        await #expect(throws: ActionError.self) {
            _ = try await evaluate("-9223372036854775808 % -1")
        }
    }

    @Test("Negating Int.min throws")
    func testNegationOverflow() async throws {
        await #expect(throws: ActionError.self) {
            _ = try await evaluate("0 - -9223372036854775808")
        }
    }

    @Test("Division by zero still reports its own message")
    func testDivisionByZeroMessageIsDistinct() async throws {
        // Overflow reporting must not swallow the more specific zero-divisor
        // message: dividedReportingOverflow(by: 0) also sets `overflow`.
        do {
            _ = try await evaluate("1 / 0")
            Issue.record("expected a runtime error")
        } catch let error as ActionError {
            #expect("\(error)".contains("Division by zero"))
        }
    }

    @Test("Overflow message names the operands and operator")
    func testOverflowMessageContent() async throws {
        do {
            _ = try await evaluate("9223372036854775807 + 1")
            Issue.record("expected a runtime error")
        } catch let error as ActionError {
            let text = "\(error)"
            #expect(text.contains("Integer overflow"))
            #expect(text.contains("9223372036854775807"))
            #expect(text.contains("+"))
        }
    }
}

// MARK: - Exact Int Arithmetic

@Suite("Exact Integer Arithmetic")
struct ExactIntegerArithmeticTests {

    @Test("Addition above 2^53 is exact")
    func testAdditionAbovePow53() async throws {
        // Previously routed through Double, which cannot represent 2^53+1,
        // so this silently returned 9007199254740994.
        let result = try await evaluate("9007199254740993 + 2")

        #expect(result as? Int == 9_007_199_254_740_995)
    }

    @Test("Multiplication above 2^53 is exact")
    func testMultiplicationAbovePow53() async throws {
        // Previously returned 9007199254740992.
        let result = try await evaluate("9007199254740993 * 1")

        #expect(result as? Int == 9_007_199_254_740_993)
    }

    @Test("Int.max round-trips through addition of zero")
    func testIntMaxRoundTrip() async throws {
        let result = try await evaluate("9223372036854775807 + 0")

        #expect(result as? Int == Int.max)
    }

    @Test("Ordinary integer arithmetic still yields Int")
    func testOrdinaryIntegerArithmetic() async throws {
        #expect(try await evaluate("2 + 3") as? Int == 5)
        #expect(try await evaluate("10 - 4") as? Int == 6)
        #expect(try await evaluate("6 * 7") as? Int == 42)
        #expect(try await evaluate("7 % 3") as? Int == 1)
    }

    @Test("Integer division still truncates toward zero")
    func testIntegerDivisionTruncates() async throws {
        #expect(try await evaluate("7 / 2") as? Int == 3)
        #expect(try await evaluate("80 / 3") as? Int == 26)
    }

    @Test("Mixed Int/Double arithmetic still yields Double")
    func testMixedArithmeticYieldsDouble() async throws {
        #expect(try await evaluate("7.0 / 2") as? Double == 3.5)
        #expect(try await evaluate("7 / 2.0") as? Double == 3.5)
        #expect(try await evaluate("1 + 0.5") as? Double == 1.5)
    }

    @Test("String repetition via * is unaffected")
    func testStringRepetitionUnaffected() async throws {
        #expect(try await evaluate(#""ab" * 3"# ) as? String == "ababab")
    }
}
