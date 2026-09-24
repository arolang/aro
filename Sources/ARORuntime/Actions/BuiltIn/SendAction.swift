// ============================================================
// SendAction.swift
// ARO Runtime - Send: handing data to an external destination
// ============================================================

import Foundation
import AROParser

/// Sends data to an external destination
public struct SendAction: ActionImplementation {
    public static let role: ActionRole = .response
    public static let verbs: Set<String> = ["send", "dispatch"]
    public static let validPrepositions: Set<Preposition> = [.to, .via, .with]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        // Get data to send
        guard let data = context.resolveAny(result.base) else {
            throw ActionError.undefinedVariable(result.base)
        }

        // Get destination - could be a connection ID variable or literal
        let destination: String
        if let resolvedDest: String = context.resolve(object.base) {
            destination = resolvedDest
        } else {
            destination = object.base
        }

        // Try socket server service first (for server-side connection IDs)
        #if !os(Windows)
        if let socketServer = context.service(SocketServerService.self) {
            // Try to send to socket connection
            do {
                if let dataValue = data as? Data {
                    try await socketServer.send(data: dataValue, to: destination)
                } else if let stringValue = data as? String {
                    try await socketServer.send(string: stringValue, to: destination)
                } else {
                    // Convert to string
                    try await socketServer.send(string: String(describing: data), to: destination)
                }
                return SendResult(destination: destination, success: true)
            } catch {
                // Connection not found in server - fall through to client
            }
        }

        // Try socket client (for client-side connection IDs from Connect action)
        if let socketClient: AROSocketClient = context.service(AROSocketClient.self),
           socketClient.connectionId == destination,
           socketClient.isConnected {
            do {
                if let dataValue = data as? Data {
                    try await socketClient.send(data: dataValue)
                } else if let stringValue = data as? String {
                    try await socketClient.send(string: stringValue)
                } else {
                    try await socketClient.send(string: String(describing: data))
                }
                return SendResult(destination: destination, success: true)
            } catch {
                // Fall through to other services
            }
        }


        // Try the native BSD socket server (compiled binaries).
        //
        // A compiled binary registers no `SocketServerService` on purpose — the
        // NIO server cannot be wired up there — so both attempts above find
        // nothing and a server's `Send the <welcome> to the <client>.` used to
        // fall through to the event emission below, which reports success
        // without writing a byte (GitLab #881). Broadcast already consulted the
        // native server; send now does too, and only claims success if the
        // connection was actually written to.
        let payload: Data
        if let dataValue = data as? Data {
            payload = dataValue
        } else if let stringValue = data as? String {
            payload = Data(stringValue.utf8)
        } else {
            payload = Data(String(describing: data).utf8)
        }
        if NativeSocketBroadcaster.shared.send(data: payload, to: destination) {
            return SendResult(destination: destination, success: true)
        }
        #endif

        // Try messaging service
        if let messagingService = context.service(MessagingService.self) {
            try await messagingService.send(data: data, to: destination)
            return SendResult(destination: destination, success: true)
        }

        // Emit as event
        context.emit(MessageSentEvent(destination: destination, data: String(describing: data)))

        return SendResult(destination: destination, success: true)
    }
}

/// Messaging service protocol
public protocol MessagingService: Sendable {
    func send(data: Any, to destination: String) async throws
}

/// Result of a send operation
public struct SendResult: Sendable, Equatable {
    public let destination: String
    public let success: Bool
}

/// Event emitted when a message is sent
public struct MessageSentEvent: RuntimeEvent {
    public static var eventType: String { "message.sent" }
    public let timestamp: Date
    public let destination: String
    public let data: String

    public init(destination: String, data: String) {
        self.timestamp = Date()
        self.destination = destination
        self.data = data
    }
}
