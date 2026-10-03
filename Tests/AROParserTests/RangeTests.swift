// ============================================================
// RangeTests.swift
// AROParser — `1..10` and `1..<10` (ARO-0089, GitLab #546)
// ============================================================
//
// Three lexing hazards had to be settled before ranges could exist, and all
// three are asserted here rather than described:
//
//   `1..10` must not read as `1.0` then `.10`              — §4.1
//   `0..<<count>` must be rejected rather than guessed      — §4.2
//   `<a: 1..10>` must not be read as a qualifier            — §4.3
//
// Plus the two shapes the language deliberately refuses: `[1..10]` (§5) and a
// range as a comparison operand (§2.2). Each of those used to be a cascade of
// three or four parser errors pointing at the following line, which is the
// reason the proposal spends a section on each.

import Testing
import Foundation
@testable import AROParser

@Suite("Ranges (ARO-0089, #546)")
struct RangeTests {

    private func tokens(_ source: String) throws -> [TokenKind] {
        try Lexer.tokenize(source).map(\.kind)
    }

    private func diagnostics(for source: String) -> [Diagnostic] {
        Compiler().compile(source, pluginActionsPossible: false).diagnostics
    }

    private func errors(in source: String) -> [String] {
        diagnostics(for: source).filter { $0.severity == .error }.map(\.message)
    }

    private func expression(_ source: String) throws -> any AROParser.Expression {
        let program = try Parser.parse(source)
        let statement = try #require(program.featureSets[0].statements[0] as? AROStatement)
        return try #require(statement.expression)
    }

    // MARK: - §4.1 Lexing: a range is not a float

    @Test("`1..10` lexes as Int, range, Int — not `1.0` and `.10`")
    func inclusiveRangeLexes() throws {
        #expect(try tokens("1..10").prefix(3) == [.intLiteral(1), .rangeInclusive, .intLiteral(10)])
    }

    @Test("`1..<10` lexes as the exclusive operator")
    func exclusiveRangeLexes() throws {
        #expect(try tokens("1..<10").prefix(3) == [.intLiteral(1), .rangeExclusive, .intLiteral(10)])
    }

    @Test("A float is still a float, and a trailing dot still ends a statement")
    func floatsAreUnaffected() throws {
        #expect(try tokens("1.5").first == .floatLiteral(1.5))
        #expect(try tokens("1.").prefix(2) == [.intLiteral(1), .dot])
    }

