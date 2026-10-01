// ============================================================
// EmitWaitsForHandlersTests.swift
// ARO Runtime — Emit waits for its handlers (GitLab #893)
// ============================================================
//
// ARO-0088 §7 said `Emit` "does not wait for handlers" and its summary table
// answered "Does `Emit` block?" with "No". ARO-0007 §7.3 said the emitting
// feature set **waits**. The runtime implements ARO-0007 —
// `EmitAction` awaits `publishAndTrack` — and #893 resolved the contradiction
// in the runtime's favour: waiting preserves causality across an `Emit`, which
// is the guarantee the next statement is allowed to rely on.
//
// Two proposals contradicting each other is not something a reader can resolve
// — CLAUDE.md's priority order makes proposals authoritative and says nothing
// about which proposal wins. Prose alone would let it drift a third time, so
// the behaviour is pinned here.
//
// The distinction these tests keep apart, because it is the thing that made
// the two documents look reconcilable: `Emit` waits for every handler, and
// orders none of them. Waiting and ordering are different promises.

import Testing
import Foundation
@testable import ARORuntime
@testable import AROParser

@Suite("Emit waits for its handlers (#893)", .serialized)
struct EmitWaitsForHandlersTests {

    private func run(_ source: String) async throws -> String {
        let compiled = Compiler.compile(source)
        guard compiled.isSuccess else {
            throw ActionError.runtimeError(
                "test program failed to compile: \(compiled.diagnostics)")
        }
        let response = try await ExecutionEngine().execute(compiled.analyzedProgram)
        return String(describing: response)
    }

    /// A unique repository per test: the store is process-global, so two tests
    /// sharing a name would see each other's writes.
    private func token() -> String {
        "e" + String((UUID().uuidString + UUID().uuidString)
            .lowercased().filter { $0.isLetter }.prefix(10))
    }

    @Test("The statement after an Emit sees what the handler stored")
    func handlerSideEffectIsVisibleAfterEmit() async throws {
        // The causality ARO-0007 §7.3 promises: a handler's repository write
        // is visible to the statement following the Emit. If Emit did not
        // wait, this would be a race the test would fail intermittently.
        let t = token()
        let rendered = try await run("""
        (Record\(t): Ping\(t) Handler) {
            Extract the <m> from the <event: msg>.
            Store the <m> into the <seen\(t)-repository>.
            Return an <OK: status> for the <handling>.
        }
        (Application-Start: Probe) {
            Emit a <Ping\(t): event> with { msg: "landed" }.
            Retrieve the <seen> from the <seen\(t)-repository>.
            Compute the <n: length> from <seen>.
            Return an <OK: status> with <n>.
        }
        """)
        #expect(rendered.contains("1"), "handler had not finished: \(rendered)")
    }

    @Test("A slow handler still finishes before the next statement")
    func slowHandlerBlocksTheEmit() async throws {
        // Without waiting, the Retrieve would run while the handler slept and
        // find nothing. The sleep is what makes the assertion meaningful
        // rather than accidentally true.
        let t = token()
        let rendered = try await run("""
        (Slow\(t): Ping\(t) Handler) {
            Sleep the <p> for 300ms.
            Create the <m> with "late".
            Store the <m> into the <slow\(t)-repository>.
            Return an <OK: status> for the <handling>.
        }
        (Application-Start: Probe) {
            Emit a <Ping\(t): event> with { msg: "go" }.
            Retrieve the <seen> from the <slow\(t)-repository>.
            Compute the <n: length> from <seen>.
            Return an <OK: status> with <n>.
        }
        """)
        #expect(rendered.contains("1"), "Emit returned before its handler: \(rendered)")
    }

    @Test("Every matching handler has finished, not just the first")
    func allHandlersFinish() async throws {
        let t = token()
        let rendered = try await run("""
        (A\(t): Ping\(t) Handler) {
            Create the <a> with "a".
            Store the <a> into the <all\(t)-repository>.
            Return an <OK: status> for the <h>.
        }
        (B\(t): Ping\(t) Handler) {
            Sleep the <p> for 200ms.
            Create the <b> with "b".
            Store the <b> into the <all\(t)-repository>.
            Return an <OK: status> for the <h>.
        }
        (Application-Start: Probe) {
            Emit a <Ping\(t): event> with { msg: "go" }.
            Retrieve the <seen> from the <all\(t)-repository>.
            Compute the <n: length> from <seen>.
            Return an <OK: status> with <n>.
        }
        """)
        // 2, not 1: the slower handler is waited for as well as the quick one.
        #expect(rendered.contains("2"), "not every handler was awaited: \(rendered)")
    }

    @Test("EmitAction awaits the tracked publish, not the fire-and-forget one")
    func emitUsesTheAwaitedStrategy() throws {
        // The source-level half of the claim. `publish()` and
        // `publishAndTrack()` differ by exactly this guarantee, and a change
        // from one to the other would pass a casual reading of EmitAction
        // while silently removing the causality the tests above rely on.
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // AROuntimeTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // repo root
            .appendingPathComponent("Sources/ARORuntime/Actions/BuiltIn/EmitAction.swift")
        let source = try String(contentsOf: path, encoding: .utf8)
        #expect(source.contains("publishAndTrack"),
                "EmitAction no longer awaits publishAndTrack — ARO-0088 §7 and ARO-0007 §7.3 both say Emit waits")
    }
}
