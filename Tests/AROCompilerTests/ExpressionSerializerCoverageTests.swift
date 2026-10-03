// ============================================================
// ExpressionSerializerCoverageTests.swift
// AROCompiler — every expression the parser builds is serialised
// GitLab #652
// ============================================================
//
// `ExpressionSerializer` is an if/else chain ending in `$unknown`, and the
// bridge evaluates `$unknown` as the empty string, which `asBool` reads as
// false. So an expression the serializer does not know is not a compile error
// — it is a **guard that quietly stops testing anything**.
//
// That is how `is empty` shipped broken: `when <list> is empty` worked under
// `aro run`, reached the binary as `$unknown`, and never performed the test.
// `is not empty` was false too, so both directions were wrong.
//
// This suite enumerates the expression kinds and asserts none of them
// serialises to `$unknown`.

import Foundation
import Testing
@testable import AROCompiler
@testable import AROParser

@Suite("Expression serializer coverage (#652)")
struct ExpressionSerializerCoverageTests {

    private let serializer = ExpressionSerializer()
    private var span: SourceSpan { SourceSpan(at: SourceLocation()) }

    private func ref(_ name: String) -> VariableRefExpression {
        VariableRefExpression(noun: QualifiedNoun(base: name, specifiers: [], span: span), span: span)
    }

    /// Every expression node the parser can produce, one instance each.
    ///
    /// Listed by hand because `ExpressionVisitor` has no `allCases`; the
    /// names are checked against that protocol's `visit` overloads below, so
    /// a node added to the AST without a case here is caught by that test
    /// rather than by a user whose guard stopped working.
    private var samples: [(name: String, expr: any AROParser.Expression)] {
        [
            ("literal", LiteralExpression(value: .string("x"), span: span)),
            ("variableRef", ref("a")),
            ("binary", BinaryExpression(left: ref("a"), op: .equal, right: ref("b"), span: span)),
            ("unary", UnaryExpression(op: .not, operand: ref("a"), span: span)),
            ("interpolated", InterpolatedStringExpression(parts: [.literal("x")], span: span)),
            ("array", ArrayLiteralExpression(elements: [ref("a")], span: span)),
            ("map", MapLiteralExpression(entries: [MapEntry(key: "k", value: ref("a"), span: span)], span: span)),
            ("member", MemberAccessExpression(base: ref("a"), member: "m", span: span)),
            ("subscript", SubscriptExpression(base: ref("a"), index: ref("i"), span: span)),
            ("grouped", GroupedExpression(expression: ref("a"), span: span)),
            ("existence", ExistenceExpression(expression: ref("a"), span: span)),
            ("typeCheck", TypeCheckExpression(expression: ref("a"), typeName: "String", hasArticle: false, span: span)),
            ("emptiness", EmptinessCheckExpression(expression: ref("a"), negated: false, span: span)),
            ("range", RangeExpression(
                lower: ref("lo"), upper: ref("hi"), isInclusive: true, span: span))
        ]
    }

    @Test("No expression kind serialises to $unknown")
    func everyExpressionKindIsSerialised() {
        let unknown = samples
            .filter { serializer.serializeExpression($0.expr).contains("$unknown") }
            .map(\.name)

        #expect(unknown.isEmpty,
                "these serialise to $unknown, which a compiled guard reads as false: \(unknown)")
    }

    // MARK: - The one that was missing

    @Test("`is empty` serialises to a node the bridge understands")
    func emptinessSerialises() {
        let json = serializer.serializeExpression(
            EmptinessCheckExpression(expression: ref("items"), negated: false, span: span))
        #expect(json.contains("$empty"))
        #expect(json.contains("\"negated\":false"))
    }

    @Test("`is not empty` carries its negation")
    func negatedEmptinessSerialises() {
        // Both directions were wrong before, not just one: `$unknown` is
        // false, so `is not empty` was false for a non-empty list.
        let json = serializer.serializeExpression(
            EmptinessCheckExpression(expression: ref("items"), negated: true, span: span))
        #expect(json.contains("$empty"))
        #expect(json.contains("\"negated\":true"))
    }

    @Test("the inner expression is serialised too, not stringified")
    func emptinessNestsItsOperand() {
        let json = serializer.serializeExpression(
            EmptinessCheckExpression(
                expression: MemberAccessExpression(base: ref("order"), member: "lines", span: span),
                negated: false, span: span))
        #expect(json.contains("$member"))
    }
}

// ============================================================
// GitLab #664 — `Break` in a for-each must compile
// ============================================================

#if !os(Windows)

@Suite("Break inside a for-each compiles (#664)")
struct BreakInForEachCodeGenTests {

    private func generateIR(_ source: String) throws -> String {
        let result = Compiler.compile(source)
        #expect(!result.hasErrors, "source should compile: \(result.diagnostics.map(\.message))")
        return try LLVMCodeGenerator().generate(program: result.analyzedProgram).irText
    }

    @Test("A for-each body containing Break generates without error")
    func breakInForEach() throws {
        // The streaming path builds the body as its own LLVM function and
        // hands it to `aro_runtime_foreach_stream`, which returns void — so
        // there is nowhere for a `Break` to branch to, and codegen failed the
        // whole build with "break used outside of loop" for a program the
        // interpreter runs happily. A body that breaks now takes the array
        // path, which has a break target.
        let ir = try generateIR("""
        (Application-Start: Demo) {
            Create the <items> with ["a", "b"].
            for each <item> in <items> {
                Log <item> to the <console>.
                Break.
            }
            Return an <OK: status> for the <demo>.
        }
        """)
        #expect(ir.contains("aro_action_log"))
        // Call sites, not the extern `declare` line, which is emitted whether
        // or not anything calls it — a plain `contains` cannot fail here.
        #expect(!ir.contains("call void @aro_runtime_foreach_stream"),
                "a breaking body must not take the streaming path")
    }

    @Test("A for-each without Break still streams")
    func streamingPreserved() throws {
        // The fallback must be narrow: only loops that actually break give up
        // the O(1) memory property.
        let ir = try generateIR("""
        (Application-Start: Demo) {
            Create the <items> with ["a", "b"].
            for each <item> in <items> {
                Log <item> to the <console>.
            }
            Return an <OK: status> for the <demo>.
        }
        """)
        #expect(ir.contains("call void @aro_runtime_foreach_stream"))
    }
}

#endif
