// ============================================================
// CompiledWithClauseParityTests.swift
// ARO Runtime — `with <expression>` reaches actions in compiled binaries
// GitLab #882
// ============================================================
//
// `Start the <file-monitor> with "sub".` parses to a statement whose object is
// an *expression* (base `_expression_`) carried under the `with` preposition.
// The interpreter's `FeatureSetExecutor` binds that evaluated expression to
// both `_expression_` and `_with_`; the compiled bridge bound only
// `_expression_`.
//
// `StartAction.startFileMonitor` reads its directory from `_with_` and
// defaults to `"."` when it is absent, so the compiled binary watched the
// process's working directory whatever path the program named — one file event
// per build artefact under a project root, and `Examples/MultiService` pinned
// to `mode: interpreter` as a result.
//
// The assertions below are about the *bridge*, not about file watching: the
// mirror is what every `with`-payload action depends on, so pinning it here
// covers `Start`, `Store`, `Compute … with …` and the rest at once.

import Foundation
import Testing
import AROParser
@testable import ARORuntime

@Suite("Compiled `with <expression>` parity (#882)")
struct CompiledWithClauseParityTests {

    private func makeContext() -> RuntimeContext {
        RuntimeContext(
            featureSetName: "Watch Only",
            businessActivity: "Test",
            eventBus: EventBus.shared,
            isCompiled: true
        )
    }

    private func objectDescriptor(
        preposition: Preposition,
        base: String
    ) -> ObjectDescriptor {
        let location = SourceLocation(line: 0, column: 0, offset: 0)
        return ObjectDescriptor(
            preposition: preposition,
            base: base,
            specifiers: [],
            span: SourceSpan(at: location)
        )
    }

    @Test("`with <expression>` mirrors the evaluated expression into _with_")
    func expressionUnderWithReachesWith() {
        let context = makeContext()
        // What `aro_evaluate_expression` leaves behind for `with "sub"`.
        context.bind("_expression_", value: "sub")

        mirrorExpressionObjectToWith(
            objectDescriptor(preposition: .with, base: "_expression_"),
            context: context
        )

        #expect(context.resolveAny("_with_") as? String == "sub",
                "a compiled `Start the <file-monitor> with \"sub\".` must reach StartAction with _with_ == \"sub\"; otherwise it watches the working directory")
    }

    @Test("A non-`with` preposition is left alone")
    func otherPrepositionsAreNotMirrored() {
        let context = makeContext()
        context.bind("_expression_", value: "sub")

        mirrorExpressionObjectToWith(
            objectDescriptor(preposition: .from, base: "_expression_"),
            context: context
        )

        #expect(context.resolveAny("_with_") == nil,
                "`from <expression>` is not a with-payload — binding _with_ here would feed the next action a modifier the statement never wrote")
    }

    @Test("A named object under `with` is left alone")
    func namedObjectIsNotMirrored() {
        let context = makeContext()
        context.bind("_expression_", value: "sub")

        mirrorExpressionObjectToWith(
            objectDescriptor(preposition: .with, base: "contract"),
            context: context
        )

        #expect(context.resolveAny("_with_") == nil,
                "only an expression object (base `_expression_`) is mirrored, matching FeatureSetExecutor")
    }

    @Test("An explicit `with` clause wins over the mirror")
    func explicitWithClauseIsNotOverwritten() {
        let context = makeContext()
        context.bind("_with_", value: ["directory": "explicit"] as [String: any Sendable])
        context.bind("_expression_", value: "sub")

        mirrorExpressionObjectToWith(
            objectDescriptor(preposition: .with, base: "_expression_"),
            context: context
        )

        let bound = context.resolveAny("_with_") as? [String: any Sendable]
        #expect(bound?["directory"] as? String == "explicit",
                "ModifierBinder.bindRangeModifiers already bound the statement's own `with` clause; the mirror must not replace it")
    }

    @Test("Nothing is invented when no expression was evaluated")
    func noExpressionMeansNoBinding() {
        let context = makeContext()

        mirrorExpressionObjectToWith(
            objectDescriptor(preposition: .with, base: "_expression_"),
            context: context
        )

        #expect(context.resolveAny("_with_") == nil)
    }
}
