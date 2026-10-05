// ============================================================
// CooperativePoolForceTests.swift
// ARO Runtime - Reads of deferred results must not park the pool (GitLab #707)
// ============================================================
//
// `AROFuture.force()` waits on a `DispatchGroup`, which parks the calling
// pthread. Every statement of the interpreter runs on Swift's cooperative pool,
// whose thread count is the core count — so a read of a still-pending deferred
// result parked one of those threads for the whole of the deferred action's
// work. With as many concurrent reads as cores the pool had no thread left for
// the work that would resolve those futures, and the process stopped: a
// handler-level deadlock, not a slowdown. Measured on an 18-core machine, 24
// concurrent HTTP requests to a handler reading a deferred `Request` answered
// 2 of 24 and timed the rest out at 60 s.
//
// The reads under test therefore wait for deferred work that itself needs the
// cooperative pool. That is deliberate, and it is what gives these tests teeth:
// run against the blocking read they do not fail, they *wedge* — which is why
// the deadline below is a `DispatchSemaphore` and not `Task.sleep`.

import Testing
import Foundation
@testable import ARORuntime

@Suite("Reads of deferred results do not park the cooperative pool (GitLab #707)")
struct CooperativePoolForceTests {

    /// Deferred work that can only finish on the cooperative pool.
    ///
    /// An `AROFuture` body runs on `ActionTaskExecutor` (GCD, elastic), and
    /// `Task {}` would inherit that preference — so the hop has to be
    /// `Task.detached`, which does not, and therefore resumes on the cooperative
    /// pool. That is the shape of the real case: a deferred `Request` whose
    /// continuation needs a cooperative thread. If the reader has parked every
    /// such thread, this can never complete.
    private func futureNeedingTheCooperativePool(_ name: String) -> AROFuture {
        AROFuture(bindingName: name) {
            await Task.detached { () -> Int in
                try? await Task.sleep(nanoseconds: 5_000_000)
                return 42
            }.value
        }
    }

