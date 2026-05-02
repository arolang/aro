// ============================================================
// AROFuture.swift
// ARORuntime - Lazy Action Result Handle (Issue #55, Phases 1, 4)
// ============================================================
//
// AROFuture is the foundation for async-by-default action execution.
// Every non-force-at-site action call returns an AROFuture instead of
// an eager value (see LazyActionPolicy for the force-at-site set).
//
// Phase 4: the underlying Task runs on `ActionTaskExecutor`, a custom
// TaskExecutor backed by GCD's elastic global queue, NOT on Swift's
// cooperative pool. This eliminates cascading-emit deadlocks: even if
// every action thread is blocked waiting on another future, GCD will
// spawn additional threads to make progress.
//
// Refcount semantics: an AROFuture is reference-counted via Unmanaged
// when handed across the C ABI. When the last reference is released,
// deinit cancels the underlying Task — implementing the "detach upstream
// from consumers" cancellation policy resolved on issue #55.
//
// Thread-safety: safe for any number of concurrent force() callers,
// including from C pthreads. Uses DispatchGroup for fan-out — group.wait()
// blocks all waiters until the Task signals completion exactly once.

import Foundation

// MARK: - ActionTaskExecutor (Issue #55, Phase 4)

/// TaskExecutor that runs action work on GCD's elastic global queue.
///
/// Why a custom executor: Swift's default cooperative pool has a fixed
/// thread count. Cascading event chains (emit → handler → emit → ...)
/// can fill it with semaphore-blocked threads, deadlocking the program.
/// GCD's global queue is elastic — it spawns additional threads under
/// load — so action work can't starve itself. Force points (the C bridge,
/// the value-accessors) block their calling pthread on a DispatchGroup
/// while this executor keeps making progress underneath.
///
/// Linux note: swift-corelibs-libdispatch implements `DispatchQueue.global`
/// with the same elastic semantics, so the design ports unchanged.
@available(macOS 15.0, *)
public final class ActionTaskExecutor: TaskExecutor, @unchecked Sendable {
    public static let shared = ActionTaskExecutor()

    private let queue = DispatchQueue.global(qos: .userInitiated)

    private init() {}

    public func enqueue(_ job: consuming ExecutorJob) {
        let unowned = UnownedJob(job)
        queue.async { [unownedExecutor = self.asUnownedTaskExecutor()] in
            unowned.runSynchronously(on: unownedExecutor)
        }
    }

    public func asUnownedTaskExecutor() -> UnownedTaskExecutor {
        UnownedTaskExecutor(ordinary: self)
    }
}

// MARK: - AROFuture

/// A pending action result.
///
/// Wraps a `Task<any Sendable, Error>` already running on the cooperative
/// pool. Multiple consumers may force the same future; the result is
/// memoized after first completion. Cancellation is automatic when the
/// last consumer reference is released.
public final class AROFuture: @unchecked Sendable {

    /// The binding name this future will resolve. Used for diagnostics.
    public let bindingName: String

    /// Optional source location ("file.aro:42:5"). Used for diagnostics.
    public let sourceLocation: String?

    /// Underlying task. Cancelled in deinit when the last consumer goes away.
    private let task: Task<any Sendable, Error>

    /// Result storage with a fan-out wait primitive. Lives in its own object
    /// so the Task body doesn't need to capture self.
    private let storage: ResultStorage

    /// Create a future that runs `work` on the action task executor
    /// (GCD-backed, elastic), separate from Swift's cooperative pool.
    public init(
        bindingName: String,
        sourceLocation: String? = nil,
        priority: TaskPriority? = nil,
        _ work: @Sendable @escaping () async throws -> any Sendable
    ) {
        self.bindingName = bindingName
        self.sourceLocation = sourceLocation
        let storage = ResultStorage()
        self.storage = storage
        self.task = Task(executorPreference: ActionTaskExecutor.shared, priority: priority) {
            do {
                let value = try await work()
                storage.complete(.success(value))
                return value
            } catch {
                storage.complete(.failure(error))
                throw error
            }
        }
    }

    /// Create a future that is already resolved. Useful for literals and
    /// for the SynchronousAction fast-path which doesn't need a Task.
    public init(resolved value: any Sendable, bindingName: String = "_literal_") {
        self.bindingName = bindingName
        self.sourceLocation = nil
        let storage = ResultStorage()
        storage.complete(.success(value))
        self.storage = storage
        self.task = Task { value }
    }

