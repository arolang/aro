// ============================================================
// EventBus.swift
// ARO Runtime - Event Bus
// ============================================================

import Foundation

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

    /// All subscriptions
    private var subscriptions: [Subscription] = []

    /// Async stream continuations for stream-based subscriptions
    private var continuations: [UUID: AsyncStream<any RuntimeEvent>.Continuation] = [:]

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
            subscriptions.filter { $0.eventType == eventType || $0.eventType == "*" }
        }
    }

    private func getAllContinuations() -> [AsyncStream<any RuntimeEvent>.Continuation] {
        withLock { Array(continuations.values) }
    }

    private func addSubscription(_ subscription: Subscription) {
        withLock { subscriptions.append(subscription) }
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
            subscriptions.removeAll { $0.id == id }
            _ = continuations.removeValue(forKey: id)
        }
    }

    /// Remove all subscriptions
    public func unsubscribeAll() {
        withLock {
            subscriptions.removeAll()
            for continuation in continuations.values {
                continuation.finish()
            }
            continuations.removeAll()
        }
    }

    // MARK: - Inspection

    /// Number of active subscriptions
    public var subscriptionCount: Int {
        withLock { subscriptions.count + continuations.count }
    }
}
