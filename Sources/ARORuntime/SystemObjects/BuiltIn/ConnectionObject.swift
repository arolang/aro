// ============================================================
// ConnectionObject.swift
// ARO Runtime - Socket Connection System Object
// ============================================================

import Foundation

// MARK: - Connection Send Protocol

/// Protocol for sending data through a connection
public protocol ConnectionSender: Sendable {
    func send(_ data: Data) async throws
}

// MARK: - Connection Object

/// Socket connection system object
///
/// A bidirectional context object for socket connections.
/// Only available in socket handler feature sets.
///
/// ## ARO Usage
/// ```aro
/// <Extract> the <id> from the <connection: id>.
/// <Send> <message> to the <connection>.
/// ```
public struct ConnectionObject: SystemObject {
    public static let identifier = "connection"
    public static let description = "Socket connection"

    public var capabilities: SystemObjectCapabilities { .bidirectional }

    private let connectionId: String
    private let remoteAddress: String
    private let sender: (any ConnectionSender)?

    /// Create a connection object
    public init(
        connectionId: String,
        remoteAddress: String,
        sender: (any ConnectionSender)? = nil
    ) {
        self.connectionId = connectionId
        self.remoteAddress = remoteAddress
        self.sender = sender
    }

    public func read(property: String?) async throws -> any Sendable {
        guard let property = property else {
            // Return connection info
            return [
                "id": connectionId,
                "remoteAddress": remoteAddress
            ] as [String: any Sendable]
        }

        switch property {
        case "id":
            return connectionId
        case "remoteAddress", "remote", "address":
            return remoteAddress
        default:
            throw SystemObjectError.propertyNotFound(property, in: Self.identifier)
        }
    }

    public func write(_ value: any Sendable) async throws {
        guard let sender = sender else {
            throw SystemObjectError.notWritable(Self.identifier)
        }

        // Convert value to data
        let data: Data
        if let stringValue = value as? String {
            data = Data(stringValue.utf8)
        } else if let dataValue = value as? Data {
            data = dataValue
        } else {
            // Serialize as JSON
            let jsonData = try JSONSerialization.data(
                withJSONObject: value,
                options: []
            )
            data = jsonData
        }

        try await sender.send(data)
    }
}

// MARK: - Packet Object

/// Socket packet system object
///
/// A source-only context object for received socket data.
/// Only available in socket data handler feature sets.
///
/// ## ARO Usage
/// ```aro
/// <Extract> the <data> from the <packet: buffer>.
/// <Extract> the <timestamp> from the <packet: timestamp>.
/// ```
public struct PacketObject: SystemObject {
    public static let identifier = "packet"
    public static let description = "Socket data packet"

    public var capabilities: SystemObjectCapabilities { .source }

    private let buffer: Data
    private let connectionId: String
    private let timestamp: Date

    /// Create a packet object
    public init(
        buffer: Data,
        connectionId: String,
        timestamp: Date = Date()
    ) {
        self.buffer = buffer
        self.connectionId = connectionId
        self.timestamp = timestamp
    }

    public func read(property: String?) async throws -> any Sendable {
        guard let property = property else {
            // Return full packet info
            return [
                "buffer": String(data: buffer, encoding: .utf8) ?? "",
                "connectionId": connectionId,
                "timestamp": ISO8601DateFormatter().string(from: timestamp),
                "size": buffer.count
            ] as [String: any Sendable]
        }

        switch property {
        case "buffer", "data":
            // Try to return as string, fall back to raw data description
            return String(data: buffer, encoding: .utf8) ?? buffer.description
        case "connectionId", "connection":
            return connectionId
        case "timestamp":
            return ISO8601DateFormatter().string(from: timestamp)
        case "size", "length":
            return buffer.count
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
    /// Register socket-related system objects
    func registerSocketObjects() {
        register(
            "connection",
            description: ConnectionObject.description,
            capabilities: .bidirectional
        ) { _ in
            PlaceholderConnectionObject()
        }

        register(
            "packet",
            description: PacketObject.description,
            capabilities: .source
        ) { _ in
            PlaceholderPacketObject()
        }
    }
}

// MARK: - Placeholders for Registration

/// Placeholder for connection objects when not in a socket handler
private struct PlaceholderConnectionObject: SystemObject {
    static let identifier = "connection"
    static let description = "Socket connection (only available in socket handlers)"

    var capabilities: SystemObjectCapabilities { .bidirectional }

    func read(property: String?) async throws -> any Sendable {
        throw SystemObjectError.notAvailableInContext(Self.identifier, context: "non-socket")
    }

    func write(_ value: any Sendable) async throws {
        throw SystemObjectError.notAvailableInContext(Self.identifier, context: "non-socket")
    }
}

/// Placeholder for packet objects when not in a socket data handler
private struct PlaceholderPacketObject: SystemObject {
    static let identifier = "packet"
    static let description = "Socket data packet (only available in socket data handlers)"

    var capabilities: SystemObjectCapabilities { .source }

    func read(property: String?) async throws -> any Sendable {
        throw SystemObjectError.notAvailableInContext(Self.identifier, context: "non-socket")
    }

    func write(_ value: any Sendable) async throws {
        throw SystemObjectError.notWritable(Self.identifier)
    }
}
