// ============================================================
// EventTypes.swift
// ARO Runtime - Standard Event Types
// ============================================================

import Foundation

// MARK: - Base Event

/// Base implementation for runtime events
public struct BaseEvent: RuntimeEvent {
    public static var eventType: String { "base" }
    public let timestamp: Date
    public let name: String
    public let data: [String: AnySendable]

    public init(name: String, data: [String: AnySendable] = [:]) {
        self.timestamp = Date()
        self.name = name
        self.data = data
    }
}

// MARK: - Application Events

/// Application started event
public struct ApplicationStartedEvent: RuntimeEvent {
    public static var eventType: String { "application.started" }
    public let timestamp: Date
    public let applicationName: String

    public init(applicationName: String) {
        self.timestamp = Date()
        self.applicationName = applicationName
    }
}

/// Application stopping event
public struct ApplicationStoppingEvent: RuntimeEvent {
    public static var eventType: String { "application.stopping" }
    public let timestamp: Date
    public let reason: String

    public init(reason: String = "shutdown") {
        self.timestamp = Date()
        self.reason = reason
    }
}

// MARK: - HTTP Events

/// HTTP request received event
public struct HTTPRequestReceivedEvent: RuntimeEvent {
    public static var eventType: String { "http.request" }
    public let timestamp: Date
    public let requestId: String
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data?

    public init(
        requestId: String = UUID().uuidString,
        method: String,
        path: String,
        headers: [String: String] = [:],
        body: Data? = nil
    ) {
        self.timestamp = Date()
        self.requestId = requestId
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }
}

/// HTTP response sent event
public struct HTTPResponseSentEvent: RuntimeEvent {
    public static var eventType: String { "http.response" }
    public let timestamp: Date
    public let requestId: String
    public let statusCode: Int
    public let durationMs: Double

    public init(requestId: String, statusCode: Int, durationMs: Double) {
        self.timestamp = Date()
        self.requestId = requestId
        self.statusCode = statusCode
        self.durationMs = durationMs
    }
}

// MARK: - File Events

/// File created event
public struct FileCreatedEvent: RuntimeEvent {
    public static var eventType: String { "file.created" }
    public let timestamp: Date
    public let path: String

    public init(path: String) {
        self.timestamp = Date()
        self.path = path
    }
}

/// File modified event
public struct FileModifiedEvent: RuntimeEvent {
    public static var eventType: String { "file.modified" }
    public let timestamp: Date
    public let path: String

    public init(path: String) {
        self.timestamp = Date()
        self.path = path
    }
}

/// File deleted event
public struct FileDeletedEvent: RuntimeEvent {
    public static var eventType: String { "file.deleted" }
    public let timestamp: Date
    public let path: String

    public init(path: String) {
        self.timestamp = Date()
        self.path = path
    }
}

// MARK: - Socket Events

/// Client connected event
public struct ClientConnectedEvent: RuntimeEvent {
    public static var eventType: String { "socket.connected" }
    public let timestamp: Date
    public let connectionId: String
    public let remoteAddress: String

    public init(connectionId: String, remoteAddress: String) {
        self.timestamp = Date()
        self.connectionId = connectionId
        self.remoteAddress = remoteAddress
    }
}

/// Data received event
public struct DataReceivedEvent: RuntimeEvent {
    public static var eventType: String { "socket.data" }
    public let timestamp: Date
    public let connectionId: String
    public let data: Data

    public init(connectionId: String, data: Data) {
        self.timestamp = Date()
        self.connectionId = connectionId
        self.data = data
    }
}

/// Client disconnected event
public struct ClientDisconnectedEvent: RuntimeEvent {
    public static var eventType: String { "socket.disconnected" }
    public let timestamp: Date
    public let connectionId: String
    public let reason: String

    public init(connectionId: String, reason: String = "closed") {
        self.timestamp = Date()
        self.connectionId = connectionId
        self.reason = reason
    }
}

// MARK: - WebSocket Events

/// WebSocket client connected event
public struct WebSocketConnectedEvent: RuntimeEvent {
    public static var eventType: String { "websocket.connected" }
    public let timestamp: Date
    public let connectionId: String
    public let path: String
    public let remoteAddress: String

    public init(connectionId: String, path: String, remoteAddress: String) {
        self.timestamp = Date()
        self.connectionId = connectionId
        self.path = path
        self.remoteAddress = remoteAddress
    }
}

/// WebSocket message received event
public struct WebSocketMessageEvent: RuntimeEvent {
    public static var eventType: String { "websocket.message" }
    public let timestamp: Date
    public let connectionId: String
    public let message: String

