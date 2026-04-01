// ============================================================
// EventBus.swift
// ARO Runtime - Event Bus
// ============================================================

import Foundation

/// Default timeout in seconds for waiting on event handlers to complete
public let AROEventHandlerDefaultTimeout: TimeInterval = 10.0

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

    /// Configurable staleness timeout for flush continuations (default: 30 s).
    /// Stale continuations are resumed and removed after this interval even if
    /// handlers are still in flight, preventing unbounded growth of the list.
    private var flushContinuationStaleness: TimeInterval = 30

    /// Flush continuations indexed by call-site UUID for targeted removal on timeout.
    /// Each entry carries a deadline so background cleanup can sweep expired ones.
    private var flushContinuations: [UUID: (deadline: Date, continuation: CheckedContinuation<Void, Never>)] = [:]

    /// Shared instance
    public static let shared = EventBus()

    public init() {}

    // MARK: - Publishing

    /// Publish an event to all subscribers (fire-and-forget)
    /// This is nonisolated for compatibility with existing synchronous code
    /// - Parameter event: The event to publish
    nonisolated public func publish(_ event: any RuntimeEvent) {
        Task {
            await self.publishInternal(event)
        }
    }

    /// Internal async publish implementation
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
            Task {
                await subscription.handler(event)
            }
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
        if inFlightHandlers == 0 {
            let pending = flushContinuations
            flushContinuations.removeAll()
            for (_, entry) in pending { entry.continuation.resume() }
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
        if inFlightHandlers == 0 {
            continuation.resume()
        } else {
            let deadline = Date().addingTimeInterval(flushContinuationStaleness)
            flushContinuations[id] = (deadline: deadline, continuation: continuation)
        }
    }

    /// Remove and resume a specific flush continuation (called on per-call timeout)
    private func removeFlushContinuation(id: UUID) {
        if let entry = flushContinuations.removeValue(forKey: id) {
            entry.continuation.resume()
        }
    }

    /// Resume and remove all flush continuations whose deadline has passed.
    /// Called automatically from awaitPendingEvents but can also be triggered manually.
    public func cleanupStaleContinuations() {
        let now = Date()
        let stale = flushContinuations.filter { $0.value.deadline < now }
        for (id, entry) in stale {
            flushContinuations.removeValue(forKey: id)
            entry.continuation.resume()
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
        if inFlightHandlers == 0 {
            let pending = flushContinuations
            flushContinuations.removeAll()
            for (_, entry) in pending { entry.continuation.resume() }
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