    deinit {
        task.cancel()
    }

    /// Block the calling thread until the result is available, then return it.
    ///
    /// Safe to call from any thread, any number of times. After the first
    /// completion the result is memoized — subsequent calls return without
    /// blocking. Errors thrown by the underlying work are re-thrown.
    ///
    /// Phase 6 (Issue #55): if `ForceDiagnostics.warningBudgetSeconds` is
    /// > 0 and the wait exceeds that budget, a one-line warning is emitted
    /// to stderr identifying the binding and source location. Catches
    /// almost-deadlocks before they become hangs — invaluable on Linux
    /// where blocked-pthread stacks are unhelpful.
    public func force() throws -> any Sendable {
        let budget = ForceDiagnostics.effectiveBudget
        guard budget > 0, !storage.isResolved else {
            return try storage.wait()
        }
        return try storage.waitWithDiagnostics(
            budget: budget,
            bindingName: bindingName,
            sourceLocation: sourceLocation
        )
    }

    /// Async path for cooperative-pool callers (action task bodies, EventBus
    /// handlers, etc.). Awaits the underlying Task without blocking a pthread.
    /// Use this — not force() — from any `async` context.
    public func value() async throws -> any Sendable {
        return try await task.value
    }

    /// True once the result is memoized; force() will not block.
    public var isResolved: Bool {
        storage.isResolved
    }
}

// MARK: - ResultStorage

/// Thread-safe one-shot result holder with fan-out wait.
///
/// `enter()` is called in init. `complete(...)` writes the result and
/// `leave()`s the group exactly once. `wait()` uses `group.wait()`, which
/// (unlike DispatchSemaphore.signal) wakes all current and future waiters
/// once the count reaches zero — the right primitive for any-number-of-
/// consumers fan-out.
private final class ResultStorage: @unchecked Sendable {
    private let lock = NSLock()
    private let group = DispatchGroup()
    private var _result: Result<any Sendable, Error>?
    private var _isComplete = false

    init() {
        group.enter()
    }

    var isResolved: Bool {
        lock.withLock { _isComplete }
    }

    func complete(_ result: Result<any Sendable, Error>) {
        let shouldLeave: Bool = lock.withLock {
            guard !_isComplete else { return false }
            _result = result
            _isComplete = true
            return true
        }
        if shouldLeave {
            group.leave()
        }
    }

    func wait() throws -> any Sendable {
        group.wait()
        return try lock.withLock {
            guard let r = _result else {
                // Should be unreachable: group.wait() only returns after complete().
                throw AROFutureError.notResolved
            }
            return try r.get()
        }
    }

    /// Phase 6: waits with a budget; if the wait exceeds the budget,
    /// emits a single warning to stderr and continues waiting.
    func waitWithDiagnostics(
        budget: Double,
        bindingName: String,
        sourceLocation: String?
    ) throws -> any Sendable {
        let timeout = DispatchTime.now() + budget
        if group.wait(timeout: timeout) == .timedOut {
            let location = sourceLocation.map { " at \($0)" } ?? ""
            let msg = "[AROFuture] Slow force: '\(bindingName)'\(location) — waited >\(String(format: "%.2f", budget))s, still pending\n"
            ForceDiagnostics.warningHandler(msg)
            // Continue waiting indefinitely — the warning is informational,
            // not a deadline. A real deadlock will hang here, but the
            // warning above is the diagnostic the operator needs.
            group.wait()
        }
        return try lock.withLock {
            guard let r = _result else {
                throw AROFutureError.notResolved
            }
            return try r.get()
        }
    }
}

// MARK: - Errors

public enum AROFutureError: Error, CustomStringConvertible {
    case notResolved

    public var description: String {
        switch self {
        case .notResolved:
            return "AROFuture: storage signalled completion without a result (internal invariant violation)"
        }
    }
}

// MARK: - ForceDiagnostics (Issue #55, Phase 6)

