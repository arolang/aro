// ============================================================
// TestMain.swift
// ARO Runtime Tests - Global Test Setup
// ============================================================

import Foundation
@testable import ARORuntime

/// Global test initialization
/// This ensures watchdog is initialized before any tests run
private let _globalTestSetup: Void = {
    // Initialize the test watchdog - it will forcibly exit after 30s if tests hang
    _ = TestWatchdog.shared

    // Initialize cleanup utilities
    _ = TestCleanup.shared

    print("[Test Setup] Test watchdog and cleanup initialized")
}()

/// Force initialization by referencing the setup
public func forceGlobalTestSetup() {
    _ = _globalTestSetup
}

// Auto-initialize on module load
private let _autoInit: Void = forceGlobalTestSetup()
