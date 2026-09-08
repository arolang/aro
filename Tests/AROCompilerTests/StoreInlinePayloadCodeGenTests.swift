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

    @Test("_with_ is unbound at the top of every statement")
    func withIsClearedPerStatement() throws {
        let ir = try generateIR("""
        (Application-Start: T) {
            Store the <first> into the <t-repository> with { id: 1 }.
            Create the <second> with { id: 2 }.
            Store the <second> into the <t-repository>.
            Return an <OK: status> for the <t>.
        }
        """)

        // Find the constant holding "_with_" and count how often it is
        // unbound: once per statement, so a payload can never outlive the
        // statement that wrote it.
        let withConstant = try #require(
            ir.split(separator: "\n")
                .first { $0.contains("private constant") && $0.contains("_with_") }
                .flatMap { line in line.split(separator: " ").first.map(String.init) },
            "IR should declare a string constant for _with_"
        )
        let unbinds = ir.components(separatedBy: "@aro_variable_unbind(ptr %0, ptr \(withConstant))")
            .count - 1
        #expect(unbinds >= 4, "expected one _with_ unbind per statement, saw \(unbinds)")
    }
}

#endif
