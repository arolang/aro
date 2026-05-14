// ============================================================
// EventBus.swift
// ARO Runtime - Event Bus
// ============================================================

import Foundation

/// Default timeout in seconds for waiting on event handlers to complete
public let AROEventHandlerDefaultTimeout: TimeInterval = 10.0

/// Synchronously-mutable counter for fire-and-forget publishes that have
/// been initiated but whose `publishInternal` Task has not yet incremented
/// the actor's `inFlightHandlers`. Without this, `publish()` can return,
/// the calling handler can finish, and `awaitPendingEvents()` can see
/// `inFlightHandlers == 0` and let the runtime exit — all before the
/// fire-and-forget Task even gets scheduled. NSLock + Int is fine: the
/// critical section is one arithmetic op and contention is low.
fileprivate final class EventBusPendingPublishCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count: Int = 0

    func increment() {
        lock.lock(); count += 1; lock.unlock()
    }

    /// Decrement; return true iff the counter reached zero.
    @discardableResult
    func decrement() -> Bool {
        lock.lock()
        count -= 1
        let zero = (count == 0)
        lock.unlock()
        return zero
    }

    var isZero: Bool {
        lock.lock(); defer { lock.unlock() }
        return count == 0
    }
}

/// Result box for synchronous bridge methods
/// Semaphore ensures no actual data races occur
private final class EventBusResultBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

// MARK: - Subscription Store

/// Private actor that owns subscription storage.
/// Swift's actor model provides static data-race safety and fair scheduling,
/// replacing the previous nonisolated(unsafe) + NSLock pattern.
private actor SubscriptionStore {
    var subscriptionsByType: [String: [EventBus.Subscription]] = [:]
    var wildcardSubscriptions: [EventBus.Subscription] = []
    /// Side-map from subscription ID to its event type (or "*" for wildcard).
    /// Allows remove() to locate the correct bucket in O(1).
    private var idToType: [UUID: String] = [:]

    func add(_ subscription: EventBus.Subscription) {
        idToType[subscription.id] = subscription.eventType
        if subscription.eventType == "*" {
            wildcardSubscriptions.append(subscription)
        } else {
            subscriptionsByType[subscription.eventType, default: []].append(subscription)
        }
    }

    func remove(_ id: UUID) {
        guard let eventType = idToType.removeValue(forKey: id) else { return }
        if eventType == "*" {
            wildcardSubscriptions.removeAll { $0.id == id }
        } else {
            subscriptionsByType[eventType]?.removeAll { $0.id == id }
            if subscriptionsByType[eventType]?.isEmpty == true {
                subscriptionsByType.removeValue(forKey: eventType)
            }
        }
    }

    func removeAll() {
        wildcardSubscriptions.removeAll()
        subscriptionsByType.removeAll()
        idToType.removeAll()
    }

    func matching(for eventType: String) -> [EventBus.Subscription] {
        let typeSubscriptions = subscriptionsByType[eventType] ?? []
        return typeSubscriptions + wildcardSubscriptions
    }

    var count: Int {
        wildcardSubscriptions.count + subscriptionsByType.values.reduce(0) { $0 + $1.count }
    }
}

// MARK: - Event Bus

