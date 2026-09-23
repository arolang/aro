// ============================================================
// NotifyAction.swift
// ARO Runtime - Notify: telling a user or system something happened
// ============================================================

import Foundation
import AROParser

/// Notifies a user or system
public struct NotifyAction: ActionImplementation {
    public static let role: ActionRole = .response
    public static let verbs: Set<String> = ["notify", "alert", "signal"]
    public static let validPrepositions: Set<Preposition> = [.to, .for, .with]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        // result = the notification target recipient (e.g., <user>, <admin>)
        // May be a plain identifier or a resolved object (dict with name, age, etc.)
        let target = result.base
        let targetValue = context.resolveAny(result.base)

        // object = the notification message content (via "with"/"to" preposition)
        let message: String
        if let value: String = context.resolve(object.base) {
            message = value
        } else if let value = context.resolveAny(object.base) {
            message = String(describing: value)
        } else {
            message = object.base
        }

        // Try notification service
        if let notificationService = context.service(NotificationService.self) {
            try await notificationService.notify(message: message, target: target)
            return NotifyResult(message: message, target: target, success: true)
        }

        // Emit notification event(s), carrying the resolved target value so handlers
        // can access object fields (e.g., Extract the <user> from the <event: user>.)
        // Use publishAndTrack so awaitPendingEvents() waits for all handlers to finish.
        // When the target is a collection, emit one event per item so the runtime
        // distributes the notification — `Notify the <adults> with "Hello!".` works
        // the same as iterating and notifying each adult individually.
        let items: [any Sendable]
        if let array = targetValue as? [any Sendable] {
            items = array
        } else if let item = targetValue {
            items = [item]
        } else {
            items = []
        }

        // Typed event: NotificationSentEvent { message, target, targetValue }
        //   One event per item in the collection; handler 'when' guards filter by target field values.
        // DomainEvent co-publish for binary mode support:
        //   eventType: "NotificationSent"
        //   payload: { "message": String, "target": String, "user": targetObj, "[target]": targetObj,
        //              ...targetObj fields spread at top level (for `when` guard evaluation) }
        if let eventBus = context.eventBus {
            for item in items {
                await eventBus.publishAndTrack(NotificationSentEvent(message: message, target: target, targetValue: item))
                // Co-publish DomainEvent for binary mode compiled handlers
                var payload: [String: any Sendable] = ["message": message, "target": target]
                if let itemDict = item as? [String: any Sendable] {
                    for (k, v) in itemDict { payload[k] = v }   // spread fields for when guard
                    payload["user"] = itemDict
                    payload[target] = itemDict
                } else {
                    payload["user"] = item
                    payload[target] = item
                }
                await context.container.eventBus.publishAndTrack(DomainEvent(eventType: "NotificationSent", payload: payload))
            }
        } else {
            for item in items {
                context.emit(NotificationSentEvent(message: message, target: target, targetValue: item))
            }
        }

        return NotifyResult(message: message, target: target, success: true)
    }
}

/// Notification service protocol
public protocol NotificationService: Sendable {
    func notify(message: String, target: String) async throws
}

/// Result of a notify operation
public struct NotifyResult: Sendable, Equatable {
    public let message: String
    public let target: String
    public let success: Bool
}

/// Event emitted when a notification is sent
public struct NotificationSentEvent: RuntimeEvent {
    public static var eventType: String { "notification.sent" }
    public let timestamp: Date
    public let message: String
    public let target: String
    /// The resolved value of the target variable (e.g., a user dict with name/age/email/sex).
    /// Bound in the handler context as "event:<target>" so handlers can extract fields.
    public let targetValue: (any Sendable)?

    public init(message: String, target: String, targetValue: (any Sendable)? = nil) {
        self.timestamp = Date()
        self.message = message
        self.target = target
        self.targetValue = targetValue
    }
}
