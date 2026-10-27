// ============================================================
// HandlerFailureLog.swift
// ARO Runtime — did any event handler fail? (GitLab #816)
// ============================================================
//
// `aro run Examples/EventReplay` printed three handler failures to stderr and
// exited **0**. The example's `expected.txt` asserted only its banner, so CI
// was green on an application whose every handler threw.
//
// A handler failure is recoverable — the application keeps running, and that
// is deliberate, since one bad event should not take a server down. But
// "recoverable" is a statement about the *process*, not about the *run*: a
// batch that processed nothing because every handler threw did not succeed,
// and `aro run` is how a script finds that out.
//
// So the two are separated. The event bus keeps publishing
// `ErrorOccurredEvent(recoverable: true)` and the application keeps going;
// this records that it happened, and `aro run` reads it once at the end to
// decide its exit code.

import Foundation

public enum HandlerFailureLog {

    private static let lock = NSLock()
    nonisolated(unsafe) private static var failures: [(featureSet: String, error: String)] = []

    /// Record a handler that threw.
    public static func record(featureSet: String, error: String) {
        lock.lock()
        defer { lock.unlock() }
        failures.append((featureSet, error))
    }

    /// How many handlers have failed in this process.
    public static var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return failures.count
    }

    /// The feature sets that failed, each named once, in first-failure order.
    public static var failedFeatureSets: [String] {
        lock.lock()
        defer { lock.unlock() }
        var seen: Set<String> = []
        return failures.compactMap { seen.insert($0.featureSet).inserted ? $0.featureSet : nil }
    }

    /// Forget everything. For tests, and for a REPL session that has
    /// reported one run and is starting another.
    public static func reset() {
        lock.lock()
        defer { lock.unlock() }
        failures.removeAll()
    }
}
