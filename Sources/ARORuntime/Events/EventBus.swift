// ============================================================
// EventBus.swift
// ARO Runtime - Event Bus
// ============================================================

import Foundation

/// Default timeout in seconds for waiting on event handlers to complete
public let AROEventHandlerDefaultTimeout: TimeInterval = 10.0

/// Central event bus for publishing and subscribing to runtime events
///
/// The EventBus provides a decoupled communication mechanism between
/// components in the ARO runtime. Events can be published from
/// actions and feature sets, and handled by registered subscribers.
public final class EventBus: @unchecked Sendable {
    /// Subscription handler type
    public typealias EventHandler = @Sendable (any RuntimeEvent) async -> Void

    /// Subscription entry
    private struct Subscription: Sendable {
        let id: UUID
        let eventType: String
        let handler: EventHandler
    }

    /// Lock for thread-safe access
    private let lock = NSLock()

    /// Subscriptions indexed by event type for O(1) lookup (ARO-0064)
    private var subscriptionsByType: [String: [Subscription]] = [:]

    /// Wildcard subscribers that receive all events (ARO-0064)
    private var wildcardSubscriptions: [Subscription] = []

    /// Async stream continuations for stream-based subscriptions
    private var continuations: [UUID: AsyncStream<any RuntimeEvent>.Continuation] = [:]

    /// In-flight event handler counter
    private var inFlightHandlers: Int = 0

    /// Active event sources (HTTP servers, file monitors, socket servers)
    /// These are long-lived services that can generate events asynchronously
    private var activeEventSources: Int = 0

    /// Continuations waiting for all handlers to complete
    private var flushContinuations: [CheckedContinuation<Void, Never>] = []

    /// Shared instance
    public static let shared = EventBus()

    public init() {}

    // MARK: - Thread-safe helpers

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func getMatchingSubscriptions(for eventType: String) -> [Subscription] {
        withLock {
            // O(1) dictionary lookup + wildcard subscriptions (ARO-0064)
            let typeSubscriptions = subscriptionsByType[eventType] ?? []
            return typeSubscriptions + wildcardSubscriptions
        }
    }

    private func getAllContinuations() -> [AsyncStream<any RuntimeEvent>.Continuation] {
        withLock { Array(continuations.values) }
    }

    private func addSubscription(_ subscription: Subscription) {
        withLock {
            // Index by event type for O(1) lookup (ARO-0064)
            if subscription.eventType == "*" {
                wildcardSubscriptions.append(subscription)
            } else {
                subscriptionsByType[subscription.eventType, default: []].append(subscription)
            }
        }
    }

    private func addContinuation(_ id: UUID, continuation: AsyncStream<any RuntimeEvent>.Continuation) {
        withLock { continuations[id] = continuation }
    }

    private func removeContinuation(_ id: UUID) {
        withLock { _ = continuations.removeValue(forKey: id) }
    }

    // MARK: - Publishing

    /// Publish an event to all subscribers
    /// - Parameter event: The event to publish
    public func publish(_ event: any RuntimeEvent) {
        let eventType = type(of: event).eventType
        let matchingSubscriptions = getMatchingSubscriptions(for: eventType)
        let allContinuations = getAllContinuations()

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
        let matchingSubscriptions = getMatchingSubscriptions(for: eventType)

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
        let matchingSubscriptions = getMatchingSubscriptions(for: eventType)

        // Execute all handlers and wait for completion
        await withTaskGroup(of: Void.self) { group in
            for subscription in matchingSubscriptions {
                // Increment counter atomically when spawning each task
                withLock {
                    inFlightHandlers += 1
                }

                group.addTask {
                    await subscription.handler(event)

                    // Decrement counter when handler completes
                    let continuationsToResume = self.withLock { () -> [CheckedContinuation<Void, Never>] in
                        self.inFlightHandlers -= 1
                        let shouldNotify = self.inFlightHandlers == 0
                        if shouldNotify {
                            let continuations = self.flushContinuations
                            self.flushContinuations.removeAll()
                            return continuations
                        }
                        return []
                    }

                    // Resume any waiting flush operations
                    for continuation in continuationsToResume {
                        continuation.resume()
                    }
                }
            }
        }
    }

