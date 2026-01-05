// ============================================================
// TTYDetectorTests.swift
// ARO Runtime - TTY Detection Unit Tests
// ============================================================

import Foundation
import Testing
@testable import ARORuntime

// MARK: - TTY Detector Tests

@Suite("TTY Detector Tests")
struct TTYDetectorTests {

    @Test("TTY detection properties return Boolean values")
    func testTTYDetectionReturnsBoolean() {
        // These are cached static properties, should always return Bool
        #expect(TTYDetector.stdoutIsTTY is Bool)
        #expect(TTYDetector.stderrIsTTY is Bool)
        #expect(TTYDetector.stdinIsTTY is Bool)
        #expect(TTYDetector.isInteractive is Bool)
    }

    @Test("isInteractive matches stdout and stderr TTY status")
    func testIsInteractiveMatchesStdoutAndStderr() {
        // isInteractive should be true only when BOTH stdout and stderr are TTY
        if TTYDetector.stdoutIsTTY && TTYDetector.stderrIsTTY {
            #expect(TTYDetector.isInteractive == true)
        } else {
            #expect(TTYDetector.isInteractive == false)
        }
    }
}
