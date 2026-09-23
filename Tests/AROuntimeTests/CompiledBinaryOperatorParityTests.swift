// ============================================================
// CompiledBinaryOperatorParityTests.swift
// ARORuntimeTests - every operator the compiler emits is evaluated
// (GitLab #516, #558)
// ============================================================
//
// Compiled code evaluates a `when` guard by serializing the expression to JSON
// (`ExpressionSerializer`, using `binary.op.rawValue`) and calling back into
// `evaluateBinaryOp`. An operator that switch does not recognise falls to
// `default`, which returned "" — and `asBool("")` is false, so the guard
// silently failed and the statement was skipped. `aro build` then did less
// than `aro run` for the same source, with no diagnostic from either.
//
// That is how `before` and `after` shipped broken in compiled mode (#516), and
// `in` would have shipped the same way (#558). This test compares the operator
// set the parser can produce against what the bridge actually evaluates, so
// the next operator cannot repeat it.

import Testing
import Foundation
import AROParser
@testable import ARORuntime

@Suite("Compiled binary operator parity (GitLab #516, #558)")
struct CompiledBinaryOperatorParityTests {

    /// Operators resolved *before* the eager operand evaluation, so they never
    /// reach `evaluateBinaryOp`. Only one: `default` has to see its left
    /// operand's absence, which an evaluated value cannot express
    /// (GitLab #547).
    static let handledBeforeOperands: Set<BinaryOperator> = [.defaulting]

    /// Operands that make sense for each operator. Arithmetic needs numbers,
    /// membership needs a container on the right, `matches` a pattern.
    private func operands(for op: BinaryOperator) -> (left: any Sendable, right: any Sendable) {
        switch op {
        case .add, .subtract, .multiply, .divide, .modulo,
             .lessThan, .greaterThan, .lessEqual, .greaterEqual:
            return (2, 1)
        case .concat:
            return ("a", "b")
        case .and, .or:
            return (true, true)
        case .in, .notIn:
            return ("a", ["a", "b"] as [any Sendable])
        case .startsWith, .endsWith:
            return ("report.aro", "report.aro")
        case .contains:
            return (["a", "b"] as [any Sendable], "a")
        case .subset:
            return (["a"] as [any Sendable], ["a", "b"] as [any Sendable])
        case .matches:
            return ("abc", "a.c")
        case .before, .after:
            return ("2020-01-01T00:00:00Z", "2030-01-01T00:00:00Z")
        case .equal, .notEqual, .is, .isNot:
            return ("a", "a")
        case .defaulting:
            return ("a", "b")
        }
    }

