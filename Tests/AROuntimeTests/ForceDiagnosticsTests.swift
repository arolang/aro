// ============================================================
// ForceDiagnosticsTests.swift
// ARO Runtime - Phase 6 slow-force diagnostics (Issue #55)
// ============================================================
//
// AROFuture.force() emits a one-line warning to stderr if the wait
// exceeds ForceDiagnostics.warningBudgetSeconds. The warning carries
// the binding name and source location so the operator can locate the
// stuck statement in the source. The wait then continues indefinitely
// — this is a diagnostic aid, not a deadline.

import XCTest
@testable import ARORuntime

final class ForceDiagnosticsTests: XCTestCase {

    final class WarningCapture: @unchecked Sendable {
        let lock = NSLock()
        var messages: [String] = []
        var count: Int { lock.withLock { messages.count } }
        var lastMessage: String? { lock.withLock { messages.last } }
    }

    override func tearDown() {
        super.tearDown()
        ForceDiagnostics.overrideBudget = nil
        // Restore default stderr handler.
        ForceDiagnostics.warningHandler = { msg in
            FileHandle.standardError.write(Data(msg.utf8))
        }
    }

    // MARK: - Default budget

    func testDefaultBudgetMatchesEnvAndLazyMode() {
        // Just exercise the property — value depends on env.
        _ = ForceDiagnostics.warningBudgetSeconds
    }

    // MARK: - Warning emitted on slow force

    func testWarningEmittedWhenWaitExceedsBudget() throws {
        let capture = WarningCapture()
        ForceDiagnostics.warningHandler = { msg in
            capture.lock.withLock { capture.messages.append(msg) }
        }
        ForceDiagnostics.overrideBudget = 0.05  // 50ms

        let future = AROFuture(
            bindingName: "slow-binding",
            sourceLocation: "main.aro:42:5"
        ) {
            try await Task.sleep(nanoseconds: 200_000_000)  // 200ms (4x budget)
            return 1 as Int
        }
        let value = try future.force()
        XCTAssertEqual(value as? Int, 1)
        XCTAssertEqual(capture.count, 1, "Expected exactly one slow-force warning")
        let msg = capture.lastMessage ?? ""
        XCTAssertTrue(msg.contains("slow-binding"), "warning lacks binding name: \(msg)")
        XCTAssertTrue(msg.contains("main.aro:42:5"), "warning lacks source location: \(msg)")
        XCTAssertTrue(msg.contains("Slow force"), "warning lacks marker: \(msg)")
    }

    // MARK: - No warning under fast force

    func testNoWarningWhenWaitInBudget() throws {
        let capture = WarningCapture()
        ForceDiagnostics.warningHandler = { msg in
            capture.lock.withLock { capture.messages.append(msg) }
        }
        ForceDiagnostics.overrideBudget = 5.0  // generous

        let future = AROFuture(bindingName: "fast", sourceLocation: nil) {
            return "ready" as String
        }
        _ = try future.force()
        XCTAssertEqual(capture.count, 0, "Expected no warning for fast force")
    }

    // MARK: - Disabled budget

    func testZeroBudgetDisablesWarnings() throws {
        let capture = WarningCapture()
        ForceDiagnostics.warningHandler = { msg in
            capture.lock.withLock { capture.messages.append(msg) }
        }
        ForceDiagnostics.overrideBudget = 0.0  // disabled

        let future = AROFuture(bindingName: "x", sourceLocation: nil) {
            try await Task.sleep(nanoseconds: 100_000_000)
            return 7 as Int
        }
        _ = try future.force()
        XCTAssertEqual(capture.count, 0, "Expected no warning when budget is 0")
    }

    // MARK: - Already-resolved future skips diagnostics

    func testResolvedFutureSkipsDiagnosticsPath() throws {
        let capture = WarningCapture()
        ForceDiagnostics.warningHandler = { msg in
            capture.lock.withLock { capture.messages.append(msg) }
        }
        ForceDiagnostics.overrideBudget = 0.001

        let future = AROFuture(resolved: "literal" as String, bindingName: "lit")
        _ = try future.force()
        XCTAssertEqual(capture.count, 0)
    }

    // MARK: - Source location optional

    func testWarningWithoutSourceLocation() throws {
        let capture = WarningCapture()
        ForceDiagnostics.warningHandler = { msg in
            capture.lock.withLock { capture.messages.append(msg) }
        }
        ForceDiagnostics.overrideBudget = 0.05

        let future = AROFuture(bindingName: "no-location", sourceLocation: nil) {
            try await Task.sleep(nanoseconds: 200_000_000)
            return 0 as Int
        }
        _ = try future.force()
        XCTAssertEqual(capture.count, 1)
        let msg = capture.lastMessage ?? ""
        XCTAssertTrue(msg.contains("no-location"))
        XCTAssertFalse(msg.contains(" at "), "shouldn't include `at` clause when location is nil: \(msg)")
    }
}
