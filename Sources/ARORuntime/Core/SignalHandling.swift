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
/// **The handler runs on an ordinary thread, not in a signal context**
/// (GitLab #630). On POSIX the signal handler writes one byte to a self-pipe
/// and returns; a dedicated thread reads that byte and calls the installed
/// handler. On Windows it arrives on a thread the console subsystem creates.
/// Both are normal threads, so a handler may take a lock, allocate, and start
/// a `Task`.
///
/// It did not used to be. `signal(SIGINT) { _ in … }` ran the handler in a
/// POSIX signal context, where `pthread_mutex_lock`, Swift runtime allocation
/// and `Task` creation are all undefined behaviour — and the installed handler
/// took two `NSLock`s, published an event on the event-bus actor (spawning a
/// `Task`) and resumed continuations. If the signal landed while the main
/// thread held either lock, the process deadlocked instead of shutting down:
/// an unreproducible "Ctrl-C hangs".
///
/// The comment here used to say handlers must only set a flag, which is the
/// correct rule for a signal context and was not what the code did. Moving
/// delivery off the signal context makes the rule unnecessary rather than
/// unenforced.
public enum ShutdownSignals {

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: (@convention(c) () -> Void)?

    /// Read end of the self-pipe, and the thread draining it.
    ///
    /// Held for the life of the process: the reader thread is what turns a
    /// signal into a normal-thread call, and there is nothing to shut it
    /// down *with* once shutdown is the thing it delivers.
    nonisolated(unsafe) private static var pipeReadFD: Int32 = -1
    nonisolated(unsafe) private static var pipeWriteFD: Int32 = -1
    nonisolated(unsafe) private static var readerStarted = false

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
        // This one already ran on an ordinary thread.
        SetConsoleCtrlHandler(aroConsoleControlHandler, true)
        #else
        // Only take over the disposition if there is somewhere to deliver to.
        //
        // If the pipe cannot be created, installing a handler that writes to
        // a closed fd would make the process *ignore* SIGTERM — which is the
        // failure this whole arrangement exists to avoid, arrived at from the
        // other direction. Leaving the default disposition means Ctrl-C
        // terminates without running `Application-End`, which is worse than
        // graceful and much better than unkillable.
        if installSelfPipe() {
            signal(SIGINT) { _ in ShutdownSignals.notifyFromSignalContext() }
            signal(SIGTERM) { _ in ShutdownSignals.notifyFromSignalContext() }
        }
        #endif
    }

    #if !os(Windows)
    /// Everything the signal handler is allowed to do: one `write`.
    ///
    /// `write(2)` is on POSIX's async-signal-safe list. Taking a lock,
    /// allocating, or starting a `Task` is not, which is what the previous
    /// handler did — see the type comment.
    ///
    /// `errno` is saved and restored because a handler that clobbers it
    /// corrupts whatever the interrupted thread was about to read from it,
    /// and that bug would be even harder to find than the one this replaces.
    private static func notifyFromSignalContext() {
        let saved = errno
        var byte: UInt8 = 1
        _ = withUnsafeBytes(of: &byte) { buffer in
            write(pipeWriteFD, buffer.baseAddress, 1)
        }
        errno = saved
    }

    /// Create the self-pipe and the thread that drains it, once.
    ///
    /// A **self-pipe**, not a `DispatchSourceSignal`. The source version was
    /// tried and reverted: it requires `signal(…, SIG_IGN)` first, because a
    /// source observes a signal rather than consuming it — and on Linux the
    /// compiled HTTP examples then ignored `SIGTERM` outright and had to be
    /// killed, turning `OrderService`, `RepositoryObserver` and `UserService`
    /// into 60-second timeouts in CI. Setting a process's disposition to
    /// `SIG_IGN` and depending on a library to deliver it instead is a bet
    /// that the library is servicing its queues; a handler plus a pipe is not
    /// a bet.
    ///
    /// `install` is called from three sites and the last handler wins, as it
    /// did with `signal`; only the pipe and its reader are once-only.
    /// - Returns: whether a signal handler may now be installed.
    @discardableResult
    private static func installSelfPipe() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !readerStarted else { return true }

        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else {
            FileHandle.standardError.write(Data((
                "[ARO] Could not create the shutdown signal pipe (errno \(errno)); "
                + "Ctrl-C will terminate without running Application-End.\n").utf8))
            return false
        }
        pipeReadFD = fds[0]
        pipeWriteFD = fds[1]
        readerStarted = true

        let thread = Thread {
            var byte: UInt8 = 0
            while true {
                let n = withUnsafeMutableBytes(of: &byte) { buffer in
                    read(ShutdownSignals.pipeReadFD, buffer.baseAddress, 1)
                }
                if n == 1 {
                    // An ordinary thread: locks, allocation and tasks are all
                    // fine here, which is the entire point.
                    ShutdownSignals.invoke()
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    break
                }
            }
        }
        thread.name = "aro.shutdown-signals"
        thread.start()
        return true
    }
    #endif

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

    /// Handle shutdown signal.
    ///
    /// Taking a lock and calling `stop()` here is safe now that delivery
    /// happens on a dispatch queue rather than in a POSIX signal context
    /// (GitLab #630) — before that it was undefined behaviour, and a signal
    /// arriving while the main thread held this lock deadlocked the process.
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

    /// Reset for testing (clears the registered runtime).
    ///
    /// `isSetup` deliberately stays true (GitLab #630 notes it as a bug; it
    /// is not). It records that the process's signal disposition has been
    /// changed and the dispatch sources created — neither of which `reset`
    /// undoes, and neither of which *should* be undone, since the sources
    /// must outlive any one runtime. Clearing the flag would make the next
    /// `register` call `setupSignalHandlers` again; that is idempotent now
    /// (`installDispatchSources` returns early), but the flag would then be
    /// claiming something it had not done.
    ///
    /// `isActive` reads it, and `ServerActions` asks `isActive` to decide
    /// whether to install its own handlers. Leaving it true is the answer
    /// that keeps that decision correct: the handlers really are installed.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        runtime = nil
    }
}