    @Test("Every BinaryOperator the parser can emit is evaluated, not silently dropped")
    func everyOperatorIsHandled() {
        var unhandled: [String] = []

        for op in BinaryOperator.allCases where !Self.handledBeforeOperands.contains(op) {
            let (left, right) = operands(for: op)
            // The serializer emits the raw value, so that is what must be matched.
            let result = evaluateBinaryOp(op: op.rawValue, left: left, right: right)

            // "" is the unhandled sentinel. `concat` is the one operator whose
            // legitimate result is a String, and with these operands it is "ab".
            if let s = result as? String, s.isEmpty {
                unhandled.append(op.rawValue)
            }
        }

        #expect(unhandled.isEmpty,
                "operators the compiled evaluator drops to default: \(unhandled)")
    }

    @Test("The operators this closed produce the right answers, not merely an answer")
    func theFixedOperatorsAreCorrect() {
        // before / after (#516)
        #expect(evaluateBinaryOp(op: "before",
                                 left: "2020-01-01T00:00:00Z",
                                 right: "2030-01-01T00:00:00Z") as? Bool == true)
        #expect(evaluateBinaryOp(op: "before",
                                 left: "2030-01-01T00:00:00Z",
                                 right: "2020-01-01T00:00:00Z") as? Bool == false)
        #expect(evaluateBinaryOp(op: "after",
                                 left: "2030-01-01T00:00:00Z",
                                 right: "2020-01-01T00:00:00Z") as? Bool == true)

        // subset of (#864). This test is why it was caught: the first compiled
        // run of `<a> subset of <b>` warned and answered false.
        #expect(evaluateBinaryOp(op: "subset of",
                                 left: ["a"] as [any Sendable],
                                 right: ["a", "b"] as [any Sendable]) as? Bool == true)
        #expect(evaluateBinaryOp(op: "subset of",
                                 left: ["a", "c"] as [any Sendable],
                                 right: ["a", "b"] as [any Sendable]) as? Bool == false)

        // in, over a collection (#558)
        let tags: [any Sendable] = ["red", "green"]
        #expect(evaluateBinaryOp(op: "in", left: "red", right: tags) as? Bool == true)
        #expect(evaluateBinaryOp(op: "in", left: "blue", right: tags) as? Bool == false)

        // in is the inverse of contains
        #expect(evaluateBinaryOp(op: "in", left: "red", right: tags) as? Bool
                == evaluateBinaryOp(op: "contains", left: tags, right: "red") as? Bool)

        // not in, starts with, ends with (GitLab #830 item 5)
        #expect(evaluateBinaryOp(op: "not in", left: "blue", right: tags) as? Bool == true)
        #expect(evaluateBinaryOp(op: "not in", left: "red", right: tags) as? Bool == false)
        // Exactly the negation, for every operand shape `in` accepts.
        for candidate in ["red", "green", "blue"] {
            let inside = evaluateBinaryOp(op: "in", left: candidate, right: tags) as? Bool
            let outside = evaluateBinaryOp(op: "not in", left: candidate, right: tags) as? Bool
            #expect(inside == !(outside ?? true), "in/not in disagree about '\(candidate)'")
        }

        #expect(evaluateBinaryOp(op: "starts with", left: "/api/users", right: "/api") as? Bool == true)
        #expect(evaluateBinaryOp(op: "starts with", left: "/api/users", right: "/web") as? Bool == false)
        #expect(evaluateBinaryOp(op: "ends with", left: "main.aro", right: ".aro") as? Bool == true)
        #expect(evaluateBinaryOp(op: "ends with", left: "main.md", right: ".aro") as? Bool == false)
        // A whole string is both its own prefix and its own suffix, and the
        // empty affix is in every string — the boundary cases a hand-rolled
        // `matches "^…"` workaround tends to get wrong.
        #expect(evaluateBinaryOp(op: "starts with", left: "abc", right: "abc") as? Bool == true)
        #expect(evaluateBinaryOp(op: "ends with", left: "abc", right: "") as? Bool == true)
    }

    /// The affix operators are not regexes, which is the point of having
    /// them: `matches "^a.c"` accepts "abc" *and* "axc", and every caller
    /// who wanted a literal prefix had to remember to escape.
    @Test("An affix test is literal, where the regex workaround was not")
    func affixIsLiteralNotPattern() {
        #expect(evaluateBinaryOp(op: "starts with", left: "a.c-file", right: "a.c") as? Bool == true)
        #expect(evaluateBinaryOp(op: "starts with", left: "axc-file", right: "a.c") as? Bool == false)
        // The regex the books taught instead, for contrast.
        #expect(evaluateBinaryOp(op: "matches", left: "axc-file", right: "^a.c") as? Bool == true)
    }

    @Test("A date-range carries membership, in either operand order")
    func dateRangeMembership() throws {
        let iso = ISO8601DateFormatter()
        let start = ARODate(date: try #require(iso.date(from: "2026-01-01T00:00:00Z")))
        let end = ARODate(date: try #require(iso.date(from: "2026-12-31T00:00:00Z")))
        let range = ARODateRange(from: start, to: end)

        #expect(evaluateBinaryOp(op: "in",
                                 left: "2026-06-01T00:00:00Z",
                                 right: range) as? Bool == true)
        #expect(evaluateBinaryOp(op: "in",
                                 left: "2030-06-01T00:00:00Z",
                                 right: range) as? Bool == false)
        // The interpreter's containsValue accepts the reversed order too
        // (ARO-0041); the compiled path matches it.
        #expect(evaluateBinaryOp(op: "in",
                                 left: range,
                                 right: "2026-06-01T00:00:00Z") as? Bool == true)
    }

    @Test("`is not` is matched under the spelling the serializer emits")
    func isNotUsesItsRawValue() {
        // The case label is `isNot`; the raw value — and so the wire form — is
        // "is not". Matching only the label would have been a silent false.
        #expect(BinaryOperator.isNot.rawValue == "is not")
        #expect(evaluateBinaryOp(op: "is not", left: "a", right: "b") as? Bool == true)
        #expect(evaluateBinaryOp(op: "is not", left: "a", right: "a") as? Bool == false)
    }
}
