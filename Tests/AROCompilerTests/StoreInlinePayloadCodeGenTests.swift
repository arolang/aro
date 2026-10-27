// ============================================================
// StoreInlinePayloadCodeGenTests.swift
// AROCompiler — `_with_` reaches (and leaves) a compiled Store (GitLab #515)
// ============================================================
//
// `aro run` and `aro build` have to agree about Store's inline payload,
// and the compiled path had two halves of the problem. The payload does
// reach the action — `bindRangeModifiers` emits `_with_` — but nothing
// ever cleared it again: the per-statement transient list held only the
// query modifiers, so a `with` clause stayed bound for every statement
// after it. Harmless while nobody read `_with_` to decide anything; once
// Store uses its presence to mean "the payload is the value", a leftover
// binding makes the next plain `Store the <x> into the <repo>.` store
// the previous statement's payload.

import Testing
@testable import AROCompiler
@testable import AROParser

#if !os(Windows)

@Suite("Store's inline payload in compiled code (#515)")
struct StoreInlinePayloadCodeGenTests {

    private func generateIR(_ source: String) throws -> String {
        let result = Compiler.compile(source)
        #expect(!result.hasErrors, "source should compile: \(result.diagnostics.map(\.message))")
        return try LLVMCodeGenerator().generate(program: result.analyzedProgram).irText
    }

    @Test("The payload is evaluated into _with_ before the store call")
    func payloadIsBoundBeforeStore() throws {
        let ir = try generateIR("""
        (Application-Start: T) {
            Store the <ticket> into the <ticket-repository> with { id: 1, state: "new" }.
            Return an <OK: status> for the <t>.
        }
        """)

        // The `_with_` string constant, the bind, and the store all present.
        #expect(ir.contains("_with_"))
        #expect(ir.contains("aro_evaluate_and_bind"))
        #expect(ir.contains("aro_action_store"))

        // The payload literal is serialized into the IR, not looked up.
        #expect(ir.contains("$lit"))
    }

    @Test("The per-statement sweep runs at the top of every statement")
    func withIsClearedPerStatement() throws {
        let ir = try generateIR("""
        (Application-Start: T) {
            Store the <first> into the <t-repository> with { id: 1 }.
            Create the <second> with { id: 2 }.
            Store the <second> into the <t-repository>.
            Return an <OK: status> for the <t>.
        }
        """)

        // `_with_` is cleared by `aro_context_clear_transients`, which sweeps
        // `FrameworkVariables.transientKeys` on the runtime side. It used to
        // be 21 `aro_variable_unbind` calls per statement, which is what this
        // test counted and what #714 removed; the invariant it was protecting
        // — a payload never outlives the statement that wrote it — is now one
        // call per statement instead of one per name.
        let sweeps = ir.components(separatedBy: "@aro_context_clear_transients(").count - 1
        #expect(sweeps >= 4, "expected one sweep per statement, saw \(sweeps)")
    }
}

#endif
