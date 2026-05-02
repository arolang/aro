// ============================================================
// AROFutureTests.swift
// ARO Runtime - Tests for the lazy action result handle (Issue #55, Phase 1)
// ============================================================

import XCTest
@testable import ARORuntime

final class AROFutureTests: XCTestCase {

    // MARK: - Resolution

    func testForceReturnsValue() throws {
        let future = AROFuture(bindingName: "x") {
            return "hello" as String
        }
        let value = try future.force()
        XCTAssertEqual(value as? String, "hello")
    }

    func testForceWaitsForCompletion() throws {
        let future = AROFuture(bindingName: "y") {
            try await Task.sleep(nanoseconds: 30_000_000)
            return 42 as Int
        }
        let value = try future.force()
        XCTAssertEqual(value as? Int, 42)
    }

    func testMultipleForcesReturnSameValue() throws {
        let future = AROFuture(bindingName: "z") {
            return [1, 2, 3] as [Int]
        }
        let v1 = try future.force()
        let v2 = try future.force()
        let v3 = try future.force()
        XCTAssertEqual(v1 as? [Int], [1, 2, 3])
        XCTAssertEqual(v2 as? [Int], [1, 2, 3])
        XCTAssertEqual(v3 as? [Int], [1, 2, 3])
    }

    func testForcePropagatesErrors() {
        struct E: Error, Equatable {}
        let future = AROFuture(bindingName: "err") {
            throw E()
        }
        XCTAssertThrowsError(try future.force()) { error in
            XCTAssertTrue(error is E)
        }
    }

    func testIsResolvedTrueAfterForce() throws {
        let future = AROFuture(bindingName: "r") {
            try await Task.sleep(nanoseconds: 20_000_000)
            return "done" as String
        }
        _ = try future.force()
        XCTAssertTrue(future.isResolved)
    }

    // MARK: - Pre-resolved

    func testResolvedConvenienceInitializer() throws {
        let future = AROFuture(resolved: "literal" as String, bindingName: "lit")
        XCTAssertTrue(future.isResolved)
        XCTAssertEqual(try future.force() as? String, "literal")
    }

    // MARK: - Fan-out

    func testForceFromMultipleThreadsReturnsSameValue() throws {
        let future = AROFuture(bindingName: "fanout") {
            try await Task.sleep(nanoseconds: 50_000_000)
            return 7 as Int
        }

        final class Collector: @unchecked Sendable {
            let lock = NSLock()
            var values: [Int] = []
            func append(_ v: Int) { lock.withLock { values.append(v) } }
        }

        let collector = Collector()
        let group = DispatchGroup()
        let queue = DispatchQueue.global()
        for _ in 0..<8 {
            group.enter()
            queue.async {
                defer { group.leave() }
                if let v = try? future.force() as? Int {
                    collector.append(v)
                }
            }
        }
        group.wait()
        XCTAssertEqual(collector.values.count, 8)
        XCTAssertTrue(collector.values.allSatisfy { $0 == 7 })
    }

    // MARK: - Cancellation on deinit

    func testTaskIsCancelledWhenFutureDeallocates() async throws {
        actor CancelTracker {
            var wasCancelled = false
            func mark() { wasCancelled = true }
        }
        let tracker = CancelTracker()

        // Scope the future so we can deinit it.
        do {
            let future = AROFuture(bindingName: "cancel") {
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    return "never" as String
                } catch {
                    await tracker.mark()
                    throw error
                }
            }
            // Give the inner Task a moment to start its sleep before we deinit.
            try await Task.sleep(nanoseconds: 5_000_000)
            _ = future // explicit use to keep the future alive until here
        }

        // Wait briefly for the cancellation to propagate.
        try await Task.sleep(nanoseconds: 50_000_000)
        let cancelled = await tracker.wasCancelled
        XCTAssertTrue(cancelled)
    }

}
