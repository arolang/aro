// ============================================================
// BoundedObserverPoolTests.swift
// Issue #227 — bounded worker pool for fire-and-forget observer dispatch.
// ============================================================
//
// These pin the two properties the design has to guarantee, both of which
// the naive `publishAndTrack → publish` swap failed (see #227):
//
//   1. Concurrent observer bodies never exceed the worker count (the "no cap"
//      variant OOM'd because every handler ran at once).
//   2. A recursive observer → store → observer cascade drains completely with
//      no deadlock, even when the bounded queue is smaller than the live fan-out
//      (the "block the producer" variant deadlocked because producers were also
//      consumers).
//
// The pool is exercised directly via `publishBackpressured` so the test does
// not depend on the global `ARO_ASYNC_OBSERVERS` opt-in.

import XCTest
@testable import ARORuntime

private struct PoolTestEvent: RuntimeEvent {
    static let eventType = "PoolTestEvent"
    let timestamp = Date()
    /// Recursion depth, used by the cascade test to bound the tree.
    let depth: Int
}

/// Thread-safe tracker for max observed concurrency and total invocations.
private actor ConcurrencyTracker {
    private var current = 0
    private(set) var maxConcurrent = 0
    private(set) var total = 0

    func enter() {
        current += 1
        total += 1
        if current > maxConcurrent { maxConcurrent = current }
    }
    func leave() { current -= 1 }
    func record() { total += 1 }
}

final class BoundedObserverPoolTests: XCTestCase {

    /// No more than `workerCount` observer bodies run at once, and every
    /// published event's handler runs exactly once (nothing dropped).
    func testBoundedConcurrencyAndCompleteDrain() async {
        let bus = EventBus()
        let workers = 3
        await bus.configureObserverPool(workerCount: workers, queueCapacity: 8)

        let tracker = ConcurrencyTracker()
        bus.subscribe(to: PoolTestEvent.self) { _ in
            await tracker.enter()
            // Hold the worker briefly so overlap is observable.
            try? await Task.sleep(nanoseconds: 5_000_000) // 5 ms
            await tracker.leave()
        }

        let total = 60
        for _ in 0..<total {
            bus.publishBackpressured(PoolTestEvent(depth: 0))
        }

        let drained = await bus.awaitPendingEvents(timeout: 15)
        XCTAssertTrue(drained, "the pool must drain without timing out")

        let ran = await tracker.total
        let peak = await tracker.maxConcurrent
        XCTAssertEqual(ran, total, "every handler must run exactly once")
        XCTAssertLessThanOrEqual(
            peak, workers,
            "no more than workerCount (\(workers)) handlers may run concurrently; saw \(peak)"
        )
        XCTAssertGreaterThan(peak, 1, "the pool should actually run handlers in parallel")
    }

    /// A recursive observer→store→observer cascade drains completely with no
    /// deadlock, even when the queue capacity is far smaller than the live
    /// fan-out — the case that deadlocked the "block the producer" variant.
    func testRecursiveCascadeDrainsWithoutDeadlock() async {
        let bus = EventBus()
        // Tight queue + few workers so the cascade repeatedly hits capacity and
        // forces producer backpressure — the deadlock-prone regime.
        await bus.configureObserverPool(workerCount: 2, queueCapacity: 4)

        let tracker = ConcurrencyTracker()
        let maxDepth = 6
        let fanout = 3

        // Each observer, below the depth limit, fires `fanout` children
        // fire-and-forget (mirrors Store → RepositoryChangedEvent recursion).
        bus.subscribe(to: PoolTestEvent.self) { [weak bus] event in
            await tracker.record()
            guard let bus, event.depth < maxDepth else { return }
            for _ in 0..<fanout {
                bus.publishBackpressured(PoolTestEvent(depth: event.depth + 1))
            }
        }

        bus.publishBackpressured(PoolTestEvent(depth: 0))

        let drained = await bus.awaitPendingEvents(timeout: 30)
        XCTAssertTrue(drained, "recursive cascade must drain — no deadlock, no timeout")

        // Full (fanout)-ary tree of height maxDepth: sum_{d=0}^{maxDepth} fanout^d.
        var expected = 0
        var power = 1
        for _ in 0...maxDepth {
            expected += power
            power *= fanout
        }
        let fired = await tracker.total
        XCTAssertEqual(fired, expected, "every node in the cascade must fire exactly once")
    }
}
