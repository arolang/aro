// ============================================================
// CompiledExecutionPoolTaskLocalTests.swift
// ARO Runtime - Phase 5 TaskLocal slot ownership (Issue #55)
// ============================================================
//
// Slot ownership migrated from Thread.threadDictionary to a @TaskLocal.
// The TaskLocal is properly scoped to the enclosing withValue closure
// (or task) so it cannot leak across thread boundaries the way the
// thread-dictionary version could under task hops.

import XCTest
@testable import ARORuntime

final class CompiledExecutionPoolTaskLocalTests: XCTestCase {

    func testHoldsSlotIsFalseOutsideAnyScope() {
        XCTAssertFalse(CompiledExecutionPool.holdsSlot)
    }

    func testWithSlotOwnershipMarksFlag() {
        XCTAssertFalse(CompiledExecutionPool.holdsSlot)
        CompiledExecutionPool.shared.withSlotOwnership {
            XCTAssertTrue(CompiledExecutionPool.holdsSlot)
        }
        XCTAssertFalse(CompiledExecutionPool.holdsSlot)
    }

    func testWithAcquiredSlotMarksFlagAndPairsGate() {
        XCTAssertFalse(CompiledExecutionPool.holdsSlot)
        CompiledExecutionPool.shared.withAcquiredSlot {
            XCTAssertTrue(CompiledExecutionPool.holdsSlot)
        }
        XCTAssertFalse(CompiledExecutionPool.holdsSlot)
    }

    func testWithYieldedSlotPassesThroughWhenNotHeld() {
        var ran = false
        XCTAssertFalse(CompiledExecutionPool.holdsSlot)
        CompiledExecutionPool.shared.withYieldedSlot {
            // No slot to yield — the closure runs immediately, flag stays false.
            XCTAssertFalse(CompiledExecutionPool.holdsSlot)
            ran = true
        }
        XCTAssertTrue(ran)
        XCTAssertFalse(CompiledExecutionPool.holdsSlot)
    }

    func testWithYieldedSlotInsideOwnershipReleasesAndRejoins() {
        CompiledExecutionPool.shared.withSlotOwnership {
            XCTAssertTrue(CompiledExecutionPool.holdsSlot)
            CompiledExecutionPool.shared.withYieldedSlot {
                // While yielded the flag must be false.
                XCTAssertFalse(CompiledExecutionPool.holdsSlot)
            }
            // Outer scope sees the flag re-acquired.
            XCTAssertTrue(CompiledExecutionPool.holdsSlot)
        }
        XCTAssertFalse(CompiledExecutionPool.holdsSlot)
    }

    func testFlagIsScopedToCurrentSyncCallStack() async throws {
        // The TaskLocal is scoped to the enclosing withValue closure.
        // A sibling task that runs concurrently should NOT see the flag
        // we set in this scope.
        async let observed: Bool = {
            // Pause briefly so the outer scope is in flight.
            try? await Task.sleep(nanoseconds: 5_000_000)
            return CompiledExecutionPool.holdsSlot
        }()
        var observedInside = false
        CompiledExecutionPool.shared.withSlotOwnership {
            observedInside = CompiledExecutionPool.holdsSlot
        }
        XCTAssertTrue(observedInside)
        let siblingSawFlag = await observed
        XCTAssertFalse(siblingSawFlag)
    }
}
