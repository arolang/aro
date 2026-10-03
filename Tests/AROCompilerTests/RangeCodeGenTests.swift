// ============================================================
// RangeCodeGenTests.swift
// AROCompiler — ranges reach the binary (ARO-0089, GitLab #546)
// ============================================================
//
// A range is serialised for the runtime bridge, so the thing that can go
// wrong is the thing that went wrong for `is empty` (GitLab #652): a node the
// serializer does not know becomes `$unknown`, which the bridge evaluates as
// the empty string. A for-each over `$unknown` iterates nothing, silently.
//
// The second assertion is the one that keeps the two execution modes
// agreeing. `lazy` is the compiler's decision about *where* a range stays a
// span instead of becoming its elements, and the answer has to be "the
// for-each collection slot, and nowhere else" — because that is the rule the
// interpreter follows in `FeatureSetExecutor`. If this test starts failing,
// `aro run` and `aro build` have begun to disagree.

#if !os(Windows)

import Foundation
import Testing
@testable import AROCompiler
@testable import AROParser

@Suite("Ranges in compiled code (ARO-0089, #546)")
struct RangeCodeGenTests {

    private let serializer = ExpressionSerializer()
    private var span: SourceSpan { SourceSpan(at: SourceLocation()) }

    private func generateIR(_ source: String) throws -> String {
        let result = Compiler.compile(source)
        #expect(!result.hasErrors, "source should compile: \(result.diagnostics.map(\.message))")
        return try LLVMCodeGenerator().generate(program: result.analyzedProgram).irText
    }

    @Test("A range serialises to $range, not $unknown")
    func rangeSerialises() {
        let json = serializer.serializeExpression(
            RangeExpression(
                lower: LiteralExpression(value: .integer(1), span: span),
                upper: LiteralExpression(value: .integer(10), span: span),
                isInclusive: true, span: span))
        #expect(json.contains("$range"))
        #expect(json.contains("\"inclusive\":true"))
        #expect(!json.contains("$unknown"))
    }

    @Test("`..<` carries its exclusive bound")
    func exclusiveSerialises() {
        let json = serializer.serializeExpression(
            RangeExpression(
                lower: LiteralExpression(value: .integer(0), span: span),
                upper: LiteralExpression(value: .integer(24), span: span),
                isInclusive: false, span: span))
        #expect(json.contains("\"inclusive\":false"))
    }

    @Test("Endpoints are serialised as expressions, not stringified")
    func endpointsNest() {
        let json = serializer.serializeExpression(
            RangeExpression(
                lower: VariableRefExpression(
                    noun: QualifiedNoun(base: "lo", specifiers: [], span: span), span: span),
                upper: VariableRefExpression(
                    noun: QualifiedNoun(base: "hi", specifiers: [], span: span), span: span),
                isInclusive: true, span: span))
        #expect(json.contains("{\"$var\":\"lo\"}"))
        #expect(json.contains("{\"$var\":\"hi\"}"))
    }

    @Test("Only the for-each collection slot asks for the lazy form")
    func onlyForEachIsLazy() throws {
        let ir = try generateIR("""
        (Application-Start: Demo) {
            for each <n> in 1..10 {
                Log <n> to the <console>.
            }
            Compute the <len: length> from 1..10.
            Log <len> to the <console>.
            Return an <OK: status> for the <demo>.
        }
        """)
        #expect(ir.contains("\\22lazy\\22:true") || ir.contains("\"lazy\":true"),
                "the loop's collection must be bound as a span")
        #expect(ir.contains("\\22lazy\\22:false") || ir.contains("\"lazy\":false"),
                "a range anywhere else must be bound as its elements")
    }

    @Test("A range in the collection slot does not become a literal array")
    func rangeIsNotConstantFolded() {
        // Folding `1..10` into `[1,…,10]` at compile time would be correct and
        // would also destroy the O(1) memory property for `1..10_000_000`, so
        // `ConstantFolder` deliberately does not know ranges.
        let range = RangeExpression(
            lower: LiteralExpression(value: .integer(1), span: span),
            upper: LiteralExpression(value: .integer(10), span: span),
            isInclusive: true, span: span)
        #expect(!ConstantFolder.isConstant(range))
    }
}

#endif
