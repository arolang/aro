// ============================================================
// ComputeResultNameNotQualifierTests.swift
// ARORuntimeTests — a result named after a qualifier is still a name
// (GitLab #903)
// ============================================================
//
// `Compute the <difference> from <x> - <y>.` was subtraction interpreted and a
// *set operation* compiled. `resolveOperationName` falls back to the result's
// base name when no qualifier is given — the documented legacy spelling,
// `Compute the <length> from the <text>.` — and `difference` is a real
// qualifier (ARO-0042), so the compiled path ran a set difference, failed for
// want of a `with` clause, and the binary still exited `[OK]`.
//
// The interpreter never reached the action at all: `FeatureSetExecutor`'s fast
// path binds an expression and skips the action when the result carries no
// qualifier. So the two modes disagreed about what the statement meant.
//
// These pin the rule in the action, which is what makes the modes agree
// whoever dispatches: with an expression in the object slot there is nothing to
// apply an operation to, so the name is just a name. Every collision in the
// issue is covered — `difference`, `sum`, `unique`, `length`, `join`, `random`
// — because `<sum>` is the one that appears in the proposals, the README and
// `Examples/Calculator`.

import Testing
import Foundation
import AROParser
@testable import ARORuntime

@Suite("A Compute result named after a qualifier (#903)")
struct ComputeResultNameNotQualifierTests {

    /// The shape the parser produces for `Compute the <name> from <a> op <b>.`
    /// — the object noun is the expression sentinel and the value arrives in
    /// the framework variable of the same name.
    private func expressionStatement(
        resultBase: String,
        value: any Sendable
    ) -> (ResultDescriptor, ObjectDescriptor, RuntimeContext) {
        let span = SourceSpan(at: SourceLocation())
        let result = ResultDescriptor(base: resultBase, specifiers: [], span: span)
        let object = ObjectDescriptor(
            preposition: .from,
            base: FrameworkVariables.expressionValue,
            specifiers: [], span: span)
        let context = RuntimeContext(featureSetName: "Test")
        context.bind(FrameworkVariables.expressionValue, value: value)
        return (result, object, context)
    }

    // MARK: - The names that collide

    @Test("An arithmetic result keeps its value, whatever it is called",
          arguments: ["difference", "sum", "unique", "length", "join", "random",
                      "intersect", "union", "avg", "count"])
    func anArithmeticResultIsNotAnOperation(name: String) async throws {
        // 15 is what `25 - 10` evaluates to; the action must hand it back
        // rather than read `name` as the operation to perform on it.
        let (result, object, context) = expressionStatement(resultBase: name, value: 15)
        let produced = try await ComputeAction().execute(
            result: result, object: object, context: context)
        // The action answers with the value; binding the result name is the
        // executor's job, not this call's.
        #expect("\(produced)" == "15", "<\(name)> was read as an operation")
    }

    @Test("The collision that reported success while being wrong")
    func theReportedCase() async throws {
        // `difference` with no `with` clause used to throw
        // "'Compute difference' requires a 'with' clause" — on its own line,
        // after which the program carried on to exit [OK].
        let (result, object, context) = expressionStatement(
            resultBase: "difference", value: 15)
        let produced = try await ComputeAction().execute(
            result: result, object: object, context: context)
        #expect("\(produced)" == "15")
    }

    // MARK: - What must keep working

    @Test("A named object still resolves its operation from the result's name")
    func legacySpellingSurvives() async throws {
        // `Compute the <length> from the <text>.` — the documented legacy
        // form. The object is a named source, not an expression, so the
        // fallback applies and this is a length, not an identity.
        let span = SourceSpan(at: SourceLocation())
        let result = ResultDescriptor(base: "length", specifiers: [], span: span)
        let object = ObjectDescriptor(
            preposition: .from, base: "text", specifiers: [], span: span)
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("text", value: "hello")
        let produced = try await ComputeAction().execute(
            result: result, object: object, context: context)
        #expect("\(produced)" == "5")
    }

    @Test("An explicit qualifier wins over everything")
    func explicitQualifierStillWins() async throws {
        // `Compute the <only-a: difference> from <a> with <b>.` — the set
        // operation is still reachable, by asking for it.
        let span = SourceSpan(at: SourceLocation())
        let result = ResultDescriptor(
            base: "only-a", specifiers: ["difference"], span: span)
        let object = ObjectDescriptor(
            preposition: .from, base: "a", specifiers: [], span: span)
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("a", value: ["p", "q", "r"])
        context.bind("_with_", value: ["q"])
        let produced = try await ComputeAction().execute(
            result: result, object: object, context: context)
        #expect("\(produced)".contains("p"))
        #expect("\(produced)".contains("r"))
        #expect(!"\(produced)".contains("q"), "q is in both, so it is not the difference")
    }

    @Test("An explicit qualifier wins even with an expression object")
    func explicitQualifierWithAnExpressionObject() async throws {
        // The fallback is what is suppressed, not the qualifier slot:
        // `Compute the <n: uppercase> from <a> ++ <b>.` still uppercases.
        let (result0, object, context) = expressionStatement(
            resultBase: "n", value: "abc")
        _ = result0
        let span = SourceSpan(at: SourceLocation())
        let result = ResultDescriptor(
            base: "n", specifiers: ["uppercase"], span: span)
        let produced = try await ComputeAction().execute(
            result: result, object: object, context: context)
        #expect("\(produced)" == "ABC")
    }

    // MARK: - The descriptor predicate itself

    @Test("isExpressionValue is exactly the parser's expression sentinel")
    func thePredicate() {
        let span = SourceSpan(at: SourceLocation())
        let expression = ObjectDescriptor(
            preposition: .from, base: FrameworkVariables.expressionValue,
            specifiers: [], span: span)
        let named = ObjectDescriptor(
            preposition: .from, base: "text", specifiers: [], span: span)
        #expect(expression.isExpressionValue)
        #expect(!named.isExpressionValue)
        #expect(FrameworkVariables.expressionValue == "_expression_")
        #expect(FrameworkVariables.transientKeys.contains(
            FrameworkVariables.expressionValue),
            "the sentinel must stay a transient, or it leaks into the next statement")
    }
}
