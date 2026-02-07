// ============================================================
// WebSocketServer.swift
// ARO Runtime - WebSocket Server (SwiftNIO)
// ============================================================

import Foundation

// MARK: - WebSocket Types (Available on all platforms)

/// Errors that can occur during WebSocket operations
public enum WebSocketError: Error, Sendable {
    case notConnected
    case connectionNotFound(String)
    case encodingError
    case serverNotEnabled
}

extension WebSocketError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .notConnected:
            return "WebSocket not connected"
        case .connectionNotFound(let id):
            return "WebSocket connection not found: \(id)"
        case .encodingError:
            return "String encoding error"
        case .serverNotEnabled:
            return "WebSocket server is not enabled"
        }
    }
}

/// Wrapper for WebSocket connection info
public struct WebSocketConnectionInfo: Sendable {
    public let id: String
    public let path: String
    public let remoteAddress: String

    public init(id: String, path: String, remoteAddress: String) {
        self.id = id
        self.path = path
        self.remoteAddress = remoteAddress
    }
}

/// Wrapper for WebSocket message info
public struct WebSocketMessageInfo: Sendable {
    public let connectionId: String
    public let message: String

    public init(connectionId: String, message: String) {
        self.connectionId = connectionId
        self.message = message
    }
}

/// Wrapper for WebSocket disconnect info
public struct WebSocketDisconnectInfo: Sendable {
    public let connectionId: String
    public let reason: String

    public init(connectionId: String, reason: String) {
        self.connectionId = connectionId
        self.reason = reason
    }
}

// MARK: - WebSocket Service Protocol

/// Protocol for WebSocket server service
public protocol WebSocketServerService: Sendable {
    /// Number of active WebSocket connections
    var connectionCount: Int { get }

    /// Check if WebSocket server is enabled
    func isEnabled() -> Bool

    /// Check if a connection ID is a WebSocket connection
    func isWebSocketConnection(_ connectionId: String) -> Bool

    /// Send a text message to a specific connection
    func send(message: String, to connectionId: String) async throws

    /// Broadcast a text message to all WebSocket connections
    func broadcast(message: String) async throws

    /// Close a specific WebSocket connection
    func close(_ connectionId: String) async throws
}

// MARK: - SwiftNIO Implementation (macOS/Linux only)

#if !os(Windows)

import NIO
import NIOHTTP1
import NIOWebSocket

/// WebSocket Server implementation using SwiftNIO
///
/// Provides WebSocket functionality integrated with the HTTP server
/// through HTTP Upgrade mechanism.
public final class AROWebSocketServer: WebSocketServerService, @unchecked Sendable {
    // MARK: - Properties

    private let eventBus: EventBus
    private var connections: [String: WebSocketConnection] = [:]
    private let lock = NSLock()
    private var enabled: Bool = false

    /// WebSocket path (default: /ws)
    public let path: String

    /// Number of active connections
    public var connectionCount: Int {
        withLock { connections.count }
    }

    // MARK: - Connection Wrapper

    private struct WebSocketConnection: @unchecked Sendable {
        let channel: Channel
        let path: String
        let remoteAddress: String
    }

    // MARK: - Thread-safe helpers

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: - Initialization

    public init(path: String = "/ws", eventBus: EventBus = .shared) {
        self.path = path
        self.eventBus = eventBus
    }

    // MARK: - Enable/Disable

    /// Enable WebSocket server
    public func enable() {
        withLock { enabled = true }
    }

    /// Disable WebSocket server
    public func disable() {
        withLock { enabled = false }
    }

    // MARK: - WebSocketServerService

    public func isEnabled() -> Bool {
        withLock { enabled }
    }

    public func isWebSocketConnection(_ connectionId: String) -> Bool {
        withLock { connections[connectionId] != nil }
    }

    public func send(message: String, to connectionId: String) async throws {
        guard let connection = withLock({ connections[connectionId] }) else {
            throw WebSocketError.connectionNotFound(connectionId)
        }

        var buffer = connection.channel.allocator.buffer(capacity: message.utf8.count)
        buffer.writeString(message)

        let frame = WebSocketFrame(fin: true, opcode: .text, data: buffer)
        try await connection.channel.writeAndFlush(frame)
    }

    public func broadcast(message: String) async throws {
        let conns = withLock { Array(connections.values) }

        for connection in conns {
            var buffer = connection.channel.allocator.buffer(capacity: message.utf8.count)
            buffer.writeString(message)

            let frame = WebSocketFrame(fin: true, opcode: .text, data: buffer)
            try? await connection.channel.writeAndFlush(frame)
        }
    }

    public func close(_ connectionId: String) async throws {
        guard let connection = withLock({ connections.removeValue(forKey: connectionId) }) else {
            return
        }

        // Send close frame
        var buffer = connection.channel.allocator.buffer(capacity: 2)
        buffer.writeInteger(UInt16(1000).bigEndian)  // Normal closure

        let frame = WebSocketFrame(fin: true, opcode: .connectionClose, data: buffer)
        try? await connection.channel.writeAndFlush(frame)
        try? await connection.channel.close()
    }

    // MARK: - Connection Management (called by WebSocket handler)

    /// Add a new WebSocket connection
    func addConnection(id: String, channel: Channel, path: String, remoteAddress: String) {
        let conn = WebSocketConnection(channel: channel, path: path, remoteAddress: remoteAddress)
        withLock { connections[id] = conn }

        eventBus.publish(WebSocketConnectedEvent(
            connectionId: id,
            path: path,
            remoteAddress: remoteAddress
        ))
    }