    public init(connectionId: String, message: String) {
        self.timestamp = Date()
        self.connectionId = connectionId
        self.message = message
    }
}

/// WebSocket client disconnected event
public struct WebSocketDisconnectedEvent: RuntimeEvent {
    public static var eventType: String { "websocket.disconnected" }
    public let timestamp: Date
    public let connectionId: String
    public let reason: String

    public init(connectionId: String, reason: String = "closed") {
        self.timestamp = Date()
        self.connectionId = connectionId
        self.reason = reason
    }
}

// MARK: - Error Events

/// Error occurred event
public struct ErrorOccurredEvent: RuntimeEvent {
    public static var eventType: String { "error" }
    public let timestamp: Date
    public let error: String
    public let context: String
    public let recoverable: Bool

    public init(error: String, context: String, recoverable: Bool = true) {
        self.timestamp = Date()
        self.error = error
        self.context = context
        self.recoverable = recoverable
    }
}

// MARK: - Feature Set Events

/// Feature set started event
public struct FeatureSetStartedEvent: RuntimeEvent {
    public static var eventType: String { "featureset.started" }
    public let timestamp: Date
    public let featureSetName: String
    public let businessActivity: String
    public let executionId: String

    public init(featureSetName: String, businessActivity: String = "", executionId: String) {
        self.timestamp = Date()
        self.featureSetName = featureSetName
        self.businessActivity = businessActivity
        self.executionId = executionId
    }
}

/// Feature set completed event
public struct FeatureSetCompletedEvent: RuntimeEvent {
    public static var eventType: String { "featureset.completed" }
    public let timestamp: Date
    public let featureSetName: String
    public let businessActivity: String
    public let executionId: String
    public let success: Bool
    public let durationMs: Double

    public init(featureSetName: String, businessActivity: String = "", executionId: String, success: Bool, durationMs: Double) {
        self.timestamp = Date()
        self.featureSetName = featureSetName
        self.businessActivity = businessActivity
        self.executionId = executionId
        self.success = success
        self.durationMs = durationMs
    }
}

// MARK: - Repository Events

/// Change type for repository operations
public enum RepositoryChangeType: String, Sendable {
    case created = "created"
    case updated = "updated"
    case deleted = "deleted"
}

/// Event emitted when a repository item changes
///
/// Repository observers can subscribe to this event to react to changes.
/// The event includes both the old and new values for comparison.
public struct RepositoryChangedEvent: RuntimeEvent {
    public static var eventType: String { "repository.changed" }
    public let timestamp: Date

    /// Repository name (e.g., "user-repository")
    public let repositoryName: String

    /// Type of change: created, updated, or deleted
    public let changeType: RepositoryChangeType

    /// Entity ID (nil for non-dictionary values)
    public let entityId: String?

    /// The new value (nil for deletes)
    public let newValue: (any Sendable)?

    /// The old value (nil for creates)
    public let oldValue: (any Sendable)?

    public init(
        repositoryName: String,
        changeType: RepositoryChangeType,
        entityId: String? = nil,
        newValue: (any Sendable)? = nil,
        oldValue: (any Sendable)? = nil
    ) {
        self.timestamp = Date()
        self.repositoryName = repositoryName
        self.changeType = changeType
        self.entityId = entityId
        self.newValue = newValue
        self.oldValue = oldValue
    }
}

// MARK: - State Transition Events

/// Event emitted when a state transition is accepted via the Accept action
///
/// StateObservers can subscribe to this event to react to state changes.
/// The event includes both the old and new states, plus entity context.
public struct StateTransitionEvent: RuntimeEvent {
    public static var eventType: String { "state.transition" }
    public let timestamp: Date

    /// The field name that transitioned (e.g., "status")
    public let fieldName: String

    /// The object name containing the field (e.g., "order")
    public let objectName: String

    /// The state before transition
    public let fromState: String

    /// The state after transition
    public let toState: String

    /// Entity ID if available (extracted from object's "id" field)
    public let entityId: String?

    /// The full object after transition (for context)
    public let entity: (any Sendable)?

    public init(
        fieldName: String,
        objectName: String,
        fromState: String,
        toState: String,
        entityId: String? = nil,
        entity: (any Sendable)? = nil
    ) {
        self.timestamp = Date()
        self.fieldName = fieldName
        self.objectName = objectName
        self.fromState = fromState
        self.toState = toState
        self.entityId = entityId
        self.entity = entity
    }
}
