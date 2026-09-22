// ============================================================
// ConcurrencyLimits.swift
// ARO Runtime - Application-wide concurrency ceiling and rate limits
// ARO-0088 §10a (GitLab #862)
// ============================================================
//
// `parallel for each … with <concurrency: N>` bounds one loop. It does not
// bound the application: a handler woken by an `Emit` inside that loop runs
// on its own, outside the loop's count, so the real concurrency of a program
// had no ceiling at all. The workaround was `Sleep`, which is a delay rather
// than a limit and is wrong in both directions — too slow when the service is
// idle, still too fast when it is not.
//
// Two separate things live here, because they answer different questions:
//
//   * a **concurrency ceiling** — how many units of work may be in flight
//   * a **rate limit** — how many may *start* per interval
//
// One request at a time still exceeds a per-minute quota, so a ceiling cannot
// express a rate; and a rate says nothing about how many may pile up at once.

import Foundation
import Synchronization

// MARK: - Concurrency gate

/// A counting semaphore with FIFO hand-off, and no busy-wait.
///
/// `acquire()` suspends until a slot is free; `release()` hands the slot
/// directly to the longest-waiting acquirer rather than decrementing and
/// letting it race, so a saturated gate admits work in arrival order.
///
/// A `limit` of `0` means unlimited and costs one actor hop.
public actor ConcurrencyGate {
    private var limit: Int
    private var inFlight: Int = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(limit: Int) {
        self.limit = max(0, limit)
    }

    /// Sync the ceiling and take a slot in one actor hop.
    ///
    /// The limit is carried in from the caller because `Configure` runs
    /// synchronously, in the middle of a statement, and cannot await an actor.
    /// It writes a lock-protected box instead; this is where the box reaches
    /// the gate, on the hop the caller was making anyway.
    public func acquire(limit newLimit: Int) async {
        setLimit(newLimit)
        await acquire()
    }

    /// Raise or lower the ceiling at run time.
    ///
    /// Raising admits queued waiters immediately. Lowering never revokes a
    /// slot already granted — the count drains to the new limit as work
    /// finishes, because interrupting work that is already running would be a
    /// different and much less useful promise.
    public func setLimit(_ newLimit: Int) {
        guard newLimit != limit else { return }
        limit = max(0, newLimit)
        while limit > 0, inFlight < limit, !waiters.isEmpty {
            let next = waiters.removeFirst()
            inFlight += 1
            next.resume()
        }
        if limit == 0 {
            let queued = waiters
            waiters.removeAll()
            for waiter in queued { waiter.resume() }
        }
    }

    public var currentLimit: Int { limit }
    public var currentInFlight: Int { inFlight }

    public func acquire() async {
        if limit == 0 { return }
        if inFlight < limit {
            inFlight += 1
            return
        }
        await withCheckedContinuation { cont in
            waiters.append(cont)
        }
        // On resume the slot was transferred by the releaser; `inFlight`
        // stays at the limit rather than dipping and re-incrementing.
    }

    public func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            inFlight = max(0, inFlight - 1)
        }
    }
}

// MARK: - Rate limiter

