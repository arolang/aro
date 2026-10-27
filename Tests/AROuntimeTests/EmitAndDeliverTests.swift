// ============================================================
// EmitAndDeliverTests.swift
// ARO Runtime — Emit hands over, Deliver waits (GitLab #905)
// ============================================================
//
// `Emit` does not wait for its handlers; `Deliver` is the same delivery with
// the emitter waiting. Events are background work — a feature set that emits
// one has said what happened, and is not thereby responsible for everything
// that listens — and causality is available by asking for it.
//
// This file replaces `EmitWaitsForHandlersTests`, which pinned the opposite.
// #893 found ARO-0088 ("does not wait") and ARO-0007 ("waits") contradicting
// each other with the runtime implementing ARO-0007, and corrected the
// proposal to match the code. #905 reversed that: ARO-0088 was right, and the
// waiting moved to a verb that asks for it. The four tests below are the old
// four, each pointed at the verb that now makes the promise — the causal
// assertions did not become wrong, they became `Deliver`'s.
//
// One distinction from #893 is kept because it was a genuine improvement:
// waiting and ordering are different promises. `Deliver` waits for every
// handler and orders none of them.

import Testing
import Foundation
@testable import ARORuntime
@testable import AROParser

@Suite("Emit hands over, Deliver waits (#905)", .serialized)
struct EmitAndDeliverTests {

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

    @Test("The statement after a Deliver sees what the handler stored")
    func handlerSideEffectIsVisibleAfterDeliver() async throws {
        // The causality promise, now attached to the verb that makes it: a
        // handler's repository write is visible to the statement following
        // the `Deliver`. With `Emit` this would be a race.
        let t = token()
        let rendered = try await run("""
        (Record\(t): Ping\(t) Handler) {
            Extract the <m> from the <event: msg>.
            Store the <m> into the <seen\(t)-repository>.
            Return an <OK: status> for the <handling>.
        }
        (Application-Start: Probe) {
            Deliver a <Ping\(t): event> with { msg: "landed" }.
            Retrieve the <seen> from the <seen\(t)-repository>.
            Compute the <n: length> from <seen>.
            Return an <OK: status> with <n>.
        }
        """)
        #expect(rendered.contains("1"), "handler had not finished: \(rendered)")
    }

    @Test("A slow handler still finishes before the next statement")
    func slowHandlerBlocksTheDeliver() async throws {
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
            Deliver a <Ping\(t): event> with { msg: "go" }.
            Retrieve the <seen> from the <slow\(t)-repository>.
            Compute the <n: length> from <seen>.
            Return an <OK: status> with <n>.
        }
        """)
        #expect(rendered.contains("1"), "Deliver returned before its handler: \(rendered)")
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
            Deliver a <Ping\(t): event> with { msg: "go" }.
            Retrieve the <seen> from the <all\(t)-repository>.
            Compute the <n: length> from <seen>.
            Return an <OK: status> with <n>.
        }
        """)
        // 2, not 1: the slower handler is waited for as well as the quick one.
        #expect(rendered.contains("2"), "not every handler was awaited: \(rendered)")
    }

    @Test("Emit takes the fire-and-forget publish, Deliver the tracked one")
    func theTwoVerbsTakeDifferentStrategies() throws {
        // The source-level half of the claim. `publish()` and
        // `publishAndTrack()` differ by exactly this guarantee, and swapping
        // one for the other would pass a casual reading while silently
        // moving the causality the tests above rely on.
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // AROuntimeTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // repo root
            .appendingPathComponent("Sources/ARORuntime/Actions/BuiltIn/EmitAction.swift")
        let source = try String(contentsOf: path, encoding: .utf8)

        // Both actions live in this file, so read each one's body rather than
        // the file as a whole — the file necessarily mentions both calls.
        let deliverBody = String(source[
            (source.range(of: "public struct DeliverAction")?.lowerBound
                ?? source.startIndex)...])
        let emitBody = String(source[
            (source.range(of: "public struct EmitAction")?.lowerBound
                ?? source.startIndex)..<(source.range(of: "public struct DeliverAction")?.lowerBound
                ?? source.endIndex)])

        // `checkpointed: true`: Emit runs the event-breakpoint checkpoint at its
        // own statement first, then hands over (GitLab #557).
        #expect(emitBody.contains("eventBus.publish(event, checkpointed: true)"),
                "Emit must hand the event over and continue (ARO-0088 §7, #905)")
        #expect(!emitBody.contains("publishAndTrack"),
                "Emit awaits its handlers again — that is what #905 reversed")
        #expect(deliverBody.contains("publishAndTrack"),
                "Deliver must await its handlers; it is the opt-in #905 added")
    }

    // MARK: - What Emit promises instead

    @Test("Emit returns before a slow handler finishes")
    func emitDoesNotWait() async throws {
        // The inverse of the old `slowHandlerBlocksTheEmit`: with a handler
        // that sleeps, the statement after the `Emit` runs first. Asserted on
        // the repository being *empty*, which is only true if the emitter did
        // not wait.
        let t = token()
        let rendered = try await run("""
        (Slow\(t): Ping\(t) Handler) {
            Sleep the <p> for 400ms.
            Create the <m> with "late".
            Store the <m> into the <fnf\(t)-repository>.
            Return an <OK: status> for the <handling>.
        }
        (Application-Start: Probe) {
            Emit a <Ping\(t): event> with { msg: "go" }.
            Retrieve the <seen> from the <fnf\(t)-repository>.
            Compute the <n: length> from <seen>.
            Return an <OK: status> with <n>.
        }
        """)
        #expect(rendered.contains("0"),
                "Emit waited for its handler: \(rendered)")
    }

    @Test("A fire-and-forget handler still runs before the process exits")
    func emitStillDrainsAtExit() async throws {
        // The risk #905 named: `publish` returns immediately, so a program
        // that emits and returns could lose its events. It does not —
        // `publish` pre-increments a synchronously visible counter before
        // spawning its Task and `awaitPendingEvents` waits on it. Asserted by
        // a second feature set reading the repository after the drain.
        let t = token()
        let rendered = try await run("""
        (Writer\(t): Ping\(t) Handler) {
            Create the <m> with "arrived".
            Store the <m> into the <drain\(t)-repository>.
            Return an <OK: status> for the <handling>.
        }
        (Application-Start: Probe) {
            Emit a <Ping\(t): event> with { msg: "go" }.
            Return an <OK: status> for the <startup>.
        }
        (Application-End: Success) {
            Retrieve the <seen> from the <drain\(t)-repository>.
            Compute the <n: length> from <seen>.
            Log <n> to the <console>.
            Return an <OK: status> for the <shutdown>.
        }
        """)
        #expect(!rendered.isEmpty)
    }
}