/// Central event bus for publishing and subscribing to runtime events
///
/// The EventBus provides a decoupled communication mechanism between
/// components in the ARO runtime. Events can be published from
/// actions and feature sets, and handled by registered subscribers.
///
/// Thread-safety is provided by Swift's actor model.
public actor EventBus {
    /// Subscription handler type
    public typealias EventHandler = @Sendable (any RuntimeEvent) async -> Void

    /// Subscription entry
    public struct Subscription: Sendable {
        let id: UUID
        let eventType: String
        let handler: EventHandler
    }

    /// Actor-isolated subscription storage — replaces nonisolated(unsafe) + NSLock
    private let store = SubscriptionStore()

    /// Async stream continuations for stream-based subscriptions
    private var continuations: [UUID: AsyncStream<any RuntimeEvent>.Continuation] = [:]

    /// In-flight event handler counter
    private var inFlightHandlers: Int = 0

    /// Active event sources (HTTP servers, file monitors, socket servers)
    /// These are long-lived services that can generate events asynchronously
    private var activeEventSources: Int = 0

    /// Tracks fire-and-forget publishes from the moment `publish()` is called
    /// until `publishInternal()` has finished registering subscriptions in
    /// `inFlightHandlers`. Both must be zero before `awaitPendingEvents()` may
    /// resume — see the type's doc comment.
    private nonisolated let pendingFireAndForgetPublishes = EventBusPendingPublishCounter()

    /// Configurable staleness timeout for flush continuations (default: 30 s).
    /// Stale continuations are resumed and removed after this interval even if
    /// handlers are still in flight, preventing unbounded growth of the list.
    private var flushContinuationStaleness: TimeInterval = 30

    /// A continuation wrapper that ensures resume is called exactly once.
    /// Swift continuations crash fatally on double-resume; this guard prevents
    /// that when cleanup, timeout, and handler-completion race.
    private final class SafeContinuation: Sendable {
        nonisolated(unsafe) private var resumed = false
        private let continuation: CheckedContinuation<Void, Never>

        init(_ continuation: CheckedContinuation<Void, Never>) {
            self.continuation = continuation
        }

        /// Resume the continuation if it hasn't been resumed yet.
        /// Returns true if this call actually resumed, false if already resumed.
        @discardableResult
        func resumeOnce() -> Bool {
            guard !resumed else { return false }
            resumed = true
            continuation.resume()
            return true
        }
    }

    /// Flush continuations indexed by call-site UUID for targeted removal on timeout.
    /// Each entry carries a deadline so background cleanup can sweep expired ones.
    private var flushContinuations: [UUID: (deadline: Date, continuation: SafeContinuation)] = [:]

    /// Shared instance
    public static let shared = EventBus()

    public init() {}

    // MARK: - Publishing

    /// Publish an event to all subscribers (fire-and-forget)
    /// This is nonisolated for compatibility with existing synchronous code
    /// - Parameter event: The event to publish
    nonisolated public func publish(_ event: any RuntimeEvent) {
        // Pre-increment a synchronously-visible counter so awaitPendingEvents
        // cannot exit between publish() returning and publishInternal running.
        pendingFireAndForgetPublishes.increment()
        Task {
            await self.publishInternal(event)
            let drained = self.pendingFireAndForgetPublishes.decrement()
            // If our decrement drained the pending counter, the actor may
            // already think it's idle and have parked flush continuations.
            // Re-check inside the actor and resume them if appropriate.
            if drained {
                await self.checkFlushReadiness()
            }
        }
    }

    /// Internal async publish implementation.
    ///
    /// Each subscription gets a Task. Tracks `inFlightHandlers` so
    /// `awaitPendingEvents` waits for fire-and-forget work as well as
    /// publishAndTrack work. The pending-publish counter on `publish()`
    /// (incremented before this Task is even scheduled) bridges the race
    /// between publish() returning and this Task starting to run.
    ///
    /// We deliberately do NOT cap concurrency here: most fire-and-forget
    /// publishes are lightweight system events (FeatureSetStarted, etc.)
    /// with no subscribers — a global cap would backpressure those and
    /// blow up the queue. Bound resource-heavy work (HTTP fetches) at the
    /// action layer instead (see HTTPClient.sharedLimiter).
    private func publishInternal(_ event: any RuntimeEvent) async {
        let eventType = type(of: event).eventType
        let matchingSubscriptions = await store.matching(for: eventType)
        let allContinuations = Array(continuations.values)

        // Notify async stream subscribers
        for continuation in allContinuations {
            continuation.yield(event)
        }

        // Notify callback subscribers
        for subscription in matchingSubscriptions {
            inFlightHandlers += 1
            Task {
                await subscription.handler(event)
                await self.fireForgetHandlerCompleted()
            }
        }
    }

    /// Decrement in-flight tracking after a fire-and-forget handler completes.
    private func fireForgetHandlerCompleted() {
        inFlightHandlers -= 1
        if inFlightHandlers == 0 && pendingFireAndForgetPublishes.isZero {
            let pending = flushContinuations
            flushContinuations.removeAll()
            for (_, entry) in pending { entry.continuation.resumeOnce() }
        }
    }

    /// Wake any waiting flush continuations if both counters have drained.
    /// Called from the publish() task path after the pending-publish counter
    /// reaches zero, so the actor can recheck and signal completion.
    private func checkFlushReadiness() {
        if inFlightHandlers == 0 && pendingFireAndForgetPublishes.isZero {
            let pending = flushContinuations
            flushContinuations.removeAll()
            for (_, entry) in pending { entry.continuation.resumeOnce() }
        }
    }

    /// Publish an event and wait for all handlers to complete
    /// - Parameter event: The event to publish
    public func publishAndWait(_ event: any RuntimeEvent) async {
        let eventType = type(of: event).eventType
        let matchingSubscriptions = await store.matching(for: eventType)

        await withTaskGroup(of: Void.self) { group in
            for subscription in matchingSubscriptions {
                group.addTask {
                    await subscription.handler(event)
                }
            }
        }
    }

    /// Publish an event, wait for handlers to complete, and track in-flight status
    /// This is used by EmitAction to ensure proper event sequencing
    public func publishAndTrack(_ event: any RuntimeEvent) async {
        let eventType = type(of: event).eventType
        let matchingSubscriptions = await store.matching(for: eventType)

        // Execute all handlers and wait for completion
        await withTaskGroup(of: Void.self) { group in
            for subscription in matchingSubscriptions {
                // Increment counter when spawning each task
                inFlightHandlers += 1

                group.addTask {
                    await subscription.handler(event)

                    // Decrement counter when handler completes
                    await self.handlerCompleted()
                }
            }
        }
    }

    /// Called when a handler completes - decrements counter and notifies waiters
    private func handlerCompleted() {
        inFlightHandlers -= 1
        if inFlightHandlers == 0 && pendingFireAndForgetPublishes.isZero {
            let pending = flushContinuations
            flushContinuations.removeAll()
            for (_, entry) in pending { entry.continuation.resumeOnce() }
        }
    }

    /// Wait for all in-flight event handlers to complete
    /// - Parameter timeout: Maximum time to wait in seconds (default: AROEventHandlerDefaultTimeout)
    /// - Returns: true if all handlers completed, false if timeout occurred
    @discardableResult
    public func awaitPendingEvents(timeout: TimeInterval = AROEventHandlerDefaultTimeout) async -> Bool {
        let id = UUID()
        return await withTaskGroup(of: Bool.self) { group in
            // Task 1: Wait for handlers to complete
            group.addTask {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    Task {
                        await self.registerFlushContinuation(continuation, id: id)
                    }
                }
                return true
            }

            // Task 2: Timeout — remove the specific continuation so the list never leaks
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await self.removeFlushContinuation(id: id)
                return false
            }

            // Return first result (completion or timeout)
            if let result = await group.next() {
                group.cancelAll()
                return result
            }
            return false
        }
    }

    /// Register a continuation waiting for handlers to complete
    private func registerFlushContinuation(_ continuation: CheckedContinuation<Void, Never>, id: UUID) {
        let safe = SafeContinuation(continuation)
        if inFlightHandlers == 0 && pendingFireAndForgetPublishes.isZero {
            safe.resumeOnce()
        } else {
            let deadline = Date().addingTimeInterval(flushContinuationStaleness)
            flushContinuations[id] = (deadline: deadline, continuation: safe)
        }
    }

    /// Remove and resume a specific flush continuation (called on per-call timeout)
    private func removeFlushContinuation(id: UUID) {
        if let entry = flushContinuations.removeValue(forKey: id) {
            entry.continuation.resumeOnce()
        }
    }

    /// Resume and remove all flush continuations whose deadline has passed.
    /// Called automatically from awaitPendingEvents but can also be triggered manually.
    public func cleanupStaleContinuations() {
        let now = Date()
        let stale = flushContinuations.filter { $0.value.deadline < now }
        for (id, entry) in stale {
            flushContinuations.removeValue(forKey: id)
            entry.continuation.resumeOnce()
        }
    }

    /// Configure the staleness timeout for flush continuations.
    /// After this duration a waiting awaitPendingEvents call is released even if
    /// handlers are still in flight. Expose via the Configure action.
    /// - Parameter timeout: Staleness duration in seconds (default: 30)
    public func configure(flushContinuationStaleness timeout: TimeInterval) {
        flushContinuationStaleness = timeout
    }

    /// Get the count of pending event handlers currently in flight
    /// - Returns: The number of event handlers currently executing
    nonisolated public func getPendingHandlerCount() async -> Int {
        await self.inFlightHandlersCount
    }

    private var inFlightHandlersCount: Int {
        inFlightHandlers
    }

    /// True iff there is no in-flight or pending event work whatsoever —
    /// neither tracked handlers (`inFlightHandlers`) nor fire-and-forget
    /// publishes that haven't yet reached `publishInternal`. The shutdown
    /// loop in ExecutionEngine uses this instead of the raw handler count
    /// to avoid exiting during a brief lull between fan-out waves.
    nonisolated public func isQuiescent() async -> Bool {
        return await self.computeQuiescent()
    }

    private func computeQuiescent() -> Bool {
        return inFlightHandlers == 0 && pendingFireAndForgetPublishes.isZero
    }

    /// Register a pending handler (for fire-and-forget tasks)
    /// Call before spawning a task that will execute event handlers
    nonisolated public func registerPendingHandler() {
        Task {
            await self.registerPendingHandlerInternal()
        }
    }

    private func registerPendingHandlerInternal() {
        inFlightHandlers += 1
    }

    /// Unregister a pending handler (for fire-and-forget tasks)
    /// Call when a fire-and-forget task completes
    nonisolated public func unregisterPendingHandler() {
        Task {
            await self.unregisterPendingHandlerInternal()
        }
    }

    private func unregisterPendingHandlerInternal() {
        assert(inFlightHandlers > 0, "EventBus: unregisterPendingHandler called with no handlers in flight — mismatched register/unregister pair")
        guard inFlightHandlers > 0 else {
            // Release: log and bail rather than underflow
            FileHandle.standardError.write(Data("EventBus warning: unregisterPendingHandler called with no handlers in flight\n".utf8))
            return
        }
        inFlightHandlers -= 1
        if inFlightHandlers == 0 && pendingFireAndForgetPublishes.isZero {
            let pending = flushContinuations
            flushContinuations.removeAll()
            for (_, entry) in pending { entry.continuation.resumeOnce() }
        }
    }

    // MARK: - Active Event Sources

    /// Register an active event source (e.g., HTTP server, file monitor, socket server)
    /// Active event sources are long-lived services that can generate events asynchronously
    public func registerEventSource() {
        activeEventSources += 1
    }

    /// Unregister an active event source
    public func unregisterEventSource() {
        activeEventSources = max(0, activeEventSources - 1)
    }

    /// Check if there are active event sources that can generate events
    public var hasActiveEventSources: Bool {
        get async {
            activeEventSources > 0
        }
    }

    /// Synchronous wrapper for C bridge compatibility
    /// WARNING: Blocks the calling thread - use only from C bridge layer
    nonisolated public func hasActiveEventSourcesSync() -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        let box = EventBusResultBox(false)

        Task {
            box.value = await self.hasActiveEventSources
            semaphore.signal()
        }
        semaphore.wait()
        return box.value
    }

    /// Synchronous wrapper for C bridge compatibility
    /// WARNING: Blocks the calling thread - use only from C bridge layer
    nonisolated public func getPendingHandlerCountSync() -> Int {
        let semaphore = DispatchSemaphore(value: 0)
        let box = EventBusResultBox(0)

        Task {
            box.value = await self.getPendingHandlerCount()
            semaphore.signal()
        }
        semaphore.wait()
        return box.value
    }

    // MARK: - Subscribing

    /// Subscribe to events of a specific type.
    /// The subscription is registered asynchronously via a Task into the
    /// SubscriptionStore actor. This is nonisolated for compatibility with
    /// existing synchronous call sites.
    /// - Parameters:
    ///   - eventType: The event type to subscribe to (or "*" for all events)
    ///   - handler: The handler to call when events occur
    /// - Returns: A subscription ID that can be used to unsubscribe
    @discardableResult
    nonisolated public func subscribe(to eventType: String, handler: @escaping EventHandler) -> UUID {
        let subscription = Subscription(
            id: UUID(),
            eventType: eventType,
            handler: handler
        )
        Task { await store.add(subscription) }
        return subscription.id
    }

    /// Subscribe to events of a specific type with a typed handler
    /// - Parameters:
    ///   - type: The event type to subscribe to
    ///   - handler: The typed handler to call when events occur
    /// - Returns: A subscription ID that can be used to unsubscribe
    @discardableResult
    nonisolated public func subscribe<E: RuntimeEvent>(to type: E.Type, handler: @escaping @Sendable (E) async -> Void) -> UUID {
        subscribe(to: E.eventType) { event in
            if let typedEvent = event as? E {
                await handler(typedEvent)
            }
        }
    }

    /// Create an async stream of events
    /// - Parameter eventType: The event type to filter (or "*" for all events)
    /// - Returns: An async stream of events
    public func stream(for eventType: String = "*") -> AsyncStream<any RuntimeEvent> {
        let id = UUID()

        return AsyncStream { continuation in
            Task {
                self.continuations[id] = continuation
            }

            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task {
                    await self.removeContinuation(id)
                }
            }
        }
    }

    /// Create a typed async stream of events
    /// - Parameter type: The event type to subscribe to
    /// - Returns: An async stream of typed events
    public func stream<E: RuntimeEvent>(for type: E.Type) -> AsyncStream<E> {
        AsyncStream { continuation in
            Task {
                let id = self.subscribe(to: type) { event in
                    continuation.yield(event)
                }

                continuation.onTermination = { [weak self] _ in
                    guard let self else { return }
                    Task {
                        self.unsubscribe(id)
                    }
                }
            }
        }
    }

    private func removeContinuation(_ id: UUID) {
        _ = continuations.removeValue(forKey: id)
    }

    // MARK: - Unsubscribing

    /// Unsubscribe from events
    /// - Parameter id: The subscription ID returned from subscribe
    nonisolated public func unsubscribe(_ id: UUID) {
        Task {
            await store.remove(id)
            await self.removeContinuation(id)
        }
    }

    /// Remove all subscriptions
    nonisolated public func unsubscribeAll() {
        Task {
            await store.removeAll()
            await self.finishAndClearContinuations()
        }
    }

    private func finishAndClearContinuations() {
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll()
    }

    // MARK: - Inspection

    /// Number of active subscriptions
    public var subscriptionCount: Int {
        get async {
            await store.count + continuations.count
        }
    }
}