    /// Whether `body` finishes inside the deadline.
    ///
    /// The deadline must not itself need the cooperative pool: a `Task.sleep`
    /// timeout cannot fire while every pool thread is parked, which is precisely
    /// the condition under test — so a regression would hang the suite rather
    /// than fail it (confirmed: the first draft of this file, run against the
    /// blocking read, never returned). A semaphore reports `.timedOut` whatever
    /// the pool is doing.
    ///
    /// Nor may the *test* park a pool thread waiting on it. Swift Testing runs
    /// tests on the cooperative pool, so a synchronous `wait` here took a thread
    /// away from the very work being timed. On a 4-core GitHub runner these two
    /// tests and the rest of the parallel suite left none, both hit the 30 s
    /// deadline, and every timing-sensitive test in the process failed with them
    /// — while GitLab's wider runner never noticed. The wait therefore runs on a
    /// GCD thread and the test suspends.
    ///
    /// Suspending reintroduces one hazard: if the pool really is wedged, the
    /// test cannot resume to report `false`. A watchdog covers that — no
    /// acknowledgement shortly after a timeout means the pool is gone, and the
    /// process stops with the reason rather than hanging.
    private func finishesWithin(
        seconds: Double,
        _ body: @escaping @Sendable () async -> Void
    ) async -> Bool {
        let done = DispatchSemaphore(value: 0)
        let resumed = DispatchSemaphore(value: 0)
        Task.detached {
            await body()
            done.signal()
        }
        let finished = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global().async {
                let finished = done.wait(timeout: .now() + seconds) == .success
                continuation.resume(returning: finished)
                if !finished, resumed.wait(timeout: .now() + 10) == .timedOut {
                    fatalError("The cooperative pool is wedged: a test could not resume 10s after its deadline (GitLab #707)")
                }
            }
        }
        resumed.signal()
        return finished
    }

    /// Somewhere for a detached body to put its answer. `#expect` inside a
    /// detached task is not attributed to the test, so results come back here
    /// and are asserted on the test's own task.
    private final class Outcome: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int?] = []
        func record(_ value: Int?) { lock.withLock { values.append(value) } }
        var all: [Int?] { lock.withLock { values } }
    }

    @Test("More concurrent reads than cores still finish")
    func concurrentReadsDoNotExhaustThePool() async {
        // Four times the pool width. Under a blocking force this cannot drain:
        // every parked thread waits for work that needs a thread.
        let readers = ProcessInfo.processInfo.activeProcessorCount * 4
        let outcome = Outcome()

        let finished = await finishesWithin(seconds: 30) {
            await withTaskGroup(of: Int?.self) { group in
                for i in 0..<readers {
                    group.addTask {
                        let ctx = RuntimeContext(featureSetName: "Reader-\(i)")
                        ctx.bind("value", value: self.futureNeedingTheCooperativePool("value"))
                        return await ctx.resolveAnyAwaitingDeferred("value") as? Int
                    }
                }
                for await value in group { outcome.record(value) }
            }
        }

        #expect(
            finished,
            "\(readers) concurrent reads of a deferred result did not finish in 30s — the cooperative pool is being parked again (GitLab #707)"
        )
        if finished {
            #expect(outcome.all.count == readers)
            #expect(outcome.all.allSatisfy { $0 == 42 })
        }
    }

    @Test("Feature-set exit drains the same way")
    func concurrentDrainsDoNotExhaustThePool() async {
        // The same hazard at the other end: exit drains what nobody read, so a
        // loaded server reaches it from many handlers at once.
        let drainers = ProcessInfo.processInfo.activeProcessorCount * 4
        let outcome = Outcome()

        let finished = await finishesWithin(seconds: 30) {
            await withTaskGroup(of: Void.self) { group in
                for i in 0..<drainers {
                    group.addTask {
                        let ctx = RuntimeContext(featureSetName: "Drainer-\(i)")
                        let future = self.futureNeedingTheCooperativePool("unread")
                        ctx.registerPendingFuture(future)
                        ctx.bindDeferredPlaceholder("unread", future: future)
                        // Nobody reads it: the drain is what has to finish the work.
                        let error = await ctx.drainPendingFuturesAwaiting()
                        outcome.record(error == nil ? 1 : 0)
                    }
                }
                await group.waitForAll()
            }
        }

        #expect(
            finished,
            "\(drainers) concurrent exit drains did not finish in 30s — the cooperative pool is being parked again (GitLab #707)"
        )
        if finished {
            #expect(outcome.all.count == drainers)
            #expect(outcome.all.allSatisfy { $0 == 1 }, "a drain reported an error")
        }
    }

    @Test("The awaiting read answers what the blocking read answers")
    func awaitingReadMatchesBlockingRead() async {
        let ctx = RuntimeContext(featureSetName: "Parity")
        ctx.bind("eager", value: AROFuture(resolved: "hello" as String, bindingName: "eager"))
        #expect(await ctx.resolveAnyAwaitingDeferred("eager") as? String == "hello")
        #expect(ctx.resolveAny("eager") as? String == "hello")

        // Plain and absent bindings answer identically too.
        ctx.bind("plain", value: 3 as Int)
        #expect(await ctx.resolveAnyAwaitingDeferred("plain") as? Int == 3)
        #expect(await ctx.resolveAnyAwaitingDeferred("missing") == nil)
    }

    /// An action's own binding wins over the value its future returned — the
    /// `bindingProducedWhileForcing` rule. The blocking path always applied it;
    /// the awaiting path did not, so adopting the awaiting path anywhere would
    /// have reintroduced the `AROStream`-versus-wrapper divergence that printed
    /// "Found AROStream<…> directories" on Linux and a count on macOS.
    @Test("An action's own binding wins on the awaiting path too")
    func awaitingReadPrefersTheActionsOwnBinding() async {
        let ctx = RuntimeContext(featureSetName: "Binding")
        let future = AROFuture(bindingName: "wrapped") {
            // While it runs, the action binds a different value for its own name.
            ctx.bind("wrapped", value: "the action's binding" as String, allowRebind: true)
            return "the returned value" as String
        }
        ctx.bindDeferredPlaceholder("wrapped", future: future)

        let resolved = await ctx.resolveAnyAwaitingDeferred("wrapped") as? String
        #expect(resolved == "the action's binding")
    }
}
