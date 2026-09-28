// ============================================================
// ConcurrencySafetyTests.swift
// ARORuntimeTests — shutdown races and shared mutable state
// GitLab #631, #645
// ============================================================
//
// Two pieces of shared state that were written without synchronisation. The
// tests here cannot *prove* the absence of a data race — that wants a thread
// sanitiser, not an assertion — so what they pin is the observable contract
// each fix establishes: a shutdown signalled before anyone waited is not
// lost, signalling twice does not trap, and the body limit survives being
// hammered from several tasks at once.

import Testing
import Foundation
@testable import ARORuntime

@Suite("Concurrency safety (GitLab #631, #645)")
struct ConcurrencySafetyTests {

    // MARK: - #631, the shutdown handshake

    @Test("A shutdown signalled before anyone waits is not lost")
    func shutdownBeforeWaitDoesNotHang() async throws {
        // The lost wake-up: `signalShutdown()` ran before `waitForShutdown()`
        // had stored its continuation, saw nil, resumed nobody — and the
        // continuation stored a moment later was never resumed by anything.
        // The process then hung on exactly the signal meant to end it, which
        // the signal path makes likely because a signal arrives at a moment
        // nobody chose.
        let context = RuntimeContext(featureSetName: "Test")
        context.signalShutdown()

        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                try await context.waitForShutdown()
                return true
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                return false
            }
            let finishedPromptly = try await group.next()
            group.cancelAll()
            #expect(finishedPromptly == true)
        }
    }

    @Test("Signalling twice does not resume a continuation twice")
    func doubleSignalDoesNotTrap() async throws {
        // Resuming a `CheckedContinuation` twice traps the process, and
        // `Keepalive`, `Stop` and the signal handler can all call this.
        let context = RuntimeContext(featureSetName: "Test")

        async let waited: Void = context.waitForShutdown()
        try await Task.sleep(nanoseconds: 50_000_000)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { context.signalShutdown() }
            }
        }
        try await waited
    }

    @Test("isWaiting is readable while another thread signals")
    func isWaitingIsSynchronised() async {
        let context = RuntimeContext(featureSetName: "Test")
        context.enterWaitState()

        await withTaskGroup(of: Void.self) { group in
            group.addTask { for _ in 0..<500 { _ = context.isWaiting } }
            group.addTask { for _ in 0..<500 { context.signalShutdown() } }
        }
        #expect(context.isWaiting == false)
    }

    // MARK: - #645, the process-wide body limit

    @Test("The body limit round-trips and survives concurrent access")
    func maxBodyIsSynchronised() async {
        // `Configure the <http-server: max-body>` writes this from a feature
        // set while the NIO event loops read it per request — an
        // unsynchronised write racing concurrent reads, which is undefined
        // behaviour rather than a merely stale number.
        let original = RuntimeDefaults.maxMaterializedBody
        defer { RuntimeDefaults.maxMaterializedBody = original }

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for _ in 0..<500 { RuntimeDefaults.maxMaterializedBody = 2_000_000 }
            }
            group.addTask {
                for _ in 0..<500 { _ = RuntimeDefaults.maxMaterializedBody }
            }
        }

        RuntimeDefaults.maxMaterializedBody = 512_000
        #expect(RuntimeDefaults.maxMaterializedBody == 512_000)
    }
}