/// A token bucket: `permits` tokens per `interval`, refilled continuously.
///
/// Continuous refill rather than a fixed window, because a window lets twice
/// the quota through across its boundary — 10 requests at 0:59 and 10 more at
/// 1:01 is 20 in two seconds against a "10 per minute" limit.
///
/// The bucket's capacity is its permit count, so a program that has been idle
/// may burst up to one full interval's worth and is then paced.
public actor RateLimiter {
    private var permits: Double
    private var interval: TimeInterval
    private var tokens: Double
    private var lastRefill: Date

    public init(permits: Double, interval: TimeInterval) {
        self.permits = max(0, permits)
        self.interval = max(0.000_001, interval)
        self.tokens = max(0, permits)
        self.lastRefill = Date()
    }

    /// Reconfigure the bucket. The token count is clamped into the new
    /// capacity so lowering a limit takes effect on the next acquisition
    /// rather than after the old bucket has drained.
    public func configure(permits: Double, interval: TimeInterval) {
        self.permits = max(0, permits)
        self.interval = max(0.000_001, interval)
        self.tokens = min(tokens, self.permits)
        self.lastRefill = Date()
    }

    /// Permits per second, for reporting.
    public var ratePerSecond: Double { permits / interval }

    /// Reconfigure, then wait for a token, in one actor hop.
    public func acquire(_ spec: RateSpec?) async {
        if let spec {
            if spec.permits != permits || spec.interval != interval {
                configure(permits: spec.permits, interval: spec.interval)
            }
        } else if permits != 0 {
            configure(permits: 0, interval: 1)
        }
        await acquire()
    }

    /// Wait until a token is available, then take it.
    ///
    /// Waiting, not failing: a limit exists so that work is paced, and a
    /// program that wanted the request to fail would have said so. The whole
    /// call is inside the actor, so acquirers are served in arrival order.
    public func acquire() async {
        guard permits > 0 else { return }
        while true {
            refill()
            if tokens >= 1 {
                tokens -= 1
                return
            }
            // Time until the next whole token, given the refill rate.
            let perSecond = permits / interval
            let seconds = (1 - tokens) / perSecond
            let nanos = UInt64(max(0.001, seconds) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
        }
    }

    private func refill() {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastRefill)
        guard elapsed > 0 else { return }
        tokens = min(permits, tokens + elapsed * (permits / interval))
        lastRefill = now
    }
}

// MARK: - Rate specification

/// A rate written the way a service documents its quota: `"10/s"`,
/// `"100/minute"`, `"5/2s"`.
public struct RateSpec: Sendable, Equatable {
    public let permits: Double
    public let interval: TimeInterval

    public init(permits: Double, interval: TimeInterval) {
        self.permits = permits
        self.interval = interval
    }

    /// Parse `"<count>/<[multiplier]unit>"`.
    ///
    /// Units are seconds, minutes and hours, each spelled long or short.
    /// The optional multiplier covers the quotas that are not per-one-unit:
    /// `"5/2s"` is five per two seconds, which is not the same shape as
    /// `"150/minute"` even where the long-run average matches.
    public static func parse(_ raw: String) -> RateSpec? {
        let text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard let slash = text.firstIndex(of: "/") else { return nil }
        let countPart = String(text[..<slash]).trimmingCharacters(in: .whitespaces)
        var unitPart = String(text[text.index(after: slash)...]).trimmingCharacters(in: .whitespaces)
        guard let count = Double(countPart), count > 0 else { return nil }

        var multiplier: Double = 1
        let digits = unitPart.prefix { $0.isNumber || $0 == "." }
        if !digits.isEmpty {
            guard let parsed = Double(digits), parsed > 0 else { return nil }
            multiplier = parsed
            unitPart = String(unitPart.dropFirst(digits.count))
        }

        let seconds: TimeInterval
        switch unitPart {
        case "s", "sec", "secs", "second", "seconds": seconds = 1
        case "m", "min", "mins", "minute", "minutes": seconds = 60
        case "h", "hr", "hrs", "hour", "hours": seconds = 3600
        default: return nil
        }
        return RateSpec(permits: count, interval: seconds * multiplier)
    }
}

// MARK: - Application-wide limits

/// The application's concurrency ceiling and the service rate limits, in one
/// place so `Configure` and the environment write to the same thing.
public enum ApplicationLimits {

    /// True while the current task already holds an application slot.
    ///
    /// This is what makes the ceiling deadlock-free. A unit of work that holds
    /// a slot and then spawns more work — a handler running a `parallel for
    /// each`, an observer storing a row — would otherwise wait for a slot held
    /// by something waiting for it. Nested work runs **under its parent's
    /// slot** and is bounded by its own loop's `with <concurrency: N>`; the
    /// ceiling counts independently triggered units, not every task.
    @TaskLocal public static var holdsSlot: Bool = false

    /// The gate every top-level unit of work passes through.
    public static let applicationGate = ConcurrencyGate(limit: 0)

    /// The outbound HTTP token bucket.
    public static let httpRateLimiter = RateLimiter(permits: 0, interval: 1)

