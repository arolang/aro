// ============================================================
// TestCleanup.swift
// ARO Runtime - Test Environment Cleanup Utilities
// ============================================================

import Foundation

/// Global cleanup utility for test environments
/// Call this at the end of test suites to ensure all resources are released
public final class TestCleanup: @unchecked Sendable {
    /// Singleton instance
    public static let shared = TestCleanup()

    private let lock = NSLock()
    private var hasPerformedCleanup = false

    private init() {
        // Force registration of atexit handler
        _forceAutomaticCleanupRegistration()
    }

    /// Perform comprehensive cleanup of all global singletons and resources
    /// This should be called at the end of test execution to prevent hanging
    public func performCleanup() {
        lock.lock()
        defer { lock.unlock() }

        // Only perform cleanup once
        guard !hasPerformedCleanup else { return }
        hasPerformedCleanup = true

        // 1. Signal shutdown to any waiting coordinators
        ShutdownCoordinator.shared.signalShutdown()

        // 2. Clean up EventBus continuations and subscriptions
        EventBus.shared.unsubscribeAll()

        // 3. Shutdown all SwiftNIO event loop groups (CRITICAL for clean exit)
        EventLoopGroupManager.shared.shutdownAll()

        // 4. Reset shutdown coordinator for next run
        ShutdownCoordinator.shared.reset()

        // 5. Give a brief moment for async cleanup tasks to complete
        Thread.sleep(forTimeInterval: 0.2)
    }

    /// Reset the cleanup state (for use between test runs)
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        hasPerformedCleanup = false
    }

    /// Perform cleanup if running in a test environment
    /// Detects test environment automatically and performs cleanup
    public func performCleanupIfNeeded() {
        let isTestEnvironment = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestSessionIdentifier"] != nil

        if isTestEnvironment {
            performCleanup()
        }
    }
}

// MARK: - Automatic Cleanup on Process Exit

/// Automatically register cleanup to run when process exits
/// This ensures cleanup happens even if tests don't explicitly call it
private let _automaticCleanupRegistration: Void = {
    // Register atexit handler for automatic cleanup
    atexit {
        TestCleanup.shared.performCleanupIfNeeded()
    }
}()

// Force initialization of automatic cleanup registration
@inline(never)
private func _forceAutomaticCleanupRegistration() {
    _ = _automaticCleanupRegistration
}
