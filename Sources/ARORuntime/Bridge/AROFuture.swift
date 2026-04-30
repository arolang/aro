// ============================================================
// AROFuture.swift
// ARORuntime - Lazy Action Result Handle (Issue #55, Phase 1)
// ============================================================
//
// AROFuture is the foundation for async-by-default action execution.
// Every action call (under ARO_LAZY_ACTIONS=1) returns an AROFuture
// instead of an eager value. The underlying Task<any Sendable, Error>
// runs on the cooperative pool. Forcing the future blocks exactly once,
// at boundaries where a concrete value must escape (Return, Log, branch
// conditions, feature-set exit, first-handler-read on emitted events).
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

    /// Create a future that runs `work` on the cooperative pool.
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
        self.task = Task(priority: priority) {
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
    public func force() throws -> any Sendable {
        return try storage.wait()
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
