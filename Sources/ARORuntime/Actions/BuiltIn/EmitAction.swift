// ============================================================
// EmitAction.swift
// ARO Runtime - Emit: the domain event that triggers handler feature sets
// ============================================================

import Foundation
import AROParser

/// A custom domain event emitted by ARO code
/// The eventType is dynamically set based on the event name in the ARO statement
public struct DomainEvent: RuntimeEvent {
    /// The event type (e.g., "UserCreated", "OrderPlaced")
    public let domainEventType: String

    /// Static event type for routing - uses "domain.*" prefix
    public static var eventType: String { "domain" }

    /// The name the `Emit` statement wrote, which is what handler routing
    /// matches on and therefore what an event breakpoint must match too
    /// (GitLab #557).
    public var eventName: String { domainEventType }

    /// Timestamp when the event occurred
    public let timestamp: Date

    /// The payload data attached to the event
    public let payload: [String: any Sendable]

    public init(eventType: String, payload: [String: any Sendable]) {
        self.domainEventType = eventType
        self.timestamp = Date()
        self.payload = payload
    }
}

/// Emits a domain event to trigger event handlers
///
/// The Emit action publishes custom domain events that can be handled
/// by feature sets with matching "Handler" business activity.
///
/// ## Example
/// ```
/// <Emit> a <UserCreated: event> with <user>.
/// ```
/// This triggers feature sets with business activity "UserCreated Handler"
public struct EmitAction: ActionImplementation {
    public static let role: ActionRole = .export
    public static let verbs: Set<String> = ["emit"]
    public static let validPrepositions: Set<Preposition> = [.with, .to]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        // Get event type from result (e.g., "UserCreated" from <UserCreated: event>)
        let eventType = result.base

        // Get payload data from object or literal
        // Always wrap the value with the variable name as key
        // e.g., <Emit> a <UserCreated: event> with <user> -> payload: {"user": <user value>}
        var payload: [String: any Sendable] = [:]

        // Determine the key name for the payload
        // If we have _expression_name_, use it (for variable references like <user>)
        // Otherwise fall back to object.base
        let payloadKey: String
        if let expressionName: String = context.resolve("_expression_name_"), !expressionName.isEmpty {
            payloadKey = expressionName
        } else if object.base != "_expression_" {
            payloadKey = object.base
        } else {
            payloadKey = "data" // Default fallback
        }

        // Payload values are forced here, at emit (ARO-0088 §3: an effect forces
        // its inputs at its own statement).
        //
        // The original design deferred this to "first handler read" so the
        // emitter wouldn't block. That only worked while nothing was ever
        // genuinely pending: once actions really defer, an unforced handle in
        // the payload escapes into the event, and every one of the ten places
        // that binds `event` into a handler context would have to know how to
        // unwrap it — including the ones that serialise the payload to JSON or
        // ship it over a socket. Forcing at the emitting statement keeps the
        // handle inside the runtime that created it. Emit is force-at-site
        // anyway, so its statement was never going to be deferred.
        if let literalValue = context.resolveAny("_literal_") {
            payload[payloadKey] = literalValue
        } else if object.base == "_expression_", let exprValue = context.resolveAny("_expression_") {
            let exprName: String = context.resolve("_expression_name_") ?? ""
            if exprName.isEmpty, let dictValue = exprValue as? [String: any Sendable] {
                // Object literal expression `with { key: val, ... }` — spread dict directly as payload
                // so handlers can access top-level keys via <event: key>
                payload = dictValue
            } else {
                // Variable reference expression — wrap with the variable name as key
                payload[exprName.isEmpty ? "data" : exprName] = exprValue
            }
        } else if let payloadValue = context.resolveAny(object.base) {
            // Named variable payload - wrap with the payload key
            // This allows handlers to extract with: <Extract> the <user> from the <event: user>
            payload[payloadKey] = payloadValue
        }

        // A body handed to an event outlives the request it arrived on, so it
        // is anchored first (GitLab #477): drained to a file one chunk at a
        // time and passed on as a value any number of handlers can read. The
        // alternative is a stream tied to a connection that will be closed
        // before the handlers run, which is not a value at all.
        for (key, value) in payload {
            guard let body = value as? RequestBodyValue else { continue }
            let statement = "Emit a <\(eventType): event> with <\(key)>"
            payload[key] = try await AnchoredBody.anchor(body, statement: statement)
        }

        // Create and emit the domain event.
        // DomainEvent eventType: user-defined (result.base, e.g. "UserCreated")
        // DomainEvent payload:   { payloadKey: value } where payloadKey = object variable name
        //   Handlers extract with: Extract the <user> from the <event: user>
        let event = DomainEvent(eventType: eventType, payload: payload)

        // Emit to event bus and wait for handlers to complete
        // This ensures event handlers finish before continuing
        if let eventBus = context.eventBus {
            await eventBus.publishAndTrack(event)
        } else {
            // Fallback to fire-and-forget if no event bus
            context.emit(event)
        }

        return EmitResult(eventType: eventType, success: true)
    }
}

/// Result of an emit operation
public struct EmitResult: Sendable, Equatable {
    public let eventType: String
    public let success: Bool
}
