// ============================================================
// BackpressureMonitorTests.swift
// ARO Runtime — stream buffer occupancy (GitLab #444)
// ============================================================
//
// The behaviour under test is the one that is otherwise invisible:
// a slow consumer parks its producer, and that parking is the
// backpressure mechanism working. These assert we can see it.

import Foundation
import Testing
@testable import ARORuntime

@Suite("Backpressure monitor (#444)", .serialized)
struct BackpressureMonitorTests {

    /// The monitor is process-wide, so each test starts from a
    /// known state and leaves sampling off.
    private func withMonitor(_ body: () async throws -> Void) async rethrows {
        BackpressureMonitor.shared.reset()
        BackpressureMonitor.shared.enable()
        defer { BackpressureMonitor.shared.disable() }
        try await body()
    }

    @Test("Sampling is off unless something asks for it")
    func disabledByDefault() {
        // A plain `aro run` must not pay for a UI feature nobody is
        // watching, so this is a behaviour, not an implementation
        // detail.
        BackpressureMonitor.shared.disable()
        #expect(!BackpressureMonitor.shared.isEnabled)
        BackpressureMonitor.shared.enable()
        #expect(BackpressureMonitor.shared.isEnabled)
        BackpressureMonitor.shared.disable()
    }

    @Test("A disabled monitor records nothing")
    func disabledRecordsNothing() async throws {
        BackpressureMonitor.shared.disable()
        let stream = AROStream<Int> {
            AsyncThrowingStream { continuation in
                for value in 1...20 { continuation.yield(value) }
                continuation.finish()
            }
        }
        var seen = 0
        for try await _ in stream.prefetch(4, label: "quiet").stream { seen += 1 }
        #expect(seen == 20)
        #expect(BackpressureMonitor.shared.snapshot().isEmpty)
    }

    @Test("A full buffer parks its producer and the stall is recorded")
    func fullBufferParksProducer() async throws {
        try await withMonitor {
            // Deliberately not "run a fast producer against a slow
            // consumer and hope the buffer fills". That version
            // passed locally and reported stallCount == 0 on the
            // two-core CI pod (job 122057), because which of the two
            // tasks is actually slower there is a property of the
            // runner, not of the code. A test whose assertion
            // depends on the scheduler is not testing backpressure.
            //
            // Instead the buffer is filled first, so the next send
            // *cannot* proceed — no scheduling outcome lets it
            // through — and the stall is read after the consumer
            // releases it.
            let channel = BoundedChannel<Int>(capacity: 1, label: "parked-stage")
            await channel.send(1)

            let blocked = Task { await channel.send(2) }
            // One bounded wait for the task to reach its first
            // suspension. This is waiting for an event that must
            // happen, not racing two speeds — 200ms is orders of
            // magnitude more than a Task needs to start, on any
            // runner that can run the suite at all.
            try await Task.sleep(nanoseconds: 200_000_000)

            // Draining resumes the parked producer, which is when
            // the stall is recorded (the duration isn't known until
            // the wait ends).
            #expect(try await channel.next() == 1)
            await blocked.value
            #expect(try await channel.next() == 2)

            let sample = BackpressureMonitor.shared.snapshot()
                .first { $0.label == "parked-stage" }
            let found = try #require(sample)
            #expect(found.capacity == 1)
            #expect(found.stallCount > 0, "a full buffer must park its producer")
            #expect(found.stalledSeconds > 0)
        }
    }

