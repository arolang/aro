// ============================================================
// SocketServer.swift
// ARO Runtime - Socket Server (SwiftNIO)
// ============================================================

import Foundation
import NIO

/// Socket Server implementation using SwiftNIO
///
/// Provides TCP socket server functionality with event-driven
/// communication for ARO applications.
public final class AROSocketServer: SocketServerService, @unchecked Sendable {
    // MARK: - Properties

    private let eventBus: EventBus
    private var channel: Channel?
    private let group: MultiThreadedEventLoopGroup
    private var connections: [String: Channel] = [:]
    private let lock = NSLock()

    /// Current port the server is listening on
    public private(set) var port: Int = 0

    /// Whether the server is running
    public var isRunning: Bool {
        withLock { channel != nil }
    }

    /// Number of active connections
    public var connectionCount: Int {
        withLock { connections.count }
    }

    // MARK: - Thread-safe helpers

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func setChannel(_ newChannel: Channel?) {
        withLock { channel = newChannel }
    }

    private func getChannel() -> Channel? {
        withLock { channel }
    }

    private func getConnections() -> [String: Channel] {
        withLock { connections }
    }

    private func getConnection(_ id: String) -> Channel? {
        withLock { connections[id] }
    }

    private func clearConnections() {
        withLock { connections.removeAll() }
    }

    private func removeAndGetConnection(_ id: String) -> Channel? {
        withLock { connections.removeValue(forKey: id) }
    }

    // MARK: - Initialization

    public init(eventBus: EventBus = .shared) {
        self.eventBus = eventBus
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
    }

    deinit {
        try? group.syncShutdownGracefully()
    }

    // MARK: - SocketServerService

    public func start(port: Int) async throws {
        let handler = SocketHandler(
            eventBus: eventBus,
            onConnect: { [weak self] connectionId, channel in
                self?.addConnection(connectionId, channel: channel)
            },
            onDisconnect: { [weak self] connectionId in
                self?.removeConnection(connectionId)
            }
        )

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(handler)
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)

        let channel = try await bootstrap.bind(host: "0.0.0.0", port: port).get()

        setChannel(channel)
        self.port = port

        eventBus.publish(SocketServerStartedEvent(port: port))

        print("Socket Server started on port \(port)")
    }

    public func stop() async throws {
        let ch = getChannel()
        let conns = getConnections()

        // Close all connections
        for (_, connection) in conns {
            try? await connection.close()
        }

        if let channel = ch {
            try await channel.close()

            setChannel(nil)
            clearConnections()

            eventBus.publish(SocketServerStoppedEvent())
            print("Socket Server stopped")
        }
    }

    // MARK: - Send Data

    /// Send data to a specific connection
    public func send(data: Data, to connectionId: String) async throws {
        guard let channel = getConnection(connectionId) else {
            throw SocketError.connectionNotFound(connectionId)
        }

        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)

        try await channel.writeAndFlush(buffer)
    }

    /// Send string to a specific connection
    public func send(string: String, to connectionId: String) async throws {
        guard let data = string.data(using: .utf8) else {
            throw SocketError.encodingError
        }
        try await send(data: data, to: connectionId)
    }

    /// Broadcast data to all connections
    public func broadcast(data: Data) async throws {
        let conns = Array(getConnections().values)

        for channel in conns {
            var buffer = channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            try? await channel.writeAndFlush(buffer)
        }
    }

    /// Disconnect a client
    public func disconnect(_ connectionId: String) async throws {
        if let channel = removeAndGetConnection(connectionId) {
            try await channel.close()
        }
    }

    // MARK: - Private

    private func addConnection(_ connectionId: String, channel: Channel) {
        lock.lock()
        connections[connectionId] = channel
        lock.unlock()
    }

    private func removeConnection(_ connectionId: String) {
        lock.lock()
        connections.removeValue(forKey: connectionId)
        lock.unlock()
    }
}

// MARK: - Socket Handler

private final class SocketHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let eventBus: EventBus
    private let onConnect: (String, Channel) -> Void
    private let onDisconnect: (String) -> Void
    private var connectionId: String?

    init(
        eventBus: EventBus,
        onConnect: @escaping (String, Channel) -> Void,
        onDisconnect: @escaping (String) -> Void
    ) {
        self.eventBus = eventBus
        self.onConnect = onConnect
        self.onDisconnect = onDisconnect
    }

    func channelActive(context: ChannelHandlerContext) {
        let id = UUID().uuidString
        self.connectionId = id

        let remoteAddress = context.remoteAddress?.description ?? "unknown"

        onConnect(id, context.channel)
        eventBus.publish(ClientConnectedEvent(connectionId: id, remoteAddress: remoteAddress))
    }

    func channelInactive(context: ChannelHandlerContext) {
        if let id = connectionId {
            onDisconnect(id)
            eventBus.publish(ClientDisconnectedEvent(connectionId: id, reason: "connection closed"))
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        guard let id = connectionId,
              let bytes = buffer.readBytes(length: buffer.readableBytes) else {
            return
        }

        let receivedData = Data(bytes)
        eventBus.publish(DataReceivedEvent(connectionId: id, data: receivedData))
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if let id = connectionId {
            eventBus.publish(SocketErrorEvent(connectionId: id, error: error.localizedDescription))
        }
        context.close(promise: nil)
    }
}

