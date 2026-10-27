// ============================================================
// GuardsAndStrictnessTests.swift
// ARO Runtime — one truthiness rule, and names that must exist
// GitLab #640, #643, #644, #648
// ============================================================
//
// Four bugs with one shape: a name or a value the runtime could not make
// sense of, answered with a plausible default instead of a complaint. An
// unknown validation rule passed. An unknown transform returned its input. A
// guard that could not be evaluated skipped its handler. A record compared
// equal because two dictionaries happened to print alike.

import Testing
import Foundation
@testable import ARORuntime
@testable import AROParser

@Suite("Guards and strictness (#640, #643, #644, #648)")
struct GuardsAndStrictnessTests {

    // MARK: - #644, one truthiness rule

    @Test("Only a Bool, or an Int carrying one, is true")
    func strictTruthiness() {
        // ARO-0002: "Guard Evaluation: Conditions must be boolean
        // expressions". There were five competing rules in the runtime, so the
        // same condition could be true in a statement guard and false in a
        // handler guard.
        #expect(FeatureSetExecutor.strictBool(true) == true)
        #expect(FeatureSetExecutor.strictBool(false) == false)

        // Int survives because 0/1 is how a compiled binary carries a boolean
        // across the C ABI; dropping it would break the two modes apart rather
        // than align them.
        #expect(FeatureSetExecutor.strictBool(1) == true)
        #expect(FeatureSetExecutor.strictBool(0) == false)

        // Everything else is "not a condition", not "true".
        #expect(FeatureSetExecutor.strictBool("yes") == nil)
        #expect(FeatureSetExecutor.strictBool("") == nil)
        #expect(FeatureSetExecutor.strictBool([1, 2] as [any Sendable]) == nil)
        #expect(FeatureSetExecutor.strictBool([String: any Sendable]()) == nil)
    }

    @Test("'and' and 'not' need conditions, and the error names which side")
    func logicalOperatorsNeedConditions() async throws {
        // The evaluator had its own copy of the loose rule, so
        // `when <user> and <admin>` was true for two records whatever they
        // contained, and `not <name>` was false for every name.
        let span = SourceSpan(at: SourceLocation())
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("user", value: ["id": 1] as [String: any Sendable])
        context.bind("admin", value: ["id": 2] as [String: any Sendable])

        let ref = { (n: String) in
            VariableRefExpression(noun: QualifiedNoun(base: n, span: span), span: span)
        }
        let conjunction = BinaryExpression(
            left: ref("user"), op: .and, right: ref("admin"), span: span)

        do {
            _ = try await ExpressionEvaluator().evaluate(conjunction, context: context)
            Issue.record("'and' on two records should not succeed")
        } catch {
            #expect("\(error)".contains("'and'"))
        }

        let negation = UnaryExpression(op: .not, operand: ref("user"), span: span)
        do {
            _ = try await ExpressionEvaluator().evaluate(negation, context: context)
            Issue.record("'not' on a record should not succeed")
        } catch {
            #expect("\(error)".contains("'not'"))
        }
    }

    @Test("A boolean condition still works on both sides")
    func logicalOperatorsAcceptBooleans() async throws {
        let span = SourceSpan(at: SourceLocation())
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("paid", value: true)
        // 0/1 is how a compiled binary carries a boolean across the C ABI.
        context.bind("shipped", value: 0)

        let ref = { (n: String) in
            VariableRefExpression(noun: QualifiedNoun(base: n, span: span), span: span)
        }
        let conjunction = BinaryExpression(
            left: ref("paid"), op: .and, right: ref("shipped"), span: span)
        let value = try await ExpressionEvaluator().evaluate(conjunction, context: context)
        #expect(value as? Bool == false)
    }

    // MARK: - #640, structural equality

    @Test("Records compare by structure, not by how they print")
    func recordsCompareStructurally() {
        // Swift's Dictionary description has no defined order, so comparing
        // `String(describing:)` matched or failed from run to run.
        let a: any Sendable = ["a": 1, "b": 2] as [String: any Sendable]
        let b: any Sendable = ["b": 2, "a": 1] as [String: any Sendable]
        #expect(AROValueEquality.equal(a, b))

        let c: any Sendable = ["a": 1, "b": 3] as [String: any Sendable]
        #expect(!AROValueEquality.equal(a, c))
    }