/// Configuration for slow-force warnings.
///
/// Reads `ARO_FORCE_WARN_SECONDS` once at startup. Default budget: 5.0s.
/// Set to "0" or "off" to disable; any positive number to override.
/// Values are seconds (Double).
///
/// On exceeded budget, AROFuture.force() prints a single line to stderr
/// identifying the binding name and (if available) source location.
/// The wait then continues indefinitely — this is a diagnostic aid, not
/// a deadline. If a true deadlock follows, the warning is the breadcrumb
/// the operator needs to find the bug, especially on Linux where blocked-
/// pthread stack traces are unhelpful.
public enum ForceDiagnostics {

    public static let warningBudgetSeconds: Double = {
        if let raw = ProcessInfo.processInfo.environment["ARO_FORCE_WARN_SECONDS"] {
            switch raw.lowercased() {
            case "0", "off", "false", "no":
                return 0.0
            default:
                return Double(raw) ?? 0.0
            }
        }
        // Default: 5s slow-force warning budget. Set ARO_FORCE_WARN_SECONDS=0
        // to disable; any positive number to override.
        return 5.0
    }()

    /// Test-only override. Set to a non-nil value to use it instead of
    /// the env-derived value. Resets to nil after the calling test.
    /// Tests run serially; the unsafe annotation reflects that, not a
    /// production-safe contract.
    public nonisolated(unsafe) static var overrideBudget: Double? = nil

    static var effectiveBudget: Double {
        overrideBudget ?? warningBudgetSeconds
    }

    /// Hook for warning emission. Defaults to writing to stderr; tests
    /// substitute a capture closure. Not @Sendable because tests may need
    /// to mutate captured state — tests run serially, so this is fine in
    /// practice. Use only at process scope (not under contention).
    public nonisolated(unsafe) static var warningHandler: ((String) -> Void) = { msg in
        FileHandle.standardError.write(Data(msg.utf8))
    }
}

// MARK: - C ABI

/// Force a future and return its boxed value.
///
/// Returns NULL on error. Callers must NOT free the future via this call;
/// use `aro_future_release` to drop a reference. The returned `AROCValue*`
/// must be freed with `aro_value_free` as usual.
@_cdecl("aro_future_force")
public func aro_future_force(
    _ futurePtr: UnsafeMutableRawPointer?
) -> UnsafeMutableRawPointer? {
    guard let ptr = futurePtr else { return nil }
    let future = Unmanaged<AROFuture>.fromOpaque(ptr).takeUnretainedValue()
    do {
        let value = try future.force()
        let boxed = AROCValue(value: value)
        return UnsafeMutableRawPointer(Unmanaged.passRetained(boxed).toOpaque())
    } catch {
        return nil
    }
}

/// Drop one reference to the future. When the last reference is released,
/// the underlying Task is cancelled and the future is deallocated.
@_cdecl("aro_future_release")
public func aro_future_release(_ futurePtr: UnsafeMutableRawPointer?) {
    guard let ptr = futurePtr else { return }
    Unmanaged<AROFuture>.fromOpaque(ptr).release()
}

/// Bump the reference count. Returns the same pointer for caller convenience.
@_cdecl("aro_future_retain")
public func aro_future_retain(
    _ futurePtr: UnsafeMutableRawPointer?
) -> UnsafeMutableRawPointer? {
    guard let ptr = futurePtr else { return nil }
    _ = Unmanaged<AROFuture>.fromOpaque(ptr).retain()
    return ptr
}

/// Returns 1 if the future is already resolved (force() will not block), 0 otherwise.
@_cdecl("aro_future_is_ready")
public func aro_future_is_ready(_ futurePtr: UnsafeMutableRawPointer?) -> Int32 {
    guard let ptr = futurePtr else { return 0 }
    let future = Unmanaged<AROFuture>.fromOpaque(ptr).takeUnretainedValue()
    return future.isResolved ? 1 : 0
}

/// Create a future that is already resolved with the given C string.
/// Useful in tests and for literal pass-through.
@_cdecl("aro_future_create_resolved_string")
public func aro_future_create_resolved_string(
    _ valuePtr: UnsafePointer<CChar>?
) -> UnsafeMutableRawPointer {
    let str = valuePtr.map { String(cString: $0) } ?? ""
    let future = AROFuture(resolved: str)
    return UnsafeMutableRawPointer(Unmanaged.passRetained(future).toOpaque())
}
