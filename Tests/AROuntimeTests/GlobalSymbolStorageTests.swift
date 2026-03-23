// ============================================================
// GlobalSymbolStorageTests.swift
// ARO Runtime - GlobalSymbolStorage eviction tests (issue #155)
// ============================================================

import XCTest
@testable import ARORuntime

final class GlobalSymbolEvictionTests: XCTestCase {

    // MARK: - Basic publish / resolve

    func testPublishAndResolve() async {
        let storage = GlobalSymbolStorage()
        await storage.publish(
            name: "greeting", value: "hello",
            fromFeatureSet: "Test", businessActivity: "Test Activity", executionId: "exec-1"
        )
        let value: String? = await storage.resolve("greeting", forBusinessActivity: "Test Activity")
        XCTAssertEqual(value, "hello")
    }

    func testResolveUnknownSymbolReturnsNil() async {
        let storage = GlobalSymbolStorage()
        let value: String? = await storage.resolve("missing", forBusinessActivity: "any")
        XCTAssertNil(value)
    }

    func testCountReflectsPublishedSymbols() async {
        let storage = GlobalSymbolStorage()
        let count0 = await storage.count
        XCTAssertEqual(count0, 0)
        await storage.publish(name: "a", value: "1", fromFeatureSet: "F", businessActivity: "", executionId: "e1")
        await storage.publish(name: "b", value: "2", fromFeatureSet: "F", businessActivity: "", executionId: "e1")
        let count2 = await storage.count
        XCTAssertEqual(count2, 2)
    }

    // MARK: - evict(executionId:)

    func testEvictRemovesSymbolsForExecution() async {
        let storage = GlobalSymbolStorage()
        await storage.publish(
            name: "result", value: "data",
            fromFeatureSet: "Handler", businessActivity: "My Activity", executionId: "exec-abc"
        )
        let before = await storage.count
        XCTAssertEqual(before, 1)

        await storage.evict(executionId: "exec-abc")

        let after = await storage.count
        XCTAssertEqual(after, 0)
        let value: String? = await storage.resolve("result", forBusinessActivity: "My Activity")
        XCTAssertNil(value, "Evicted symbol must not be resolvable")
    }

    func testEvictUnknownExecutionIsNoop() async {
        let storage = GlobalSymbolStorage()
        await storage.publish(name: "x", value: 42, fromFeatureSet: "F", businessActivity: "", executionId: "exec-1")
        await storage.evict(executionId: "exec-nonexistent")  // must not crash
        let count = await storage.count
        XCTAssertEqual(count, 1)
    }

    func testEvictOnlyTargetedExecution() async {
        let storage = GlobalSymbolStorage()
        await storage.publish(name: "sym-a", value: "A", fromFeatureSet: "F", businessActivity: "Act", executionId: "exec-1")
        await storage.publish(name: "sym-b", value: "B", fromFeatureSet: "F", businessActivity: "Act", executionId: "exec-2")

        await storage.evict(executionId: "exec-1")

        let valA = await storage.resolveAny("sym-a", forBusinessActivity: "Act")
        let valB = await storage.resolveAny("sym-b", forBusinessActivity: "Act")
        XCTAssertNil(valA, "exec-1 symbol must be removed")
        XCTAssertNotNil(valB, "exec-2 symbol must survive")
    }

    func testEvictMultipleSymbolsForSameExecution() async {
        let storage = GlobalSymbolStorage()
        for i in 1...5 {
            await storage.publish(
                name: "sym-\(i)", value: i,
                fromFeatureSet: "F", businessActivity: "", executionId: "exec-bulk"
            )
        }
        let before = await storage.count
        XCTAssertEqual(before, 5)

        await storage.evict(executionId: "exec-bulk")

        let after = await storage.count
        XCTAssertEqual(after, 0)
    }

    func testEvictTwiceIsNoop() async {
        let storage = GlobalSymbolStorage()
        await storage.publish(name: "x", value: "v", fromFeatureSet: "F", businessActivity: "", executionId: "exec-1")
        await storage.evict(executionId: "exec-1")
        await storage.evict(executionId: "exec-1")  // must not crash
        let count = await storage.count
        XCTAssertEqual(count, 0)
    }

    // MARK: - Ownership guard (concurrent-overwrite safety)

    func testLaterInvocationOverwritePreventStaleEviction() async {
        let storage = GlobalSymbolStorage()

        // exec-1 publishes "shared"
        await storage.publish(
            name: "shared", value: "v1",
            fromFeatureSet: "F", businessActivity: "A", executionId: "exec-1"
        )
        // exec-2 overwrites "shared" before exec-1 evicts
        await storage.publish(
            name: "shared", value: "v2",
            fromFeatureSet: "F", businessActivity: "A", executionId: "exec-2"
        )

        // exec-1 finishes and evicts — must NOT remove exec-2's entry
        await storage.evict(executionId: "exec-1")

        let value: String? = await storage.resolve("shared", forBusinessActivity: "A")
        XCTAssertEqual(value, "v2", "Newer invocation's symbol must survive stale eviction")
        let count = await storage.count
        XCTAssertEqual(count, 1)
    }

    func testOwnershipTransferToNewExecution() async {
        let storage = GlobalSymbolStorage()

        await storage.publish(name: "key", value: "old", fromFeatureSet: "F", businessActivity: "", executionId: "exec-A")
        await storage.publish(name: "key", value: "new", fromFeatureSet: "F", businessActivity: "", executionId: "exec-B")

        // Evicting exec-A must not touch exec-B's entry
        await storage.evict(executionId: "exec-A")
        let count1 = await storage.count
        XCTAssertEqual(count1, 1)

        // Evicting exec-B removes it
        await storage.evict(executionId: "exec-B")
        let count2 = await storage.count
        XCTAssertEqual(count2, 0)
    }

    // MARK: - allSymbols returns PublishedSymbol

    func testAllSymbolsReturnsPublishedEntries() async {
        let storage = GlobalSymbolStorage()
        await storage.publish(name: "alpha", value: "a", fromFeatureSet: "F1", businessActivity: "Act1", executionId: "e1")
        await storage.publish(name: "beta",  value: "b", fromFeatureSet: "F2", businessActivity: "Act2", executionId: "e2")

        let all = await storage.allSymbols()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all["alpha"]?.featureSet, "F1")
        XCTAssertEqual(all["alpha"]?.executionId, "e1")
        XCTAssertEqual(all["beta"]?.businessActivity, "Act2")
    }

    func testAllSymbolsEmptyAfterEviction() async {
        let storage = GlobalSymbolStorage()
        await storage.publish(name: "x", value: 1, fromFeatureSet: "F", businessActivity: "", executionId: "e1")
        await storage.evict(executionId: "e1")
        let all = await storage.allSymbols()
        XCTAssertTrue(all.isEmpty)
    }

    // MARK: - Business activity scoping unaffected

    func testBusinessActivityScopingStillWorks() async {
        let storage = GlobalSymbolStorage()
        await storage.publish(
            name: "secret", value: "hidden",
            fromFeatureSet: "F", businessActivity: "Activity-A", executionId: "e1"
        )
        let fromA: String? = await storage.resolve("secret", forBusinessActivity: "Activity-A")
        let fromB: String? = await storage.resolve("secret", forBusinessActivity: "Activity-B")

        XCTAssertEqual(fromA, "hidden")
        XCTAssertNil(fromB, "Symbol must not be accessible from a different business activity")
    }
}
