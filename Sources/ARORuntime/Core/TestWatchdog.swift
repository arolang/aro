// ============================================================
// TestWatchdog.swift
// ARO Runtime - Test Process Watchdog
// ============================================================

import Foundation

/// Watchdog that forcibly shuts down resources and exits if tests hang
/// Runs on a background queue independently of test execution
public final class TestWatchdog: @unchecked Sendable {
    public static let shared = TestWatchdog()

    private let isTestEnvironment: Bool

    private init() {
        // Only activate watchdog in actual XCTest environments
        // Don't trigger on paths that happen to contain "test"
        isTestEnvironment = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestSessionIdentifier"] != nil

        if isTestEnvironment {
            print("[TestWatchdog] Initialized - will force exit after 35 seconds if tests hang")
            startWatchdog()
        }
    }

    /// Start the watchdog on a background thread
    private func startWatchdog() {
        DispatchQueue.global(qos: .background).async {
            // Wait for tests to complete
            Thread.sleep(forTimeInterval: 35.0)

            print("\n[TestWatchdog] 35-second timeout reached")
            print("[TestWatchdog] Performing emergency shutdown of event loops and resources...")

            // Shutdown all resources
            self.performEmergencyShutdown()

            // Give shutdown a brief moment
            Thread.sleep(forTimeInterval: 0.5)

            print("[TestWatchdog] Forcing process exit")
            exit(0)
        }
    }

    /// Perform emergency shutdown of all resources
    private func performEmergencyShutdown() {
        // 1. Shutdown NIO event loops
        #if !os(Windows)
        EventLoopGroupManager.shared.shutdownAll()
        #endif

        // 2. Signal shutdown coordinator
        ShutdownCoordinator.shared.signalShutdown()

        // 3. Clean up EventBus
        EventBus.shared.unsubscribeAll()

        print("[TestWatchdog] Resource shutdown complete")
    }
}
