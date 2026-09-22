// ============================================================
// SignalHandling.swift
// ARO Runtime - SIGINT/SIGTERM to a graceful shutdown
// ============================================================

import Foundation

// MARK: - Signal Handler

/// Thread-safe signal handler for runtime shutdown
///
/// Sendable-safety: the two mutable fields (`runtime`, `isSetup`) are only ever
/// read/written under `lock` (an `NSLock`) in `register`, `handleSignal`,
/// `isActive`, and `reset`. `handleSignal` deliberately copies `runtime` out
/// under the lock and releases it before calling `stop()`, so no user code runs
/// while the lock is held. The class is `@unchecked Sendable` because this
/// lock-based discipline is invisible to the compiler.
public final class RuntimeSignalHandler: @unchecked Sendable {
    public static let shared = RuntimeSignalHandler()

    private let lock = NSLock()
    private var runtime: Runtime?
    private var isSetup = false

    private init() {}

    /// Register a runtime for signal handling
    public func register(_ runtime: Runtime) {
        lock.lock()
        defer { lock.unlock() }

        self.runtime = runtime

        if !isSetup {
            setupSignalHandlers()
            isSetup = true
        }
    }

    /// Setup signal handlers (once)
    private func setupSignalHandlers() {
        signal(SIGINT) { _ in
            RuntimeSignalHandler.shared.handleSignal()
        }

        signal(SIGTERM) { _ in
            RuntimeSignalHandler.shared.handleSignal()
        }
    }

    /// Handle shutdown signal
    private func handleSignal() {
        lock.lock()
        let rt = runtime
        lock.unlock()

        rt?.stop()
    }

    /// Whether signal handlers have been set up
    public var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isSetup
    }

    /// Reset for testing (clears registered runtime)
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        runtime = nil
    }
}
