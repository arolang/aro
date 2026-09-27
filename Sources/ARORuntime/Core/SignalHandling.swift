// ============================================================
// SignalHandling.swift
// ARO Runtime - SIGINT/SIGTERM to a graceful shutdown
// ============================================================

import Foundation

#if os(Windows)
import WinSDK
#endif

// MARK: - Asking a process to stop

/// Installs a graceful-shutdown handler for whatever the host calls "stop".
///
/// Three places installed `signal(SIGINT)` and `signal(SIGTERM)` directly, with
/// no platform guard. Windows never delivers `SIGTERM` at all, and its Ctrl-C
/// arrives through the console control handler rather than through `signal`, so
/// a Windows build installed two handlers that could never fire: `Keepalive`
/// only unblocks through `ShutdownCoordinator.signalShutdown()`, which nothing
/// then called, and `Application-End: Success` never ran (GitLab #685).
///
/// The three call sites keep their own semantics — the last installer wins, as
/// it did with `signal` — so this changes where the handler comes from, not
/// which one is in force.
///
/// **The handler runs on an unspecified thread.** On POSIX it runs in a signal
/// context, on Windows on a thread the console subsystem creates for it; the
/// existing handlers are safe on both because all they do is set a flag on
/// `ShutdownCoordinator`. Keep it that way.
public enum ShutdownSignals {

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: (@convention(c) () -> Void)?

    /// Install `body` as the process's shutdown handler.
    ///
    /// `body` must not capture — it becomes a C function pointer either way,
    /// which is the same restriction `signal` already imposed.
    public static func install(_ body: @escaping @convention(c) () -> Void) {
        lock.lock()
        handler = body
        lock.unlock()

        #if os(Windows)
        // `true` adds the handler; the console subsystem calls it for Ctrl-C,
        // Ctrl-Break, and the three events that mean the session is going away.
        SetConsoleCtrlHandler(aroConsoleControlHandler, true)
        #else
        signal(SIGINT) { _ in ShutdownSignals.invoke() }
        signal(SIGTERM) { _ in ShutdownSignals.invoke() }
        #endif
    }

    /// Call whatever is installed, for tests.
    ///
    /// The real triggers are a POSIX signal and a Windows console event,
    /// neither of which a unit test can raise without ending the process, so
    /// the indirection is exercised directly instead.
    public static func invokeForTesting() { invoke() }

    /// Call whatever is installed. Safe when nothing is.
    fileprivate static func invoke() {
        lock.lock()
        let body = handler
        lock.unlock()
        body?()
    }
}

#if os(Windows)
/// The console subsystem's entry point, dispatching to whatever
/// `ShutdownSignals.install` last recorded.
///
/// `CTRL_CLOSE_EVENT`, `CTRL_LOGOFF_EVENT` and `CTRL_SHUTDOWN_EVENT` are
/// handled as well as Ctrl-C, because each of them ends the process and each
/// should still run `Application-End`. Windows allows a bounded grace period
/// after these — measured in seconds, and not extendable — so a shutdown that
/// takes longer than that is cut short. That is the same bargain the POSIX
/// path makes with its five-second safety `exit(0)`.
///
/// Returning `true` claims the event; returning `false` for anything else
/// leaves unknown events to the default handler.
private func aroConsoleControlHandler(_ eventType: DWORD) -> WindowsBool {
    switch eventType {
    case DWORD(CTRL_C_EVENT), DWORD(CTRL_BREAK_EVENT), DWORD(CTRL_CLOSE_EVENT),
         DWORD(CTRL_LOGOFF_EVENT), DWORD(CTRL_SHUTDOWN_EVENT):
        ShutdownSignals.invoke()
        return true
    default:
        return false
    }
}
#endif

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
        ShutdownSignals.install {
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
