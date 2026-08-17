// ============================================================
// DeepCallStack.swift
// ARO Runtime - Native stack headroom for deeply nested calls
// ============================================================

import Foundation

/// Keeps deeply nested *native* call chains from running out of stack.
///
/// A user-defined action in a compiled binary is a real C function called on
/// the calling thread, so every nesting level costs native stack — around 5 KB
/// once the dispatch bridge is counted. On an 8 MB stack that is a wall at
/// roughly 1 500 frames, and hitting it is a `SIGSEGV` with no diagnostics
/// (GitLab #473).
///
/// Rather than cap recursion, hand it a fresh stack: after
/// `framesPerThread` nested bodies on one thread, the next one runs on a new
/// thread with a large stack, and the thread below it blocks until that
/// returns. Depth then costs one thread per `framesPerThread` levels instead of
/// one per level — 100 000 deep is 100 threads, which the OS handles without
/// complaint, and each thread's stack is committed lazily by the VM system.
///
/// The interpreter does not need this: its call frames are `async`, so they
/// live on the heap already.
public enum DeepCallStack {
    /// Nested bodies per thread. At ~5 KB of stack per frame this uses about
    /// 5 MB of the 32 MB stack below — enough headroom for the deepest single
    /// action body (expression evaluation, JSON parsing) to run at any level.
    public static let framesPerThread = 1000

    /// Stack size for each continuation thread. Reserved address space, not
    /// resident memory.
    public static let threadStackBytes = 32 * 1024 * 1024

    private static let depthKey = "aro.deepCallStack.depth"

    /// Run `body`, moving to a fresh large-stack thread when this thread has
    /// taken as many nested frames as it should.
    public static func run<T>(_ body: @escaping @Sendable () throws -> T) throws -> T {
        let storage = Thread.current.threadDictionary
        let depth = (storage[depthKey] as? Int) ?? 0

        if depth < framesPerThread {
            storage[depthKey] = depth + 1
            defer { storage[depthKey] = depth }
            return try body()
        }

        let box = TransferBox<T>()
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            // The new thread starts its own budget at one — this frame.
            Thread.current.threadDictionary[depthKey] = 1
            do {
                box.value = try body()
            } catch {
                box.error = error
            }
            done.signal()
        }
        thread.stackSize = threadStackBytes
        thread.start()
        // The borrow ends before this returns, which is what makes handing the
        // box across threads safe despite the unchecked conformance.
        done.wait()

        if let error = box.error { throw error }
        guard let value = box.value else {
            throw DeepCallStackError.continuationProducedNoValue
        }
        return value
    }
}

public enum DeepCallStackError: Error, CustomStringConvertible {
    case continuationProducedNoValue

    public var description: String {
        switch self {
        case .continuationProducedNoValue:
            return "deep-call continuation thread finished without a result"
        }
    }
}

/// Single-value box used to ferry a result out of a continuation thread.
private final class TransferBox<T>: @unchecked Sendable {
    var value: T?
    var error: Error?
    init() {}
}
