// ============================================================
// EventuallyPoll.swift
// SOLARO tests — waiting for a thing to happen, not for a clock
// GitLab #849
// ============================================================
//
// A test that sleeps for a fixed interval and then asserts is asserting two
// things: that the mechanism works, and that the machine was fast enough. The
// second one fails under full-suite parallel load while passing in isolation,
// and a test that fails for reasons unrelated to its subject teaches people to
// re-run rather than read — which is the worst possible habit to teach around
// the save debounce and the external-change watcher, where a real regression
// is most expensive to miss (GitLab #536, #759).
//
// Polling with a generous ceiling asserts only the first thing. It costs a
// single interval on an idle machine and tolerates a loaded one, and it is the
// shape `SigningRescanTests` and `LiveEventStreamTeardownTests` already use.

import Foundation

/// Wait until `condition` holds, or the ceiling elapses.
///
/// The ceiling is deliberately far above any plausible real latency: if it is
/// ever reached, the mechanism is broken, not slow. Returns whether the
/// condition held, so the caller still makes the assertion — a helper that
/// asserted for you would report the failure at this file's line rather than
/// at the test's.
@MainActor
func eventually(
    timeout: Duration = .seconds(2),
    interval: Duration = .milliseconds(20),
    _ condition: () -> Bool
) async -> Bool {
    if condition() { return true }
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        try? await Task.sleep(for: interval)
        if condition() { return true }
    }
    return condition()
}

/// The same, for a condition that reads from disk and may throw.
///
/// A read that fails mid-write is a "not yet", not a failure: an atomic
/// replace has a moment where the path resolves to neither file.
@MainActor
func eventually(
    timeout: Duration = .seconds(2),
    interval: Duration = .milliseconds(20),
    _ condition: () throws -> Bool
) async -> Bool {
    await eventually(timeout: timeout, interval: interval) {
        (try? condition()) ?? false
    }
}
