// ============================================================
// OffThePool.swift
// ARO Runtime Tests - blocking work must not hold a cooperative thread
// ============================================================
//
// Swift Testing runs tests on the cooperative pool, whose width is the core
// count — three on GitHub's macOS runner. A test that blocks (`waitUntilExit`,
// a semaphore, `Thread.sleep`, a synchronous subprocess run) holds one of those
// threads for as long as it blocks, and every other test in the process waits
// for it. A few at once stalled the whole run, and the tests that measure time
// — debounces, `Sleep 250ms` — failed for what their neighbours were doing.

import Foundation

/// Run `body` on a thread of its own while the calling test suspends.
func offThePool<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        Thread { continuation.resume(with: Result { try body() }) }.start()
    }
}

/// `offThePool` for a body that cannot fail.
func offThePool<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        Thread { continuation.resume(returning: body()) }.start()
    }
}
