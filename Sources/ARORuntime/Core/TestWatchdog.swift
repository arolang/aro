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

    /// Held strongly while armed so the timer source survives the
    /// init return. `DispatchSourceTimer` releases its background
    /// thread until the deadline fires — no \`Thread.sleep\`
    /// pinning a thread for 35 seconds (#333).
    private var timer: DispatchSourceTimer?

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

    /// Arm the watchdog via a DispatchSourceTimer on a background
    /// queue. The timer fires once at the 35-second deadline,
    /// runs the emergency-shutdown handler, and then forces
    /// process exit.
    private func startWatchdog() {
        let queue = DispatchQueue.global(qos: .background)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 35.0, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            print("\n[TestWatchdog] 35-second timeout reached")
            print("[TestWatchdog] Performing emergency shutdown of event loops and resources...")
            self?.performEmergencyShutdown()
            // Brief grace window before exit so the shutdown
            // handlers' stdout makes it to the test log.
            queue.asyncAfter(deadline: .now() + 0.5) {
                print("[TestWatchdog] Forcing process exit")
                exit(0)
            }
        }
        self.timer = timer
        timer.resume()
    }

    /// Perform emergency shutdown of all resources
    private func performEmergencyShutdown() {
        // 1. Shutdown NIO event loops
        // Note: EventLoopGroupManager is not available on Windows
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
