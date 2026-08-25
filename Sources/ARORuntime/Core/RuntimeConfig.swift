// ============================================================
// RuntimeConfig.swift
// ARO Runtime - Centralised default constants
// ============================================================
//
// One home for the magic timeouts / sizes / ports that used to
// be declared inline at use sites. Tuning these without grep
// across the runtime — and making them discoverable in one
// place — is the goal of #328.
//
// Keep this surface narrow. Adding a new constant means it is
// genuinely tunable, not just a local internal limit. Constants
// stay public-let so they're cheap to read in hot paths.

import Foundation

/// Runtime-wide default values. Where a user-facing configuration
/// system needs to override one of these, the Configure action /
/// `aro.toml` reader copies it onto the relevant component at
/// startup; these are the fallbacks.
public enum RuntimeDefaults {
    /// Default deadline for waiting on a single event handler to
    /// finish. Per-publish overrides are still supported on
    /// `EventBus.publishAndWait(timeout:)`.
    public static let eventHandlerTimeout: TimeInterval = 10.0

    /// Default deadline for invoking a Python plugin's subprocess
    /// action. Long-running plugins should declare a higher value
    /// in their `plugin.yaml` (follow-up).
    public static let pythonPluginTimeout: TimeInterval = 30.0

    /// Maximum number of distinct URLs the crawl-style visited
    /// dedup keeps in memory before evicting the oldest. The
    /// BoundedSet's eviction is amortised O(1) so the cost is
    /// purely the memory budget.
    public static let visitedURLStoreMaxSize: Int = 100_000

    /// How many elements a stream's producer may run ahead of its consumer
    /// (ARO-0088 §6). Small on purpose: the win is overlapping one element's
    /// read/parse with the previous one's processing, and a deep buffer only
    /// trades memory for latency the consumer cannot use. Override with
    /// `ARO_STREAM_PREFETCH`.
    public nonisolated(unsafe) static var streamPrefetchCapacity: Int = {
        if let raw = ProcessInfo.processInfo.environment["ARO_STREAM_PREFETCH"],
           let n = Int(raw), n > 0 { return n }
        return 2
    }()

    /// How many user-defined action frames may be live at once before the
    /// runtime stops and says so (ARO-0081, GitLab #473).
    ///
    /// This is a diagnostic backstop, not the recursion model. Recursion in
    /// tail position reuses its frame and is not counted here at all, so it has
    /// no ceiling; recursion that must keep its frames is bounded by memory,
    /// and this budget exists so that hitting that bound produces an ARO error
    /// naming the call chain instead of an OOM kill or a `SIGSEGV` with no
    /// output. The default is far above any legitimate call depth and roughly
    /// an order of magnitude below what exhausts a developer machine.
    ///
    /// Override with `ARO_MAX_CALL_DEPTH`; `0` disables the check entirely.
    public nonisolated(unsafe) static var maxUserActionDepth: Int = {
        if let raw = ProcessInfo.processInfo.environment["ARO_MAX_CALL_DEPTH"],
           let n = Int(raw), n >= 0 { return n }
        return 50_000
    }()

    // MARK: - Observer dispatch backpressure (#227)

    /// When true, `Store` publishes `RepositoryChangedEvent` fire-and-forget
    /// through the EventBus's bounded observer worker pool instead of awaiting
    /// the whole observer chain (`publishAndTrack`). This frees the storing
    /// handler's locals immediately — the dominant memory cost in recursive
    /// fan-out crawls (observer → store → observer …) — while a fixed worker
    /// pool caps how many observer bodies run at once so memory stays bounded.
    ///
    /// **Off by default**: it changes `store → observer side-effect → next
    /// statement` ordering (Store no longer awaits observer completion), so
    /// programs that rely on that ordering must opt in. Enable with the
    /// `ARO_ASYNC_OBSERVERS` environment variable (`1`/`true`/`yes`).
    public nonisolated(unsafe) static var asyncObserverDispatch: Bool = {
        guard let raw = ProcessInfo.processInfo.environment["ARO_ASYNC_OBSERVERS"]?
            .lowercased() else { return false }
        return raw == "1" || raw == "true" || raw == "yes"
    }()

    /// Number of persistent workers that drain the bounded observer queue when
    /// `asyncObserverDispatch` is on. Sized to the machine so lightweight
    /// observers stay responsive while heavy ones (HTTP fetch + parse) can't
    /// all run at once. Overridable via `ARO_OBSERVER_WORKERS`.
    public nonisolated(unsafe) static var observerWorkerCount: Int = {
        if let raw = ProcessInfo.processInfo.environment["ARO_OBSERVER_WORKERS"],
           let n = Int(raw), n > 0 { return n }
        return max(4, ProcessInfo.processInfo.activeProcessorCount * 2)
    }()

    /// Ceiling on the number of queued-but-not-yet-dispatched observer work
    /// items. When the queue is full, producers (the fire-and-forget publish
    /// task, never a pool worker) suspend until a slot frees, bounding the
    /// queue's memory. Overridable via `ARO_OBSERVER_QUEUE_CAPACITY`.
    public nonisolated(unsafe) static var observerQueueCapacity: Int = {
        if let raw = ProcessInfo.processInfo.environment["ARO_OBSERVER_QUEUE_CAPACITY"],
           let n = Int(raw), n > 0 { return n }
        return 4096
    }()

    // MARK: - Request body limits (GitLab #477)

    /// How many bytes of a request body may become a value in memory.
    ///
    /// This is a *materialization* limit, not a transport limit: a route whose
    /// feature set only moves its body (to a file, a socket, the response) is
    /// not bounded by it, because nothing accumulates. It applies wherever a
    /// body has to exist as a whole — a field access, a parse, a repository
    /// store — and it exists because before #477 the server accumulated an
    /// entire body with no ceiling at all, so one connection could exhaust the
    /// process.
    ///
    /// A route may raise or lower it in the contract with `x-aro-max-body`.
    /// This is the default for routes that declare nothing. Override the
    /// default with `ARO_MAX_BODY` (`1MB`, `512KB`, `2097152`) or, from ARO,
    /// `Configure the <http-server: max-body> with "1MB".`
    public nonisolated(unsafe) static var maxMaterializedBody: Int = {
        if let raw = ProcessInfo.processInfo.environment["ARO_MAX_BODY"],
           let n = ByteSize.parse(raw), n > 0 { return n }
        return 1_000_000
    }()

    /// Chunk size for streamed request bodies and streamed file writes.
    /// Matches `AROFileSystemService.readChunks`, so a body streamed from a
    /// socket to a file moves in one buffer size end to end.
    public nonisolated(unsafe) static var bodyChunkSize: Int = {
        if let raw = ProcessInfo.processInfo.environment["ARO_BODY_CHUNK_SIZE"],
           let n = ByteSize.parse(raw), n > 0 { return n }
        return 65_536
    }()
}