    @Test("Numeric separators work in endpoints (ARO-0082)")
    func separatorsInEndpoints() throws {
        #expect(try tokens("1_001..2_000").prefix(3)
                == [.intLiteral(1001), .rangeInclusive, .intLiteral(2000)])
    }

    @Test("`1...10` is an error naming the two real spellings")
    func threeDotsIsAnError() {
        let messages = errors(in: "(Application-Start: D) { Compute the <a: length> from 1...10. }")
        #expect(messages.contains { $0.contains("Unknown operator '...'") })
    }

    // MARK: - §4.2 `..<<` is rejected, not guessed

    @Test("`0..<<count>` is rejected and names the fix")
    func rangeOperatorNeedsSpace() {
        let messages = errors(in: """
        (Application-Start: D) {
            Create the <count> with 24.
            for each <i> in 0..<<count> {
                Log <i> to the <console>.
            }
            Return an <OK: status> for the <d>.
        }
        """)
        #expect(messages.contains { $0.contains("'..< <name>'") })
    }

    @Test("`<lo>..<hi>` is an inclusive range of two references, not `..<`")
    func referenceEndpointsReadAsInclusive() throws {
        // The characters of `<lo>..<hi>` contain `..<`. Reading them as the
        // exclusive operator would make the most natural way to write a
        // computed range mean something else — hence the rule that a `<`
        // opening a reference belongs to the reference (§4.2).
        let range = try #require(
            try expression("(D: X) { Create the <r> with <lo>..<hi>. }") as? RangeExpression)
        #expect(range.isInclusive)
        #expect((range.lower as? VariableRefExpression)?.noun.base == "lo")
        #expect((range.upper as? VariableRefExpression)?.noun.base == "hi")
    }

    @Test("`<lo>..< <hi>` — with the space — is exclusive")
    func spacedExclusiveWithReference() throws {
        let range = try #require(
            try expression("(D: X) { Create the <r> with <lo>..< <hi>. }") as? RangeExpression)
        #expect(!range.isInclusive)
    }

    // MARK: - §4.3 The qualifier slot excludes ranges

    @Test("`<a: 1..10>` is an error pointing at the object form")
    func rangeInQualifierSlot() {
        let messages = errors(in: """
        (Application-Start: D) {
            Create the <count> with 3.
            Compute the <a: 1..10> from <count>.
            Return an <OK: status> for the <d>.
        }
        """)
        #expect(messages.contains { $0.contains("A range cannot appear in a qualifier") })
    }

    // MARK: - §5 `[1..10]` is an error

    @Test("`[1..10]` is rejected rather than defined as sugar")
    func bracketedRangeIsAnError() {
        let messages = errors(in: """
        (Application-Start: D) {
            for each <n> in [1..10] {
                Log <n> to the <console>.
            }
            Return an <OK: status> for the <d>.
        }
        """)
        #expect(messages.contains { $0.contains("list holding one range") })
    }

    // MARK: - §2.2 Precedence and chaining

    @Test("A range binds looser than arithmetic: `1..<n> + 1` is `1..(<n> + 1)`")
    func looserThanArithmetic() throws {
        let range = try #require(
            try expression("(D: X) { Create the <r> with 1..<n> + 1. }") as? RangeExpression)
        let upper = try #require(range.upper as? BinaryExpression)
        #expect(upper.op == .add)
        #expect(range.isInclusive)
    }

    @Test("Ranges do not chain")
    func rangesDoNotChain() {
        let messages = errors(in: "(Application-Start: D) { Create the <r> with 1..5..10. }")
        #expect(messages.contains { $0.contains("Ranges do not chain") })
    }

    @Test("A range is not a comparison operand")
    func notAComparisonOperand() {
        let messages = errors(in: """
        (Application-Start: D) {
            Return an <OK: status> for the <d> when 1..10 == 3.
        }
        """)
        #expect(messages.contains { $0.contains("cannot be an operand of `==`") })
    }

    // MARK: - §3.1 Endpoint types

    @Test("A Float endpoint is a check-time error naming the side")
    func floatEndpointRejected() {
        let messages = errors(in: "(Application-Start: D) { Create the <r> with 1..2.5. }")
        #expect(messages.contains {
            $0.contains("must be an Int") && $0.contains("upper endpoint") && $0.contains("Float")
        })
    }

    @Test("A String endpoint is a check-time error too")
    func stringEndpointRejected() {
        let messages = errors(in: "(Application-Start: D) { Create the <r> with 1..\"ten\". }")
        #expect(messages.contains { $0.contains("must be an Int") && $0.contains("String") })
    }

    @Test("Int endpoints pass `aro check` clean")
    func intEndpointsAreClean() {
        let messages = errors(in: """
        (Application-Start: D) {
            for each <n> in 1..10 {
                Log <n> to the <console>.
            }
            Compute the <len: length> from 0..<24.
            Log <len> to the <console>.
            Return an <OK: status> for the <d>.
        }
        """)
        #expect(messages.isEmpty, "unexpected errors: \(messages)")
    }

    // MARK: - Where a range is allowed (§3.4)

    @Test("The `for each` collection slot takes a range")
    func forEachCollectionSlot() throws {
        let program = try Parser.parse("""
        (D: X) {
            for each <n> in 1..10 {
                Log <n> to the <console>.
            }
        }
        """)
        let loop = try #require(program.featureSets[0].statements[0] as? ForEachLoop)
        let range = try #require(loop.collectionExpression as? RangeExpression)
        #expect(range.isInclusive)
        #expect((range.upper as? LiteralExpression)?.value == .integer(10))
    }

    @Test("An action argument takes a range")
    func actionArgumentSlot() throws {
        let program = try Parser.parse("(D: X) { Application.Histogram the <h> from 0..<24. }")
        let statement = try #require(program.featureSets[0].statements[0] as? AROStatement)
        let range = try #require(statement.expression as? RangeExpression)
        #expect(!range.isInclusive)
    }

    // MARK: - Data flow

    @Test("Both endpoints count as reads of their variables")
    func endpointsAreReads() throws {
        let program = try Parser.parse("(D: X) { Create the <r> with <lo>..<hi>. }")
        let statement = try #require(program.featureSets[0].statements[0] as? AROStatement)
        let expression = try #require(statement.expression)
        #expect(DataFlowAnalyzer.variables(in: expression) == ["lo", "hi"])
    }

    // MARK: - The description round-trips

    @Test("A range prints the way it was written")
    func descriptionRoundTrips() throws {
        let inclusive = try expression("(D: X) { Create the <r> with 1..10. }")
        #expect(inclusive.description == "1..10")
        let exclusive = try expression("(D: X) { Create the <r> with 1..<10. }")
        #expect(exclusive.description == "1..<10")
    }
}