    /// Remove a WebSocket connection
    func removeConnection(id: String, reason: String = "closed") {
        let removed = withLock { connections.removeValue(forKey: id) != nil }

        if removed {
            eventBus.publish(WebSocketDisconnectedEvent(
                connectionId: id,
                reason: reason
            ))
        }
    }

    /// Handle incoming WebSocket message
    func handleMessage(connectionId: String, message: String) {
        eventBus.publish(WebSocketMessageEvent(
            connectionId: connectionId,
            message: message
        ))
    }

    // MARK: - Upgrade Handler Factory

    /// Create a channel handler for WebSocket upgrade
    /// Called by HTTPServer when WebSocket upgrade is detected
    public func createUpgradeHandler(
        connectionId: String,
        path: String,
        remoteAddress: String
    ) -> ChannelHandler {
        WebSocketHandler(
            server: self,
            connectionId: connectionId,
            path: path,
            remoteAddress: remoteAddress
        )
    }
}

// MARK: - WebSocket Handler

private final class WebSocketHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let server: AROWebSocketServer
    private let connectionId: String
    private let path: String
    private let remoteAddress: String
    private var hasRegistered = false

    init(server: AROWebSocketServer, connectionId: String, path: String, remoteAddress: String) {
        self.server = server
        self.connectionId = connectionId
        self.path = path
        self.remoteAddress = remoteAddress
    }

    func handlerAdded(context: ChannelHandlerContext) {
        // Register connection when handler is added to pipeline
        // (channelActive won't be called for upgrades since channel is already active)
        if !hasRegistered {
            server.addConnection(
                id: connectionId,
                channel: context.channel,
                path: path,
                remoteAddress: remoteAddress
            )
            hasRegistered = true
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        // Also register on channel active (for non-upgrade scenarios)
        if !hasRegistered {
            server.addConnection(
                id: connectionId,
                channel: context.channel,
                path: path,
                remoteAddress: remoteAddress
            )
            hasRegistered = true
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        server.removeConnection(id: connectionId, reason: "connection closed")
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)

        switch frame.opcode {
        case .text:
            // Handle text message
            var data = frame.data
            if let text = data.readString(length: data.readableBytes) {
                server.handleMessage(connectionId: connectionId, message: text)
            }

        case .binary:
            // Convert binary to text and handle
            var data = frame.data
            if let text = data.readString(length: data.readableBytes) {
                server.handleMessage(connectionId: connectionId, message: text)
            }

        case .ping:
            // Respond with pong
            var pongData = context.channel.allocator.buffer(capacity: frame.data.readableBytes)
            pongData.writeImmutableBuffer(frame.data)
            let pong = WebSocketFrame(fin: true, opcode: .pong, data: pongData)
            context.writeAndFlush(wrapOutboundOut(pong), promise: nil)

        case .pong:
            // Ignore pong (keep-alive response)
            break

        case .connectionClose:
            // Handle close frame
            server.removeConnection(id: connectionId, reason: "client closed")
            // Echo close frame
            var closeData = context.channel.allocator.buffer(capacity: 2)
            closeData.writeInteger(UInt16(1000).bigEndian)
            let close = WebSocketFrame(fin: true, opcode: .connectionClose, data: closeData)
            context.writeAndFlush(wrapOutboundOut(close)).whenComplete { _ in
                context.close(promise: nil)
            }

        case .continuation:
            // Handle continuation frames (for large messages)
            // For simplicity, we don't support fragmented messages yet
            break

        default:
            break
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        server.removeConnection(id: connectionId, reason: "error: \(error.localizedDescription)")
        context.close(promise: nil)
    }
}

// MARK: - WebSocket Upgrader

/// Creates the upgrader configuration for HTTP to WebSocket upgrade
public func createWebSocketUpgrader(
    server: AROWebSocketServer,
    path: String = "/ws"
) -> NIOWebSocketServerUpgrader {
    NIOWebSocketServerUpgrader(
        shouldUpgrade: { channel, head in
            // Only upgrade if path matches
            let requestPath = head.uri.split(separator: "?").first.map(String.init) ?? head.uri
            if requestPath == path {
                // IMPORTANT: Remove HTTP handler BEFORE upgrade proceeds.
                // This must happen before NIO adds WebSocket handlers,
                // otherwise our HTTP handler ends up at the front of the pipeline
                // and receives raw WebSocket bytes it can't decode.
                return channel.pipeline.removeHandler(name: "AROHTTPHandler")
                    .map { _ in [:] as HTTPHeaders }
                    .flatMapError { _ in
                        // Handler might not exist, that's OK
                        channel.eventLoop.makeSucceededFuture([:] as HTTPHeaders)
                    }
            }
            return channel.eventLoop.makeSucceededFuture(nil)
        },
        upgradePipelineHandler: { channel, head in
            let connectionId = UUID().uuidString
            let remoteAddress = channel.remoteAddress?.description ?? "unknown"
            let requestPath = head.uri.split(separator: "?").first.map(String.init) ?? head.uri

            let handler = server.createUpgradeHandler(
                connectionId: connectionId,
                path: requestPath,
                remoteAddress: remoteAddress
            )

            // HTTP handler was already removed in shouldUpgrade.
            // Just add the WebSocket handler.
            return channel.pipeline.addHandler(handler)
        }
    )
}

#endif  // !os(Windows)
