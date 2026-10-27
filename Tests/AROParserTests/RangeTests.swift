// ============================================================
// RangeTests.swift
// AROParser — `1->10` (ARO-0089, GitLab #546)
// ============================================================
//
// The range operator is `->`, both ends included, and there is no
// exclusive-bound form (ARO-0089 §2.1). An arrow cannot collide with the
// character ARO spends on sentence structure, so most of what a dotted
// operator would have needed from the lexer is simply absent here — what is
// left is the diagnostic for someone who reaches for `..` anyway.
//
// Also asserted: the two shapes the language deliberately refuses — `[1->10]`
// (§5) and a range as a comparison operand (§2.2) — and that the dots a
// program legitimately contains are untouched: a double-tapped terminator
// (GitLab #372) and `import ../ModuleA`.

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

    // MARK: - Lexing

    @Test("`1->10` lexes as Int, arrow, Int")
    func rangeLexes() throws {
        #expect(try tokens("1->10").prefix(3) == [.intLiteral(1), .arrow, .intLiteral(10)])
    }

    @Test("Spaces around the arrow are allowed")
    func spacedArrowLexes() throws {
        #expect(try tokens("1 -> 10").prefix(3) == [.intLiteral(1), .arrow, .intLiteral(10)])
    }

    @Test("Subtraction is still subtraction")
    func minusIsUnaffected() throws {
        // The arrow needs the `>`; `-` alone keeps every meaning it had.
        let subtraction = try tokens("<a> - <b>")
        #expect(subtraction.contains(.minus) || subtraction.contains(.hyphen))
        #expect(!subtraction.contains(.arrow))
        // `1-5` is binary subtraction after a number (GitLab #658) and stays so.
        let unspaced = try tokens("1-5")
        #expect(unspaced.first == .intLiteral(1))
        #expect(!unspaced.contains(.arrow))
    }

    @Test("A negative upper endpoint lexes as a sign, not as subtraction")
    func negativeEndpoint() throws {
        #expect(try tokens("1->-5").prefix(3) == [.intLiteral(1), .arrow, .intLiteral(-5)])
    }

    @Test("Numeric separators work in endpoints (ARO-0082)")
    func separatorsInEndpoints() throws {
        #expect(try tokens("1_001->2_000").prefix(3)
                == [.intLiteral(1001), .arrow, .intLiteral(2000)])
    }

    @Test("A reference endpoint needs no space: `<lo>-><hi>`")
    func referenceEndpointsAreUnambiguous() throws {
        // This is the form a dotted operator could not spell without a rule
        // about which `<` belongs to what: `<lo>..<hi>` contains `..<`.
        let range = try #require(
            try expression("(D: X) { Create the <r> with <lo>-><hi>. }") as? RangeExpression)
        #expect((range.lower as? VariableRefExpression)?.noun.base == "lo")
        #expect((range.upper as? VariableRefExpression)?.noun.base == "hi")
    }

    // MARK: - The dots a program legitimately contains

    @Test("A double-tapped statement terminator is still one terminator (#372)")
    func trailingDotsAreUntouched() {
        let messages = errors(in: """
        (Application-Start: D) {
            Log "hi" to the <console>..
            Log "ho" to the <console>...
            Return an <OK: status> for the <d>.
        }
        """)
        #expect(messages.isEmpty, "unexpected errors: \(messages)")
    }

    @Test("`import ../ModuleA` is still a relative path")
    func importPathsAreUntouched() throws {
        let program = try Parser.parse("""
        import ../ModuleA
        import ../../shared/common

        (D: X) {
            Return an <OK: status> for the <x>.
        }
        """)
        #expect(program.imports.map(\.path) == ["../ModuleA", "../../shared/common"])
    }

    // MARK: - Reaching for `..` instead

    @Test("`1..10` is an error naming the arrow")
    func dottedRangeIsAnError() {
        let messages = errors(in: "(Application-Start: D) { Create the <r> with 1..10. }")
        #expect(messages.contains { $0.contains("'..' is not a range operator") })
    }

    @Test("`1..<10` is an error too — there is no exclusive form")
    func exclusiveDottedRangeIsAnError() {
        let messages = errors(in: "(Application-Start: D) { Create the <r> with 1..<10. }")
        #expect(messages.contains { $0.contains("'..<' is not a range operator") })
    }

    @Test("`1...10` lands on the same diagnostic")
    func threeDotsIsAnError() {
        let messages = errors(in: "(Application-Start: D) { Create the <r> with 1...10. }")
        #expect(messages.contains { $0.contains("is not a range operator") })
    }

    @Test("The diagnostic says there is no exclusive-bound operator")
    func dottedRangeHintNamesTheSubtraction() {
        let hints = diagnostics(for: "(Application-Start: D) { Create the <r> with 1..<10. }")
            .filter { $0.severity == .error }
            .flatMap(\.hints)
        #expect(hints.contains { $0.contains("1->10") })
        #expect(hints.contains { $0.contains("1->(<n> - 1)") })
    }

    @Test("One mistake earns one diagnostic")
    func dottedRangeDoesNotCascade() {
        // Left alone, `1..10` lexes as Int, two terminators and Int — four
        // parse errors, the last two pointing at the following statement.
        let messages = errors(in: """
        (Application-Start: D) {
            for each <n> in 1..10 {
                Log <n> to the <console>.
            }
            Return an <OK: status> for the <d>.
        }
        """)
        #expect(messages.count == 1, "expected exactly one error, got: \(messages)")
    }

    @Test("`<lo>..<hi>` is reported, not silently read as a reference range")
    func dottedReferenceRangeIsAnError() {
        let messages = errors(in: """
        (Application-Start: D) {
            Create the <lo> with 1.
            Create the <hi> with 3.
            Create the <r> with <lo>..<hi>.
            Return an <OK: status> for the <d>.
        }
        """)
        #expect(messages.contains { $0.contains("is not a range operator") })
    }

    // MARK: - §4.2 The qualifier slot excludes ranges

    @Test("`<a: 1->10>` is an error pointing at the object form")
    func rangeInQualifierSlot() {
        let messages = errors(in: """
        (Application-Start: D) {
            Create the <count> with 3.
            Compute the <a: 1->10> from <count>.
            Return an <OK: status> for the <d>.
        }
        """)
        #expect(messages.contains { $0.contains("A range cannot appear in a qualifier") })
    }

    // MARK: - §5 `[1->10]` is an error

    @Test("`[1->10]` is rejected rather than defined as sugar")
    func bracketedRangeIsAnError() {
        let messages = errors(in: """
        (Application-Start: D) {
            for each <n> in [1->10] {
                Log <n> to the <console>.
            }
            Return an <OK: status> for the <d>.
        }
        """)
        #expect(messages.contains { $0.contains("list holding one range") })
    }

    // MARK: - §2.2 Precedence and chaining

    @Test("A range binds looser than arithmetic: `1-><n> + 1` is `1->(<n> + 1)`")
    func looserThanArithmetic() throws {
        let range = try #require(
            try expression("(D: X) { Create the <r> with 1-><n> + 1. }") as? RangeExpression)
        let upper = try #require(range.upper as? BinaryExpression)
        #expect(upper.op == .add)
    }

    @Test("Ranges do not chain")
    func rangesDoNotChain() {
        let messages = errors(in: "(Application-Start: D) { Create the <r> with 1->5->10. }")
        #expect(messages.contains { $0.contains("Ranges do not chain") })
    }

    @Test("A range is not a comparison operand")
    func notAComparisonOperand() {
        let messages = errors(in: """
        (Application-Start: D) {
            Return an <OK: status> for the <d> when 1->10 == 3.
        }
        """)
        #expect(messages.contains { $0.contains("cannot be an operand of `==`") })
    }

    // MARK: - §3.1 Endpoint types

    @Test("A Float endpoint is a check-time error naming the side")
    func floatEndpointRejected() {
        let messages = errors(in: "(Application-Start: D) { Create the <r> with 1->2.5. }")
        #expect(messages.contains {
            $0.contains("must be an Int") && $0.contains("upper endpoint") && $0.contains("Float")
        })
    }

    @Test("A String endpoint is a check-time error too")
    func stringEndpointRejected() {
        let messages = errors(in: "(Application-Start: D) { Create the <r> with 1->\"ten\". }")
        #expect(messages.contains { $0.contains("must be an Int") && $0.contains("String") })
    }

    @Test("Int endpoints pass `aro check` clean")
    func intEndpointsAreClean() {
        let messages = errors(in: """
        (Application-Start: D) {
            for each <n> in 1->10 {
                Log <n> to the <console>.
            }
            Compute the <len: length> from 0->23.
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
            for each <n> in 1->10 {
                Log <n> to the <console>.
            }
        }
        """)
        let loop = try #require(program.featureSets[0].statements[0] as? ForEachLoop)
        let range = try #require(loop.collectionExpression as? RangeExpression)
        #expect((range.upper as? LiteralExpression)?.value == .integer(10))
    }

    @Test("An action argument takes a range")
    func actionArgumentSlot() throws {
        let program = try Parser.parse("(D: X) { Application.Histogram the <h> from 0->23. }")
        let statement = try #require(program.featureSets[0].statements[0] as? AROStatement)
        _ = try #require(statement.expression as? RangeExpression)
    }

    // MARK: - Data flow

    @Test("Both endpoints count as reads of their variables")
    func endpointsAreReads() throws {
        let program = try Parser.parse("(D: X) { Create the <r> with <lo>-><hi>. }")
        let statement = try #require(program.featureSets[0].statements[0] as? AROStatement)
        let expression = try #require(statement.expression)
        #expect(DataFlowAnalyzer.variables(in: expression) == ["lo", "hi"])
    }

    // MARK: - The description round-trips

    @Test("A range prints the way it was written")
    func descriptionRoundTrips() throws {
        let range = try expression("(D: X) { Create the <r> with 1->10. }")
        #expect(range.description == "1->10")
    }
}