// MARK: - Socket Client

/// Socket Client for outgoing TCP connections
public final class AROSocketClient: @unchecked Sendable {
    // MARK: - Properties

    private let eventBus: EventBus
    private var channel: Channel?
    private let group: MultiThreadedEventLoopGroup
    private let lock = NSLock()

    public let connectionId: String

    /// Whether the client is connected
    public var isConnected: Bool {
        withLock { channel != nil }
    }

    // MARK: - Thread-safe helpers

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func setChannel(_ newChannel: Channel?) {
        withLock { channel = newChannel }
    }

    private func getChannel() -> Channel? {
        withLock { channel }
    }

    // MARK: - Initialization

    public init(eventBus: EventBus = .shared) {
        self.eventBus = eventBus
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.connectionId = UUID().uuidString
    }

    deinit {
        try? group.syncShutdownGracefully()
    }

    // MARK: - Connection

    /// Connect to a server
    public func connect(host: String, port: Int) async throws {
        let handler = ClientHandler(
            eventBus: eventBus,
            connectionId: connectionId,
            onDisconnect: { [weak self] in
                self?.setChannel(nil)
            }
        )

        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                channel.pipeline.addHandler(handler)
            }

        let channel = try await bootstrap.connect(host: host, port: port).get()

        setChannel(channel)

        eventBus.publish(ClientConnectedEvent(connectionId: connectionId, remoteAddress: "\(host):\(port)"))
    }

    /// Disconnect from server
    public func disconnect() async throws {
        let ch = getChannel()

        if let channel = ch {
            try await channel.close()

            setChannel(nil)

            eventBus.publish(ClientDisconnectedEvent(connectionId: connectionId, reason: "disconnect requested"))
        }
    }

    /// Send data
    public func send(data: Data) async throws {
        guard let channel = getChannel() else {
            throw SocketError.notConnected
        }

        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)

        try await channel.writeAndFlush(buffer)
    }

    /// Send string
    public func send(string: String) async throws {
        guard let data = string.data(using: .utf8) else {
            throw SocketError.encodingError
        }
        try await send(data: data)
    }
}

// MARK: - Client Handler

private final class ClientHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let eventBus: EventBus
    private let connectionId: String
    private let onDisconnect: () -> Void

    init(eventBus: EventBus, connectionId: String, onDisconnect: @escaping () -> Void) {
        self.eventBus = eventBus
        self.connectionId = connectionId
        self.onDisconnect = onDisconnect
    }

    func channelInactive(context: ChannelHandlerContext) {
        onDisconnect()
        eventBus.publish(ClientDisconnectedEvent(connectionId: connectionId, reason: "connection closed"))
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        guard let bytes = buffer.readBytes(length: buffer.readableBytes) else {
            return
        }

        let receivedData = Data(bytes)
        eventBus.publish(DataReceivedEvent(connectionId: connectionId, data: receivedData))
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        eventBus.publish(SocketErrorEvent(connectionId: connectionId, error: error.localizedDescription))
        context.close(promise: nil)
    }
}

// MARK: - Socket Errors

/// Errors that can occur during socket operations
public enum SocketError: Error, Sendable {
    case notConnected
    case connectionNotFound(String)
    case connectionFailed(String)
    case encodingError
    case timeout
}

extension SocketError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .notConnected:
            return "Not connected"
        case .connectionNotFound(let id):
            return "Connection not found: \(id)"
        case .connectionFailed(let reason):
            return "Connection failed: \(reason)"
        case .encodingError:
            return "String encoding error"
        case .timeout:
            return "Connection timeout"
        }
    }
}

// MARK: - Socket Events

/// Event emitted when socket server starts
public struct SocketServerStartedEvent: RuntimeEvent {
    public static var eventType: String { "socket.server.started" }
    public let timestamp: Date
    public let port: Int

    public init(port: Int) {
        self.timestamp = Date()
        self.port = port
    }
}

/// Event emitted when socket server stops
public struct SocketServerStoppedEvent: RuntimeEvent {
    public static var eventType: String { "socket.server.stopped" }
    public let timestamp: Date

    public init() {
        self.timestamp = Date()
    }
}

/// Event emitted when a socket error occurs
public struct SocketErrorEvent: RuntimeEvent {
    public static var eventType: String { "socket.error" }
    public let timestamp: Date
    public let connectionId: String
    public let error: String

    public init(connectionId: String, error: String) {
        self.timestamp = Date()
        self.connectionId = connectionId
        self.error = error
    }
}
