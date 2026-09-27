// ============================================================
// ApplicationLimitsTests.swift
// ARO Runtime — application-wide concurrency ceiling and rate limits
// ARO-0088 §10a, GitLab #862
// ============================================================
//
// `with <concurrency: N>` bounds one loop. It never bounded the application:
// a handler woken by an `Emit` inside that loop ran outside the count.

import Foundation
import Testing
@testable import ARORuntime
@testable import AROParser

// Serialized: the ceiling and the rate are process-wide settings, which is
// the point of them. Two of these tests writing the global at once would be
// testing the test runner.
@Suite("Application limits (#862)", .serialized)
struct ApplicationLimitsTests {

    // MARK: - Rate specification

    @Test("a rate is written the way a quota is documented")
    func rateSpellings() {
        #expect(RateSpec.parse("10/s") == RateSpec(permits: 10, interval: 1))
        #expect(RateSpec.parse("10/sec") == RateSpec(permits: 10, interval: 1))
        #expect(RateSpec.parse("100/minute") == RateSpec(permits: 100, interval: 60))
        #expect(RateSpec.parse("2/h") == RateSpec(permits: 2, interval: 3600))
    }

    @Test("a multiplier is not the same shape as the scaled-up rate")
    func rateMultiplier() {
        // 5 per 2 seconds and 150 per minute have the same long-run average
        // and different burst behaviour, so the bucket has to keep them apart.
        let burst = RateSpec.parse("5/2s")
        #expect(burst == RateSpec(permits: 5, interval: 2))
        #expect(burst != RateSpec.parse("150/minute"))
    }

    @Test("nonsense is rejected rather than guessed at")
    func badRatesAreNil() {
        #expect(RateSpec.parse("10") == nil)
        #expect(RateSpec.parse("10/fortnight") == nil)
        #expect(RateSpec.parse("0/s") == nil)
        #expect(RateSpec.parse("ten/s") == nil)
        #expect(RateSpec.parse("") == nil)
    }

    // MARK: - The gate

    @Test("a gate admits at most `limit` at once")
    func gateBoundsConcurrency() async {
        let gate = ConcurrencyGate(limit: 2)
        let peak = PeakCounter()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    await gate.acquire()
                    await peak.enter()
                    try? await Task.sleep(nanoseconds: 20_000_000)
                    await peak.leave()
                    await gate.release()
                }
            }
        }
        #expect(await peak.highWater <= 2)
        #expect(await peak.highWater >= 1)
    }

    @Test("a limit of 0 is no ceiling at all")
    func zeroMeansUnlimited() async {
        let gate = ConcurrencyGate(limit: 0)
        for _ in 0..<50 { await gate.acquire() }
        #expect(await gate.currentInFlight == 0)
    }

    @Test("raising the ceiling admits the queue")
    func raisingLimitReleasesWaiters() async {
        let gate = ConcurrencyGate(limit: 1)
        await gate.acquire()

        let waiting = Task { await gate.acquire() }
        try? await Task.sleep(nanoseconds: 10_000_000)
        await gate.setLimit(4)
        await waiting.value            // would hang at limit 1

        #expect(await gate.currentLimit == 4)
    }

    // MARK: - Re-entrancy, which is what makes the ceiling deadlock-free

    @Test("work inside a slot does not wait for a second one")
    func nestedWorkInheritsTheSlot() async throws {
        // Without this, a handler holding the only slot and awaiting its own
        // `parallel for each` would be waiting for a slot it is itself
        // holding. The nesting rule is the whole reason a ceiling of 1 is safe.
        ApplicationLimits.applicationConcurrency = 1
        defer { ApplicationLimits.applicationConcurrency = 0 }

        let reached = await ApplicationLimits.withSlot { () -> Bool in
            await ApplicationLimits.withSlot { true }
        }
        #expect(reached)
    }

    @Test("a fresh unit of work takes its own slot")
    func topLevelWorkIsCounted() async {
        ApplicationLimits.applicationConcurrency = 2
        defer { ApplicationLimits.applicationConcurrency = 0 }

        let peak = PeakCounter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    await ApplicationLimits.withSlot {
                        await peak.enter()
                        try? await Task.sleep(nanoseconds: 20_000_000)
                        await peak.leave()
                    }
                }
            }
        }
        #expect(await peak.highWater <= 2)
    }

    // MARK: - The token bucket

    @Test("a rate paces work rather than failing it")
    func rateLimiterWaits() async {
        // Three permits per 100ms, six acquisitions: the last three wait for
        // the bucket to refill. Nothing is rejected — a limit exists so that
        // work is paced, and there is no ARO spelling for "fail when busy".
        let limiter = RateLimiter(permits: 3, interval: 0.1)
        let started = Date()
        for _ in 0..<6 { await limiter.acquire() }
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed >= 0.08)
    }

    @Test("an unlimited bucket never waits")
    func zeroPermitsIsUnlimited() async {
        let limiter = RateLimiter(permits: 0, interval: 1)
        let started = Date()
        for _ in 0..<100 { await limiter.acquire() }
        #expect(Date().timeIntervalSince(started) < 0.5)
    }

    // MARK: - The Configure surface

    @Test("Configure writes the application ceiling")
    func configureApplicationConcurrency() throws {
        defer { ApplicationLimits.applicationConcurrency = 0 }
        let applied = try apply(base: "application", key: "concurrency", value: 8)
        #expect((applied as? [String: any Sendable])?["concurrency"] as? Int == 8)
        #expect(ApplicationLimits.applicationConcurrency == 8)
    }

    @Test("Configure writes the outbound HTTP rate")
    func configureHTTPRate() throws {
        defer { ApplicationLimits.httpRate = nil }
        _ = try apply(base: "http-client", key: "rate", value: "10/s")
        #expect(ApplicationLimits.httpRate == RateSpec(permits: 10, interval: 1))
    }

    @Test("Configure writes the outbound HTTP ceiling")
    func configureHTTPConcurrency() throws {
        defer { ApplicationLimits.httpConcurrency = 8 }
        _ = try apply(base: "http-client", key: "concurrency", value: 4)
        #expect(ApplicationLimits.httpConcurrency == 4)
    }

    @Test("a value that is not a rate is an error naming what one looks like")
    func badRateIsReported() {
        #expect(throws: (any Error).self) {
            _ = try apply(base: "http-client", key: "rate", value: "soon")
        }
    }

    @Test("a value that is not a number is an error")
    func badConcurrencyIsReported() {
        #expect(throws: (any Error).self) {
            _ = try apply(base: "application", key: "concurrency", value: "lots")
        }
    }

    @Test("an unrelated Configure still falls through to entity update")
    func unrelatedConfigureIsNotALimit() throws {
        let applied = try apply(base: "validation", key: "timeout", value: 30)
        #expect(applied == nil)
    }

    private func apply(base: String, key: String, value: any Sendable) throws -> (any Sendable)? {
        let span = SourceSpan(at: SourceLocation())
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("_literal_", value: value)
        return try ConfigurableSettings.applyLimitSetting(
            result: ResultDescriptor(base: base, specifiers: [key], span: span),
            object: ObjectDescriptor(preposition: .with, base: "value",
                                     specifiers: [], span: span),
            context: context)
    }
}

/// Records the highest number of tasks inside the guarded region at once.
private actor PeakCounter {
    private var current = 0
    private(set) var highWater = 0

    func enter() {
        current += 1
        highWater = max(highWater, current)
    }

    func leave() {
        current -= 1
    }
}
