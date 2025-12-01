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
    public let executionId: String

    public init(featureSetName: String, executionId: String) {
        self.timestamp = Date()
        self.featureSetName = featureSetName
        self.executionId = executionId
    }
}

/// Feature set completed event
public struct FeatureSetCompletedEvent: RuntimeEvent {
    public static var eventType: String { "featureset.completed" }
    public let timestamp: Date
    public let featureSetName: String
    public let executionId: String
    public let success: Bool
    public let durationMs: Double

    public init(featureSetName: String, executionId: String, success: Bool, durationMs: Double) {
        self.timestamp = Date()
        self.featureSetName = featureSetName
        self.executionId = executionId
        self.success = success
        self.durationMs = durationMs
    }
}
