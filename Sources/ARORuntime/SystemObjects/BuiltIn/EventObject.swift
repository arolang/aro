// ============================================================
// EventObject.swift
// ARO Runtime - Event System Object
// ============================================================

import Foundation

// MARK: - Event Object

/// Event system object for accessing event payload
///
/// A source-only context object that provides access to the current event.
/// Only available in event handler feature sets.
///
/// ## ARO Usage
/// ```aro
/// <Extract> the <user> from the <event: user>.
/// <Extract> the <path> from the <event: path>.
/// ```
public struct EventObject: SystemObject {
    public static let identifier = "event"
    public static let description = "Event payload"

    public var capabilities: SystemObjectCapabilities { .source }

    private let eventType: String
    private let payload: [String: any Sendable]
    private let timestamp: Date

    /// Create an event object from event data
    public init(
        eventType: String,
        payload: [String: any Sendable],
        timestamp: Date = Date()
    ) {
        self.eventType = eventType
        self.payload = payload
        self.timestamp = timestamp
    }

    public func read(property: String?) async throws -> any Sendable {
        guard let property = property else {
            // Return the full event
            var event: [String: any Sendable] = [
                "type": eventType,
                "timestamp": ISO8601DateFormatter().string(from: timestamp)
            ]
            for (key, value) in payload {
                event[key] = value
            }
            return event
        }

        // Support nested paths like "user.name"
        let parts = property.split(separator: ".").map(String.init)

        switch parts[0] {
        case "type":
            return eventType
        case "timestamp":
            return ISO8601DateFormatter().string(from: timestamp)
        default:
            // Look in payload
            return try resolveNestedPath(parts, in: payload)
        }
    }

    private func resolveNestedPath(
        _ parts: [String],
        in dict: [String: any Sendable]
    ) throws -> any Sendable {
        guard let first = parts.first else {
            throw SystemObjectError.propertyNotFound("", in: Self.identifier)
        }

        guard let value = dict[first] else {
            throw SystemObjectError.propertyNotFound(parts.joined(separator: "."), in: Self.identifier)
        }

        if parts.count == 1 {
            return value
        }

        // Recurse into nested dictionary
        if let nested = value as? [String: any Sendable] {
            return try resolveNestedPath(Array(parts.dropFirst()), in: nested)
        }

        throw SystemObjectError.propertyNotFound(parts.joined(separator: "."), in: Self.identifier)
    }

    public func write(_ value: any Sendable) async throws {
        throw SystemObjectError.notWritable(Self.identifier)
    }
}

// MARK: - Shutdown Object

/// Shutdown context system object
///
/// A source-only context object for Application-End handlers.
/// Provides access to shutdown reason, signal, and any error.
///
/// ## ARO Usage
/// ```aro
/// <Extract> the <error> from the <shutdown: error>.
/// <Extract> the <signal> from the <shutdown: signal>.
/// ```
public struct ShutdownObject: SystemObject {
    public static let identifier = "shutdown"
    public static let description = "Shutdown context"

    public var capabilities: SystemObjectCapabilities { .source }

    private let reason: String
    private let signal: String?
    private let error: (any Error)?
    private let exitCode: Int

    /// Create a shutdown object
    public init(
        reason: String,
        signal: String? = nil,
        error: (any Error)? = nil,
        exitCode: Int = 0
    ) {
        self.reason = reason
        self.signal = signal
        self.error = error
        self.exitCode = exitCode
    }

    public func read(property: String?) async throws -> any Sendable {
        guard let property = property else {
            // Return full shutdown context
            var context: [String: any Sendable] = [
                "reason": reason,
                "exitCode": exitCode
            ]
            if let signal = signal {
                context["signal"] = signal
            }
            if let error = error {
                context["error"] = String(describing: error)
            }
            return context
        }

        switch property {
        case "reason":
            return reason
        case "signal":
            return signal ?? ""
        case "error":
            if let error = error {
                return String(describing: error)
            }
            return ""
        case "exitCode", "code":
            return exitCode
        default:
            throw SystemObjectError.propertyNotFound(property, in: Self.identifier)
        }
    }

    public func write(_ value: any Sendable) async throws {
        throw SystemObjectError.notWritable(Self.identifier)
    }
}

// MARK: - Registration

public extension SystemObjectRegistry {
    /// Register event-related system objects
    func registerEventObjects() {
        register(
            "event",
            description: EventObject.description,
            capabilities: .source
        ) { _ in
            PlaceholderEventObject()
        }

        register(
            "shutdown",
            description: ShutdownObject.description,
            capabilities: .source
        ) { _ in
            PlaceholderEventObject()
        }
    }
}

// MARK: - Placeholder for Registration

/// Placeholder for event objects when not in an event handler
private struct PlaceholderEventObject: SystemObject {
    static let identifier = "event"
    static let description = "Event payload (only available in event handlers)"

    var capabilities: SystemObjectCapabilities { .source }

    func read(property: String?) async throws -> any Sendable {
        throw SystemObjectError.notAvailableInContext(Self.identifier, context: "non-event")
    }

    func write(_ value: any Sendable) async throws {
        throw SystemObjectError.notWritable(Self.identifier)
    }
}