    @Test("A number is a number, whichever way it arrived")
    func numbersCompareAcrossTypes() {
        // `[1, 2]` never matched `[1.0, 2.0]`. Which of the two a value is
        // depends on whether it came from a literal, JSON, a CSV column or
        // arithmetic — none of which the author chose.
        #expect(AROValueEquality.equal([1, 2] as [any Sendable],
                                       [1.0, 2.0] as [any Sendable]))
        #expect(AROValueEquality.equal(3 as any Sendable, 3.0 as any Sendable))
    }

    @Test("true is not 1")
    func boolIsNotANumber() {
        // Checked before the numeric branch on purpose: a flag and a count are
        // different things, and conflating them is how a guard starts passing
        // for the wrong reason.
        #expect(!AROValueEquality.equal(true as any Sendable, 1 as any Sendable))
    }

    @Test("An unrecognised type is not equal, rather than equal-if-it-prints-alike")
    func unknownTypesAreNotEqual() {
        struct Opaque: Sendable {}
        #expect(!AROValueEquality.equal(Opaque(), Opaque()))
    }

    // MARK: - #643, a name that does not exist is not a default

    private func descriptors(
        resultBase: String,
        resultSpecifiers: [String],
        objectBase: String,
        preposition: Preposition
    ) -> (ResultDescriptor, ObjectDescriptor) {
        let span = SourceSpan(at: SourceLocation())
        return (
            ResultDescriptor(base: resultBase, specifiers: resultSpecifiers, span: span),
            ObjectDescriptor(preposition: preposition, base: objectBase, specifiers: [], span: span)
        )
    }

    @Test("An unknown validation rule fails the statement instead of passing")
    func unknownValidationRuleThrows() async throws {
        // `Validate the <ok: emial> for the <address>.` used to report success
        // for every input, which reads in the source as though the address had
        // been checked.
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("address", value: "not-an-email")
        let (result, object) = descriptors(
            resultBase: "ok", resultSpecifiers: ["emial"],
            objectBase: "address", preposition: .for)

        await #expect(throws: (any Error).self) {
            _ = try await ValidateAction().execute(result: result, object: object, context: context)
        }
    }

    @Test("A real validation rule still validates")
    func knownValidationRuleStillWorks() async throws {
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("address", value: "not-an-email")
        let (result, object) = descriptors(
            resultBase: "ok", resultSpecifiers: ["email"],
            objectBase: "address", preposition: .for)

        let value = try await ValidateAction().execute(result: result, object: object, context: context)
        #expect((value as? ValidationResult)?.isValid == false)
    }

    @Test("An unknown Transform format fails instead of returning its input")
    func unknownTransformFormatThrows() async throws {
        // The identity fallback made `<x: jsn>` a silent no-op, and the
        // untransformed value travelled on as though it had been converted.
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("payload", value: ["a": 1] as [String: any Sendable])
        let (result, object) = descriptors(
            resultBase: "encoded", resultSpecifiers: ["jsn"],
            objectBase: "payload", preposition: .from)

        await #expect(throws: (any Error).self) {
            _ = try await TransformAction().execute(result: result, object: object, context: context)
        }
    }

    // MARK: - #648, Log's qualifier namespace is the closed one

    @Test("An unknown Log qualifier fails instead of logging the untransformed value")
    func unknownLogQualifierThrows() async throws {
        // It used to write `[LogAction] Warning: …` to stderr and print the
        // value unchanged — the same typo that is a check-time error in
        // `Compute` was a line a program's output never shows.
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("numbers", value: [3, 1, 2] as [any Sendable])
        let (result, object) = descriptors(
            resultBase: "numbers", resultSpecifiers: ["revrese"],
            objectBase: "console", preposition: .to)

        await #expect(throws: (any Error).self) {
            _ = try await LogAction().execute(result: result, object: object, context: context)
        }
    }

    // MARK: - #851, `+` on text names the operator that joins it

    @Test("'+' on a string names '++'")
    func plusOnTextNamesConcatenation() async throws {
        let span = SourceSpan(at: SourceLocation())
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("greeting", value: "Hello, ")
        context.bind("name", value: "Ada")
        let expr = BinaryExpression(
            left: VariableRefExpression(noun: QualifiedNoun(base: "greeting", span: span), span: span),
            op: .add,
            right: VariableRefExpression(noun: QualifiedNoun(base: "name", span: span), span: span),
            span: span)

        // "Cannot convert String to number" described the machine's
        // difficulty; the author had used the operator every other language
        // spells this way.
        do {
            _ = try await ExpressionEvaluator().evaluate(expr, context: context)
            Issue.record("'+' on two strings should not succeed")
        } catch {
            #expect("\(error)".contains("++"))
        }
    }
}