    /// The gate on concurrent outbound HTTP fetches. Separate from the
    /// application ceiling because it counts a different thing — sockets and
    /// response buffers, not units of work — and because a crawler wants both:
    /// eight units of work, two of which may be talking to the same host.
    public static let httpGate: ConcurrencyGate = {
        let raw = ProcessInfo.processInfo.environment["ARO_HTTP_CONCURRENCY"]
        return ConcurrencyGate(limit: raw.flatMap(Int.init) ?? 8)
    }()

    /// Lock over the two settings below. `Configure` runs synchronously inside
    /// a statement and cannot await an actor, so the settings live here and
    /// reach the actors on the next hop through them.
    private static let settingsLock = NSLock()

    /// How many independently triggered units of work may run at once.
    ///
    /// `0` — the default — is unlimited, which is what the runtime did before
    /// GitLab #862. Set it with `Configure the <application: concurrency>
    /// with 8.` or `ARO_CONCURRENCY`. Stored atomically — see
    /// `concurrencyValue`.

    /// Outbound HTTP rate limit; `nil` is unlimited.
    /// `Configure the <http-client: rate> with "10/s".` or `ARO_HTTP_RATE`.
    nonisolated(unsafe) private static var _httpRate: RateSpec? = {
        ProcessInfo.processInfo.environment["ARO_HTTP_RATE"].flatMap(RateSpec.parse)
    }()

    /// The ceiling, readable without taking a lock.
    ///
    /// `withSlot` runs on **every** feature-set execution, which for a
    /// recursive user-defined action is once per frame. Reading the setting
    /// through `settingsLock` put an uncontended-but-real mutex acquire in
    /// that path and made deep recursion measurably slower — enough that
    /// `Examples/RecursiveActions` went from 2s to a CI timeout. An atomic
    /// read costs nothing when no ceiling is configured, which is the case
    /// almost every program is in.
    private static let concurrencyValue = Atomic<Int>(
        ProcessInfo.processInfo.environment["ARO_CONCURRENCY"].flatMap(Int.init) ?? 0
    )

    public static var applicationConcurrency: Int {
        get { concurrencyValue.load(ordering: .relaxed) }
        set { concurrencyValue.store(max(0, newValue), ordering: .relaxed) }
    }

    /// How many outbound HTTP fetches may be in flight. Defaults to 8;
    /// `ARO_HTTP_CONCURRENCY` or `Configure the <http-client: concurrency>`.
    nonisolated(unsafe) private static var _httpConcurrency: Int = {
        ProcessInfo.processInfo.environment["ARO_HTTP_CONCURRENCY"].flatMap(Int.init) ?? 8
    }()

    public static var httpConcurrency: Int {
        get { settingsLock.lock(); defer { settingsLock.unlock() }; return _httpConcurrency }
        set { settingsLock.lock(); defer { settingsLock.unlock() }; _httpConcurrency = max(0, newValue) }
    }

    public static var httpRate: RateSpec? {
        get { settingsLock.lock(); defer { settingsLock.unlock() }; return _httpRate }
        set { settingsLock.lock(); defer { settingsLock.unlock() }; _httpRate = newValue }
    }

    /// Run `body` under the application ceiling.
    ///
    /// A no-op when no ceiling is configured, and a no-op when the caller
    /// already holds a slot — see `holdsSlot`.
    public static func withSlot<T: Sendable>(
        _ body: @Sendable () async throws -> T
    ) async rethrows -> T {
        if holdsSlot { return try await body() }
        let limit = applicationConcurrency
        if limit == 0 { return try await body() }
        await applicationGate.acquire(limit: limit)
        do {
            let value = try await $holdsSlot.withValue(true) { try await body() }
            // Released before the caller continues, not in a trailing task:
            // a slot that outlives the work it bounded is a ceiling that
            // drifts, and the drift is invisible.
            await applicationGate.release()
            return value
        } catch {
            await applicationGate.release()
            throw error
        }
    }

    /// Apply the configured outbound HTTP rate limit, if any.
    public static func awaitHTTPRateAllowance() async {
        let spec = httpRate
        if spec == nil, await httpRateLimiter.ratePerSecond == 0 { return }
        await httpRateLimiter.acquire(spec)
    }
}
