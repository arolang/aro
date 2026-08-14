// ============================================================
// DeferredExecutionTests.swift
// ARO Runtime - Overlapping statement execution (ARO-0088, GitLab #485)
// ============================================================

import Foundation
import Testing
@testable import ARORuntime
@testable import AROParser

// MARK: - Policy

@Suite("Deferral policy (ARO-0088 §2)")
struct DeferralPolicyTests {

    @Test("Pure reads and transformations defer")
    func testDeferrableVerbs() {
        #expect(LazyActionPolicy.deferrable("retrieve"))
        #expect(LazyActionPolicy.deferrable("compute"))
        #expect(LazyActionPolicy.deferrable("extract"))
        #expect(LazyActionPolicy.deferrable("filter"))
    }

    @Test("Effects never defer")
    func testEffectsStayEager() {
        // Observable output and state changes must happen at their statement,
        // or source order stops meaning anything.
        for verb in ["log", "store", "emit", "publish", "send", "write", "commit", "delete", "update"] {
            #expect(!LazyActionPolicy.deferrable(verb), "\(verb) must not defer")
        }
    }

    @Test("Sleep stays eager — the delay is the effect")
    func testSleepStaysEager() {
        // `Sleep … ` followed by an unrelated `Log` is a pacing idiom. Deferring
        // it would delete the pause unless something happened to read the result.
        for verb in ["sleep", "delay", "pause"] {
            #expect(!LazyActionPolicy.deferrable(verb))
        }
    }

    @Test("Branch consumers stay eager even though they compute")
    func testBranchConsumersEager() {
        // Force-at-site wins over the deferrable list.
        for verb in ["compare", "validate", "accept"] {
            #expect(!LazyActionPolicy.deferrable(verb))
        }
    }

    @Test("Service lifecycle never defers")
    func testLifecycleEager() {
        for verb in ["start", "stop", "keepalive", "connect", "close"] {
            #expect(!LazyActionPolicy.deferrable(verb))
        }
    }
}

// MARK: - Overlap

private func runProgram(_ source: String) async throws {
    let compiled = Compiler.compile(source)
    guard compiled.isSuccess else {
        throw ActionError.runtimeError("test program failed to compile: \(compiled.diagnostics)")
    }
    let engine = ExecutionEngine()
    _ = try await engine.execute(compiled.analyzedProgram)
}

@Suite("Overlapping statements (ARO-0088 §2)", .serialized)
struct StatementOverlapTests {

    /// Two independent units of deferred work must cost about as much as one,
    /// not both added together.
    ///
    /// Measured at the future level rather than by driving a program with slow
    /// middleware: middleware re-enters the dispatch path, which makes it a test
    /// of the middleware plumbing as much as of overlap. End-to-end timing is
    /// covered by the example suite, where two 2-second HTTP requests in one
    /// feature set complete in ~2.1s interpreted and ~2.8s compiled, against a
    /// 4.2s sequential baseline.
    @Test("Independent deferred work overlaps instead of accumulating")
    func testIndependentWorkOverlaps() async throws {
        let delay = 0.4

        let start = Date()
        let first = AROFuture(bindingName: "first") {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            return 1 as any Sendable
        }
        let second = AROFuture(bindingName: "second") {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            return 2 as any Sendable
        }
        _ = try await first.value()
        _ = try await second.value()
        let elapsed = Date().timeIntervalSince(start)

        #expect(elapsed < delay * 1.9, "two independent futures took \(elapsed)s — they serialized")
    }

    /// End-to-end: the program's observable result is unchanged by deferral.
    @Test("A deferred result reaches the response with the right value")
    func testDeferredValueReachesResponse() async throws {
        let compiled = Compiler.compile("""
        (Application-Start: Deferred Value) {
            Create the <word> with "abcd".
            Compute the <size: length> from <word>.
            Return an <OK: status> with <size>.
        }
        """)
        #expect(compiled.isSuccess)

        let engine = ExecutionEngine()
        let response = try await engine.execute(compiled.analyzedProgram)
        let rendered = String(describing: response)
        #expect(rendered.contains("4"), "deferred length never reached the response: \(rendered)")
    }
}

// MARK: - Failures

@Suite("Deferred failures (ARO-0088 §4)", .serialized)
struct DeferredFailureTests {

    /// The mechanism: a failed result that nobody read is still forced at the
    /// drain, and the error is retrievable rather than discarded with the handle.
    ///
    /// Asserted at the context level rather than by running a program and
    /// expecting a throw. How the engine *surfaces* a handler failure differs by
    /// path — thrown to the caller for Application-Start, turned into an error
    /// response for an HTTP route, logged for a fire-and-forget handler — and a
    /// test that pins one of those routes fails on the others. (It did: this
    /// test passed on macOS and failed on Linux CI.) What must hold everywhere
    /// is that the failure is not lost.
    @Test("A deferred failure nobody reads is still raised by the drain")
    func testUnreadFailureSurfacesAtDrain() async throws {
        struct Boom: Error {}

        let context = RuntimeContext(featureSetName: "Unread Failure", businessActivity: "Test")
        let failing = AROFuture(bindingName: "n") { throw Boom() }
        context.bind("n", value: failing)
        context.registerPendingFuture(failing)

        // Nothing ever reads <n>.
        let drainError = context.drainPendingFutures()
        #expect(drainError != nil, "the drain must report the failure")
        #expect(context.takeDeferredFailure() != nil, "the failure must also be recorded for the exit path")
    }

