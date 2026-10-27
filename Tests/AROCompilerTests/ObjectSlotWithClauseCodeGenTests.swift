// ============================================================
// ObjectSlotWithClauseCodeGenTests.swift
// AROCompiler — `with { … }` in the object slot reaches `_with_` (GitLab #887)
// ============================================================
//
// `Start the <socket-server> with { port: 9123 }.` has nowhere to put the
// map except the object slot, so the parser produces `with the
// <_expression_>` rather than a `RangeModifiers.withClause`. The
// interpreter binds that value to BOTH `_expression_` and `_with_`
// (`FeatureSetExecutor.executeAROStatement`); the compiled path bound only
// `_expression_`.
//
// Every action that reads `_with_` therefore saw nothing once compiled.
// `ServerActions.resolvePort` consults `_with_` for a config map and
// `_expression_` only as a bare Int, so a `{ port: 9123 }` fell through to
// the 9000 default — and the server reported success on the wrong port.
//
// This asserts the IR rather than the behaviour because the behaviour needs
// a bound socket. See `ObjectSlotWithClauseTests` in the runtime suite for
// the other half: that `resolvePort` really does require `_with_` for the
// map form, so this bind is not decorative.

import Testing
@testable import AROCompiler
@testable import AROParser

#if !os(Windows)

@Suite("An object-slot `with` clause binds _with_ (#887)")
struct ObjectSlotWithClauseCodeGenTests {

    private func generateIR(_ source: String) throws -> String {
        let result = Compiler.compile(source)
        #expect(!result.hasErrors, "source should compile: \(result.diagnostics.map(\.message))")
        return try LLVMCodeGenerator().generate(program: result.analyzedProgram).irText
    }

    /// The bind is emitted as resolve(`_expression_`) → bind(`_with_`), so the
    /// marker to look for is a `_with_` string constant in a feature set whose
    /// only `with` is in the object slot.
    @Test("A config map in the object slot is bound to _with_")
    func objectSlotMapBindsWith() throws {
        let ir = try generateIR("""
        (Application-Start: T) {
            Start the <socket-server> with { port: 9123 }.
            Return an <OK: status> for the <t>.
        }
        """)

        #expect(ir.contains("_with_"),
                "the object-slot map must reach _with_, or every action reading it sees nothing")
        // `call`, not `declare` — every external appears once as a declaration
        // whether or not anything uses it.
        #expect(ir.contains("call void @aro_variable_bind_value("),
                "the value is aliased, not re-evaluated")
    }

    @Test("The alias reads the value already computed, it does not evaluate twice")
    func aliasDoesNotReEvaluate() throws {
        // Re-serialising the expression for `_with_` would run its side
        // effects a second time. The emitted shape has to be a resolve of
        // `_expression_` feeding a bind, which means exactly one
        // `aro_evaluate_expression` for the statement.
        let ir = try generateIR("""
        (Application-Start: T) {
            Start the <socket-server> with { port: 9123 }.
            Return an <OK: status> for the <t>.
        }
        """)

        let evaluations = ir.components(separatedBy: "call void @aro_evaluate_expression(").count - 1
        #expect(evaluations == 1,
                "the map must be evaluated once and aliased, saw \(evaluations) evaluations")
        #expect(ir.contains("call ptr @aro_variable_resolve("),
                "the alias resolves the value _expression_ already holds")
    }

    @Test("A statement with no object-slot `with` binds no _with_ of its own")
    func unrelatedStatementDoesNotBind() throws {
        // `from` is not `with`, so nothing here may bind `_with_` — otherwise
        // the alias would start manufacturing payloads for actions that read
        // it, which is the failure #887's second half was about.
        let ir = try generateIR("""
        (Application-Start: T) {
            Compute the <doubled> from 21 * 2.
            Return an <OK: status> for the <t>.
        }
        """)

        // `_with_` still appears as a pre-registered string constant for the
        // transient sweep, and `aro_variable_bind_value` still appears as a
        // declaration. What must not appear is a *call* to it: nothing in this
        // feature set aliases anything into `_with_`.
        #expect(!ir.contains("call void @aro_variable_bind_value("),
                "a `from` statement must not alias anything into _with_")
    }

    @Test("The sweep still clears it between statements")
    func sweepStillRuns() throws {
        // The alias is emitted after the sweep, so the modifier belongs to its
        // own statement and no other. Without this the fix would trade a
        // dropped payload for a leaked one.
        let ir = try generateIR("""
        (Application-Start: T) {
            Start the <socket-server> with { port: 9123 }.
            Create the <record> with { id: 1 }.
            Store the <record> into the <t-repository>.
            Return an <OK: status> for the <t>.
        }
        """)

        let sweeps = ir.components(separatedBy: "@aro_context_clear_transients(").count - 1
        #expect(sweeps >= 4, "expected one sweep per statement, saw \(sweeps)")
    }
}

#endif