    @Test("A slow consumer still receives every element in order")
    func slowConsumerDeliversEverything() async throws {
        // What the producer/consumer pairing can assert without
        // depending on which side wins: instrumentation must not
        // change delivery.
        try await withMonitor {
            let stream = AROStream<Int> {
                AsyncThrowingStream { continuation in
                    for value in 1...40 { continuation.yield(value) }
                    continuation.finish()
                }
            }
            var received: [Int] = []
            for try await value in stream.prefetch(2, label: "slow-stage").stream {
                received.append(value)
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            #expect(received == Array(1...40))
            let sample = BackpressureMonitor.shared.snapshot()
                .first { $0.label == "slow-stage" }
            #expect(sample?.capacity == 2)
        }
    }

    @Test("Backpressure does not change what the stream delivers")
    func orderingPreserved() async throws {
        try await withMonitor {
            let stream = AROStream<Int> {
                AsyncThrowingStream { continuation in
                    for value in 1...50 { continuation.yield(value) }
                    continuation.finish()
                }
            }
            var received: [Int] = []
            for try await value in stream.prefetch(3, label: "ordered").stream {
                received.append(value)
            }
            #expect(received == Array(1...50))
        }
    }

    @Test("Fill is the fraction of capacity in use")
    func fillFraction() {
        let empty = BackpressureSample(label: "a", depth: 0, capacity: 8,
                                       stallCount: 0, stalledSeconds: 0)
        let half = BackpressureSample(label: "b", depth: 4, capacity: 8,
                                      stallCount: 0, stalledSeconds: 0)
        let full = BackpressureSample(label: "c", depth: 8, capacity: 8,
                                      stallCount: 3, stalledSeconds: 0.4)
        #expect(empty.fill == 0)
        #expect(half.fill == 0.5)
        #expect(full.fill == 1.0)
    }

    @Test("A zero-capacity reading doesn't divide by zero")
    func zeroCapacity() {
        let sample = BackpressureSample(label: "x", depth: 3, capacity: 0,
                                        stallCount: 0, stalledSeconds: 0)
        #expect(sample.fill == 0)
        #expect(!sample.isBackpressured)
    }

    @Test("Full is not the same as backpressured")
    func fullWithoutStallsIsNotPressure() {
        // A buffer that filled once and drained is healthy. The
        // bottleneck is the one that fills *and* parks producers —
        // colouring the first amber would cry wolf on every fast
        // pipeline.
        let burst = BackpressureSample(label: "burst", depth: 8, capacity: 8,
                                       stallCount: 0, stalledSeconds: 0)
        let stuck = BackpressureSample(label: "stuck", depth: 8, capacity: 8,
                                       stallCount: 12, stalledSeconds: 1.5)
        #expect(!burst.isBackpressured)
        #expect(stuck.isBackpressured)
    }

    @Test("A mostly-empty buffer is never backpressured")
    func lowFillIsNeverPressure() {
        let sample = BackpressureSample(label: "y", depth: 1, capacity: 8,
                                        stallCount: 99, stalledSeconds: 9)
        #expect(!sample.isBackpressured)
    }

    @Test("Snapshots list the tightest stage first")
    func snapshotSorted() async throws {
        try await withMonitor {
            let fast = AROStream<Int> {
                AsyncThrowingStream { continuation in
                    for value in 1...5 { continuation.yield(value) }
                    continuation.finish()
                }
            }
            for try await _ in fast.prefetch(64, label: "roomy").stream {}
            let samples = BackpressureMonitor.shared.snapshot()
            // Sorted by fill descending — the head of the list is
            // where a reviewer should look first.
            let fills = samples.map(\.fill)
            #expect(fills == fills.sorted(by: >))
        }
    }

    @Test("Reset clears readings between runs")
    func resetClears() async throws {
        try await withMonitor {
            let stream = AROStream<Int> {
                AsyncThrowingStream { continuation in
                    continuation.yield(1)
                    continuation.finish()
                }
            }
            for try await _ in stream.prefetch(2, label: "one-shot").stream {}
            #expect(!BackpressureMonitor.shared.snapshot().isEmpty)
            BackpressureMonitor.shared.reset()
            #expect(BackpressureMonitor.shared.snapshot().isEmpty)
        }
    }

    @Test("A finished stage keeps its stall total but reports no depth")
    func finishedStageKeepsHistory() async throws {
        try await withMonitor {
            let stream = AROStream<Int> {
                AsyncThrowingStream { continuation in
                    for value in 1...10 { continuation.yield(value) }
                    continuation.finish()
                }
            }
            for try await _ in stream.prefetch(2, label: "done").stream {}
            // Post-run review is exactly when someone asks "where
            // did the time go", so the totals have to survive the
            // channel finishing.
            let sample = BackpressureMonitor.shared.snapshot()
                .first { $0.label == "done" }
            #expect(sample != nil)
        }
    }
}
