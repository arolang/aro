// ============================================================
// EventLoopGroupManager.swift
// ARO Runtime - NIO Event Loop Group Management
// ============================================================
// NOTE: NIO is not available on Windows, so this file is excluded

#if !os(Windows)

import Foundation
import NIOCore
import NIOPosix

/// Manages SwiftNIO event loop groups to ensure proper cleanup
/// This prevents background threads from keeping the process alive during tests
public final class EventLoopGroupManager: @unchecked Sendable {
    public static let shared = EventLoopGroupManager()

    private let lock = NSLock()
    private var groups: [ObjectIdentifier: MultiThreadedEventLoopGroup] = [:]
    private var hasShutdown = false

    /// Shared event loop group for test environments
    /// Using a single shared group allows clean shutdown
    private lazy var sharedGroup: MultiThreadedEventLoopGroup = {
        // Create on GCD thread to ensure proper thread initialization
        // This prevents crashes when called from LLVM-compiled code
        var group: MultiThreadedEventLoopGroup!
        DispatchQueue.global(qos: .userInitiated).sync {
            group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        }
        registerGroup(group)
        return group
    }()

    private init() {
        // Register automatic shutdown on process exit
        setupAutomaticShutdown()

        // Debug: Confirm initialization
        let isTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestSessionIdentifier"] != nil
        if isTest {
            print("[EventLoopGroupManager] Initialized for test environment")
        }
    }

    /// Get an event loop group - uses shared group in test environments
    public func getEventLoopGroup() -> MultiThreadedEventLoopGroup {
        let isTestEnvironment = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestSessionIdentifier"] != nil

        if isTestEnvironment {
            // Use shared group for all servers in test environment
            return sharedGroup
        } else {
            // Create new group for production on GCD thread
            // This ensures proper thread initialization when called from LLVM-compiled code
            var group: MultiThreadedEventLoopGroup!
            DispatchQueue.global(qos: .userInitiated).sync {
                group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
            }
            registerGroup(group)
            return group
        }
    }

    /// Register an event loop group for tracking
    public func registerGroup(_ group: MultiThreadedEventLoopGroup) {
        lock.lock()
        defer { lock.unlock() }

        guard !hasShutdown else { return }
        groups[ObjectIdentifier(group)] = group
    }

    /// Shutdown all tracked event loop groups
    public func shutdownAll() {
        lock.lock()
        let groupsToShutdown = Array(groups.values)
        groups.removeAll()
        hasShutdown = true
        lock.unlock()

        // Shutdown all groups
        for group in groupsToShutdown {
            do {
                try group.syncShutdownGracefully()
            } catch {
                // Ignore errors during shutdown
            }
        }
    }

    /// Reset for next test run (test environments only)
    public func reset() {
        lock.lock()
        defer { lock.unlock() }

        hasShutdown = false
        // Note: groups remain registered, they'll be shut down on next shutdownAll()
    }

    /// Setup automatic shutdown when process exits
    private func setupAutomaticShutdown() {
        // Register atexit handler - this runs when process tries to exit
        // Shutting down the event loops allows the process to complete exit
        atexit {
            EventLoopGroupManager.shared.shutdownAll()
        }
    }
}

#endif  // !os(Windows)
