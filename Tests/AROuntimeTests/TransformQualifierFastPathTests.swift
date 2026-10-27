// ============================================================
// TransformQualifierFastPathTests.swift
// ARO Runtime — a qualified Transform runs its action
// GitLab #643 (the check it restores), #501 (the same shape, one verb along)
// ============================================================
//
// `Transform the <price: float> from <text>.` takes its object as an
// expression, and the executor's fast path binds an expression's value
// directly instead of calling the action. For most verbs that is exactly
// right. For a *qualified* Transform it is never right, because the qualifier
// IS the conversion: skipping the action keeps the source type and still
// answers OK.
//
//     Create the <price-text> with "4.60".
//     Transform the <price-value: float> from <price-text>.
//     Compute the <total> from <price-value> + 0.4.
//
// `<price-value>` stayed the string "4.60", so the third line failed with
// "'+' adds numbers; use '++' to join text" — a type error reported two
// statements away from its cause, on a line that was correct.
//
// #643 had already decided an unknown format is an error rather than the
// identity, but that check lives inside the action, which this path never
// reached. So the typo it was written to catch was silent again.

import Foundation
import Testing
@testable import ARORuntime
@testable import AROParser

@Suite("A qualified Transform runs its action")
struct TransformQualifierFastPathTests {

    private func run(_ source: String) async throws -> String {
        let compiled = Compiler.compile(source)
        guard compiled.isSuccess else {
            throw ActionError.runtimeError(
                "test program failed to compile: \(compiled.diagnostics)")
        }
        let response = try await ExecutionEngine().execute(compiled.analyzedProgram)
        return String(describing: response)
    }

    @Test("A float transform binds a number, not the source string")
    func floatTransformConverts() async throws {
        // The repro from Learning notebook 03. 4.60 + 0.4 is 5.
        let rendered = try await run("""
        (Application-Start: Probe) {
            Create the <price-text> with "4.60".
            Transform the <price-value: float> from <price-text>.
            Compute the <total> from <price-value> + 0.4.
            Return an <OK: status> with <total>.
        }
        """)
        #expect(rendered.contains("5"), "unexpected result: \(rendered)")
    }

    @Test("An int transform converts too")
    func intTransformConverts() async throws {
        let rendered = try await run("""
        (Application-Start: Probe) {
            Create the <count-text> with "41".
            Transform the <count: int> from <count-text>.
            Compute the <total> from <count> + 1.
            Return an <OK: status> with <total>.
        }
        """)
        #expect(rendered.contains("42"), "unexpected result: \(rendered)")
    }

    @Test("An unknown format is an error, not the identity (#643)")
    func unknownFormatIsAnError() async throws {
        // The action has always said so; the fast path meant nobody heard it.
        await #expect(throws: (any Error).self) {
            _ = try await run("""
            (Application-Start: Probe) {
                Create the <a> with "4.60".
                Transform the <b: jsn> from <a>.
                Return an <OK: status> with <b>.
            }
            """)
        }
    }

    @Test("An unqualified Transform still takes the fast path")
    func unqualifiedTransformIsUnchanged() async throws {
        // No qualifier means identity, so binding the expression's value is
        // the right answer and stays the right answer.
        let rendered = try await run("""
        (Application-Start: Probe) {
            Create the <original> with "unchanged".
            Transform the <copy> from <original>.
            Return an <OK: status> with <copy>.
        }
        """)
        #expect(rendered.contains("unchanged"), "unexpected result: \(rendered)")
    }
}