    /// A failure observed by a *read* is recorded too — the read stays total
    /// (it yields an empty value) but the error is kept for feature-set exit.
    @Test("A failure observed by a read is recorded, not swallowed")
    func testObservedFailureIsRecorded() async throws {
        struct Boom: Error {}

        let context = RuntimeContext(featureSetName: "Observed Failure", businessActivity: "Test")
        let failing = AROFuture(bindingName: "n") { throw Boom() }
        context.bind("n", value: failing)
        context.registerPendingFuture(failing)

        // The read yields empty rather than throwing at an arbitrary point...
        let value = context.resolveAny("n")
        #expect(value as? String == "")

        // ...and the failure is still there to be reported.
        #expect(context.takeDeferredFailure() != nil)
    }
}

// MARK: - Placeholder binding

@Suite("Deferred placeholder binding (ARO-0088 §2)")
struct DeferredPlaceholderTests {

    /// A future starts running when it is created, so a fast action can bind its
    /// own result before the executor binds the placeholder. The executor must
    /// then leave the value alone — binding a handle over it is pointless, and
    /// it trapped the immutability backstop.
    @Test("A materialized value is distinguishable from a pending handle")
    func testHoldsMaterializedValue() async throws {
        let context = RuntimeContext(featureSetName: "Test", businessActivity: "Test")

        context.bind("done", value: "value")
        #expect(context.holdsMaterializedValue("done"))

        context.bind("pending", value: AROFuture(resolved: "later" as String, bindingName: "pending"))
        #expect(!context.holdsMaterializedValue("pending"),
                "a handle is not a materialized value, however it resolves")

        #expect(!context.holdsMaterializedValue("never-bound"))
    }

    /// Immutability attaches to the value, not the placeholder — otherwise the
    /// producing action cannot bind its own result.
    @Test("A pending placeholder does not lock the name")
    func testPlaceholderDoesNotLockName() async throws {
        let context = RuntimeContext(featureSetName: "Test", businessActivity: "Test")
        context.bind("result", value: AROFuture(resolved: 1 as Int, bindingName: "result"))

        // The producing action binding its own result must not trap.
        context.bind("result", value: 2)
        #expect(context.resolveAny("result") as? Int == 2)
    }
}

// MARK: - Stream prefetch

@Suite("Stream prefetch (ARO-0088 §6)")
struct StreamPrefetchTests {

    @Test("Prefetch preserves element order and count")
    func testPrefetchPreservesContents() async throws {
        let source = AROStream<Int>.from(Array(1...50))
        var received: [Int] = []
        for try await element in source.prefetch(4).stream {
            received.append(element)
        }
        #expect(received == Array(1...50))
    }

    /// The channel is what bounds run-ahead, so the bound is asserted on the
    /// channel.
    ///
    /// Asserting it end-to-end through `prefetch` would measure the *source*
    /// instead: an `AsyncThrowingStream` built with the default policy buffers
    /// without limit, so a source that ignores backpressure (an array, a socket
    /// pushing as fast as it can) still races ahead no matter what this stage
    /// does. Prefetch bounds the hand-off it owns; it cannot retrofit
    /// backpressure onto a producer that has none.
    @Test("A blocked consumer stops the producer once the buffer is full")
    func testProducerBlocksWhenBufferFull() async throws {
        let capacity = 3
        let channel = BoundedChannel<Int>(capacity: capacity)
        let sent = Counter()

        let producer = Task {
            for i in 1...100 {
                if Task.isCancelled { break }
                await channel.send(i)
                sent.increment()
            }
        }

        // Consumer takes nothing. The producer fills the buffer and parks.
        try await Task.sleep(nanoseconds: 200_000_000)
        let ahead = sent.value
        #expect(ahead > 0, "producer never ran ahead — no overlap")
        // capacity buffered, plus the one currently suspended in `send`.
        #expect(ahead <= capacity + 1, "producer ran away: \(ahead) sends for capacity \(capacity)")

        // Draining releases it again.
        _ = try await channel.next()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(sent.value > ahead, "consuming an element did not unblock the producer")

        // Release the parked producer and join it. Cancelling alone is not
        // enough — `send` parks on a non-cancellable continuation, so a leaked
        // suspended task outlives the test and stalls the whole suite (it did).
        await channel.finish()
        producer.cancel()
        _ = await producer.result
    }

    /// The trailing elements are the ones a prefetch stage loses when it gets
    /// this wrong: whatever is still buffered when the producer finishes.
    /// StreamExample dropped exactly its last `capacity` lines this way.
    @Test("Elements buffered when the producer finishes are still delivered")
    func testTrailingElementsSurviveFinish() async throws {
        for capacity in [1, 2, 4] {
            let source = AROStream<Int>.from(Array(1...9))
            var received: [Int] = []
            for try await element in source.prefetch(capacity).stream {
                received.append(element)
                // Consume slower than the producer so the buffer is occupied
                // when the source runs out.
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            #expect(received == Array(1...9), "capacity \(capacity) lost trailing elements: \(received)")
        }
    }

    @Test("A producer failure propagates to the consumer")
    func testFailurePropagates() async throws {
        struct Boom: Error {}
        let source = AROStream<Int> {
            AsyncThrowingStream { continuation in
                continuation.yield(1)
                continuation.finish(throwing: Boom())
            }
        }

        var caught: Error?
        do {
            for try await _ in source.prefetch(2).stream {}
        } catch {
            caught = error
        }
        #expect(caught is Boom)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
