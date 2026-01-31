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
    /// GCD wrapper provides extra safety in compiled mode where Swift async runtime
    /// may not be fully initialized when first accessed
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
        // Mark as initialized BEFORE registering atexit handler
        // This allows the atexit handler to know if we need to do anything
        EventLoopGroupManager._instanceInitialized = true

        // Register atexit handler - this runs when process tries to exit
        // Only shutdown if the manager was actually used (groups were created)
        atexit {
            // Only access shared if it was already initialized
            // This prevents recursive initialization during exit which causes hangs
            guard EventLoopGroupManager._instanceInitialized else { return }
            EventLoopGroupManager.shared.shutdownAll()
        }
    }

    /// Static flag to track if the singleton was ever initialized
    /// Must be set BEFORE the atexit handler is registered to avoid race conditions
    /// nonisolated(unsafe) is used because this is only ever written once (during init)
    /// and read once (during atexit) - no concurrent access is possible
    nonisolated(unsafe) private static var _instanceInitialized = false
}

#endif  // !os(Windows)