    /// Wait for all in-flight event handlers to complete
    /// - Parameter timeout: Maximum time to wait in seconds (default: AROEventHandlerDefaultTimeout)
    /// - Returns: true if all handlers completed, false if timeout occurred
    @discardableResult
    public func awaitPendingEvents(timeout: TimeInterval = AROEventHandlerDefaultTimeout) async -> Bool {
        // Wait with timeout
        return await withTaskGroup(of: Bool.self) { group in
            // Task 1: Wait for handlers to complete
            group.addTask {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    self.withLock {
                        // CRITICAL: Both check AND resume must be inside lock to prevent TOCTOU race
                        if self.inFlightHandlers == 0 {
                            continuation.resume()
                        } else {
                            self.flushContinuations.append(continuation)
                        }
                    }
                }
                return true
            }

            // Task 2: Timeout
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
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

    /// Get the count of pending event handlers currently in flight
    /// - Returns: The number of event handlers currently executing
    public func getPendingHandlerCount() -> Int {
        withLock { inFlightHandlers }
    }

    /// Register a pending handler (for fire-and-forget tasks)
    /// Call before spawning a task that will execute event handlers
    public func registerPendingHandler() {
        withLock { inFlightHandlers += 1 }
    }

    /// Unregister a pending handler (for fire-and-forget tasks)
    /// Call when a fire-and-forget task completes
    public func unregisterPendingHandler() {
        let continuationsToResume = withLock { () -> [CheckedContinuation<Void, Never>] in
            inFlightHandlers = max(0, inFlightHandlers - 1)
            if inFlightHandlers == 0 {
                let continuations = flushContinuations
                flushContinuations.removeAll()
                return continuations
            }
            return []
        }
        // Resume any waiting continuations outside the lock
        for continuation in continuationsToResume {
            continuation.resume()
        }
    }

    // MARK: - Active Event Sources

    /// Register an active event source (e.g., HTTP server, file monitor, socket server)
    /// Active event sources are long-lived services that can generate events asynchronously
    public func registerEventSource() {
        withLock { activeEventSources += 1 }
    }

    /// Unregister an active event source
    public func unregisterEventSource() {
        withLock { activeEventSources = max(0, activeEventSources - 1) }
    }

    /// Check if there are active event sources that can generate events
    public var hasActiveEventSources: Bool {
        withLock { activeEventSources > 0 }
    }

    // MARK: - Subscribing

    /// Subscribe to events of a specific type
    /// - Parameters:
    ///   - eventType: The event type to subscribe to (or "*" for all events)
    ///   - handler: The handler to call when events occur
    /// - Returns: A subscription ID that can be used to unsubscribe
    @discardableResult
    public func subscribe(to eventType: String, handler: @escaping EventHandler) -> UUID {
        let subscription = Subscription(
            id: UUID(),
            eventType: eventType,
            handler: handler
        )

        addSubscription(subscription)

        return subscription.id
    }

    /// Subscribe to events of a specific type with a typed handler
    /// - Parameters:
    ///   - type: The event type to subscribe to
    ///   - handler: The typed handler to call when events occur
    /// - Returns: A subscription ID that can be used to unsubscribe
    @discardableResult
    public func subscribe<E: RuntimeEvent>(to type: E.Type, handler: @escaping @Sendable (E) async -> Void) -> UUID {
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
            self.addContinuation(id, continuation: continuation)

            continuation.onTermination = { [weak self] _ in
                self?.removeContinuation(id)
            }
        }
    }

    /// Create a typed async stream of events
    /// - Parameter type: The event type to subscribe to
    /// - Returns: An async stream of typed events
    public func stream<E: RuntimeEvent>(for type: E.Type) -> AsyncStream<E> {
        AsyncStream { continuation in
            let id = subscribe(to: type) { event in
                continuation.yield(event)
            }

            continuation.onTermination = { [weak self] _ in
                self?.unsubscribe(id)
            }
        }
    }

    // MARK: - Unsubscribing

    /// Unsubscribe from events
    /// - Parameter id: The subscription ID returned from subscribe
    public func unsubscribe(_ id: UUID) {
        withLock {
            // Remove from wildcard subscriptions (ARO-0064)
            wildcardSubscriptions.removeAll { $0.id == id }

            // Remove from type-specific subscriptions (ARO-0064)
            for key in subscriptionsByType.keys {
                subscriptionsByType[key]?.removeAll { $0.id == id }
                // Clean up empty arrays
                if subscriptionsByType[key]?.isEmpty == true {
                    subscriptionsByType.removeValue(forKey: key)
                }
            }

            _ = continuations.removeValue(forKey: id)
        }
    }

    /// Remove all subscriptions
    public func unsubscribeAll() {
        withLock {
            // Clear indexed subscriptions (ARO-0064)
            wildcardSubscriptions.removeAll()
            subscriptionsByType.removeAll()

            for continuation in continuations.values {
                continuation.finish()
            }
            continuations.removeAll()
        }
    }

    // MARK: - Inspection

    /// Number of active subscriptions
    public var subscriptionCount: Int {
        withLock {
            // Count indexed subscriptions (ARO-0064)
            let typeSubscriptionCount = subscriptionsByType.values.reduce(0) { $0 + $1.count }
            return wildcardSubscriptions.count + typeSubscriptionCount + continuations.count
        }
    }
}
