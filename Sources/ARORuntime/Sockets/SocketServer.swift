// ============================================================
// SocketServer.swift
// ARO Runtime - Socket Server (SwiftNIO)
// ============================================================

import Foundation

// MARK: - Socket Types (Available on all platforms)

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

/// Wrapper for socket packet data, used by feature sets to extract data
public struct SocketPacket: Sendable {
    public let connectionId: String
    public let data: Data

    /// Get the buffer (data) from the packet
    public var buffer: Data { data }

    /// Get the connection ID
    public var connection: String { connectionId }

    public init(connectionId: String, data: Data) {
        self.connectionId = connectionId
        self.data = data
    }
}

/// Wrapper for socket connection info, used by feature sets
public struct SocketConnection: Sendable {
    public let id: String
    public let remoteAddress: String

    public init(id: String, remoteAddress: String) {
        self.id = id
        self.remoteAddress = remoteAddress
    }
}

/// Wrapper for socket disconnect info, used by feature sets
public struct SocketDisconnectInfo: Sendable {
    public let connectionId: String
    public let reason: String

    public init(connectionId: String, reason: String) {
        self.connectionId = connectionId
        self.reason = reason
    }
}

// MARK: - Socket Events (Available on all platforms)

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

// MARK: - SwiftNIO Implementation (macOS/Linux only)

#if !os(Windows)

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
        self.group = EventLoopGroupManager.shared.getEventLoopGroup()
    }

    deinit {
        // Event loop group shutdown is managed by EventLoopGroupManager
        // Don't shut down here as the group might be shared
    }

    // MARK: - SocketServerService

    public func start(port: Int) async throws {
        // Capture references for use in closures
        let server = self
        let bus = self.eventBus

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                // Create a NEW handler for each channel (handlers are stateful)
                let handler = SocketHandler(
                    eventBus: bus,
                    onConnect: { connectionId, chan in
                        server.addConnection(connectionId, channel: chan)
                    },
                    onDisconnect: { connectionId in
                        server.removeConnection(connectionId)
                    }
                )
                return channel.pipeline.addHandler(handler)
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

// MARK: - Socket Client (BSD Sockets)

/// Socket Client for outgoing TCP connections using BSD sockets.
///
/// Uses POSIX BSD sockets directly instead of SwiftNIO so that it works
/// in both interpreter mode (`aro run`) and compiled binary mode (`aro build`).
/// SwiftNIO's MultiThreadedEventLoopGroup crashes with SIGSEGV in LLVM binaries.
public final class AROSocketClient: @unchecked Sendable {
    // MARK: - Properties

    private let eventBus: EventBus
    private var socketFd: Int32 = -1
    private let lock = NSLock()
    private var _isConnected = false

    public let connectionId: String

    /// Whether the client is connected
    public var isConnected: Bool {
        withLock { _isConnected }
    }

    // MARK: - Thread-safe helpers

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func getFd() -> Int32 {
        withLock { socketFd }
    }

    /// Atomically clears socketFd / _isConnected and returns the old fd.
    private func takeFd() -> Int32 {
        withLock {
            let fd = socketFd
            socketFd = -1
            _isConnected = false
            return fd
        }
    }

    // MARK: - Initialization

    public init(eventBus: EventBus = .shared) {
        self.eventBus = eventBus
        self.connectionId = UUID().uuidString
    }

    deinit {
        let fd = takeFd()
        if fd >= 0 { _ = bsdClose(fd) }
    }

    // MARK: - Connection

    /// Connect to a server. Resolves hostname, connects, and starts the receive loop.
    public func connect(host: String, port: Int) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .utility).async { [self] in
                do {
                    try self.connectBlocking(host: host, port: port)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func connectBlocking(host: String, port: Int) throws {
        // SOCK_STREAM is Int32 on macOS but __socket_type on Linux
        #if canImport(Darwin)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else {
            throw SocketError.connectionFailed("socket() failed (errno \(errno))")
        }

        // Resolve host and port via getaddrinfo — handles both IPs and hostnames
        var hints = addrinfo()
        hints.ai_family = AF_INET
        #if canImport(Darwin)
        hints.ai_socktype = SOCK_STREAM
        #else
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #endif
        var res: UnsafeMutablePointer<addrinfo>? = nil
        let gaiStatus = getaddrinfo(host, "\(port)", &hints, &res)
        guard gaiStatus == 0, let addrRes = res else {
            _ = bsdClose(fd)
            let msg = gai_strerror(gaiStatus).map { String(cString: $0) } ?? "\(gaiStatus)"
            throw SocketError.connectionFailed("Cannot resolve \(host): \(msg)")
        }
        defer { freeaddrinfo(res) }

        let connectResult: Int32
        #if canImport(Darwin)
        connectResult = Darwin.connect(fd, addrRes.pointee.ai_addr, addrRes.pointee.ai_addrlen)
        #else
        connectResult = Glibc.connect(fd, addrRes.pointee.ai_addr, addrRes.pointee.ai_addrlen)
        #endif

        guard connectResult == 0 else {
            _ = bsdClose(fd)
            throw SocketError.connectionFailed("connect() to \(host):\(port) failed (errno \(errno))")
        }

        withLock {
            socketFd = fd
            _isConnected = true
        }

        eventBus.publish(ClientConnectedEvent(connectionId: connectionId, remoteAddress: "\(host):\(port)"))
        // Co-publish DomainEvent for binary mode handlers
        EventBus.shared.publish(DomainEvent(
            eventType: "socket.connected",
            payload: ["connection": ["id": connectionId, "remoteAddress": "\(host):\(port)"] as [String: any Sendable]]
        ))

        // Start receive loop on a background thread
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.receiveLoop()
        }
    }

    private func receiveLoop() {
        var buffer = [UInt8](repeating: 0, count: 4096)

        while true {
            let fd = getFd()
            guard fd >= 0 else { break }

            let n = recv(fd, &buffer, buffer.count, 0)
            if n <= 0 { break }

            let data = Data(buffer[0..<n])
            eventBus.publish(DataReceivedEvent(connectionId: connectionId, data: data))
            // Co-publish DomainEvent for binary mode handlers
            let msgStr = String(data: data, encoding: .utf8) ?? ""
            EventBus.shared.publish(DomainEvent(
                eventType: "socket.data",
                payload: ["packet": ["message": msgStr, "buffer": msgStr, "data": msgStr, "connection": connectionId] as [String: any Sendable]]
            ))
        }

        let fd = takeFd()
        if fd >= 0 { _ = bsdClose(fd) }
        eventBus.publish(ClientDisconnectedEvent(connectionId: connectionId, reason: "connection closed"))
        EventBus.shared.publish(DomainEvent(
            eventType: "socket.disconnected",
            payload: ["event": ["connectionId": connectionId, "reason": "connection closed"] as [String: any Sendable]]
        ))
    }

    /// Disconnect from server
    public func disconnect() async throws {
        let fd = takeFd()
        if fd >= 0 { _ = bsdClose(fd) }
        eventBus.publish(ClientDisconnectedEvent(connectionId: connectionId, reason: "disconnect requested"))
        EventBus.shared.publish(DomainEvent(
            eventType: "socket.disconnected",
            payload: ["event": ["connectionId": connectionId, "reason": "disconnect requested"] as [String: any Sendable]]
        ))
    }

    // MARK: - Send

    /// Send raw data
    public func send(data: Data) async throws {
        let fd = getFd()
        guard fd >= 0 else { throw SocketError.notConnected }

        let sent = data.withUnsafeBytes { buf in
            bsdSend(fd, buf.baseAddress!, data.count, 0)
        }
        if sent < 0 {
            throw SocketError.connectionFailed("send() failed (errno \(errno))")
        }
    }

    /// Send a UTF-8 string
    public func send(string: String) async throws {
        guard let data = string.data(using: .utf8) else {
            throw SocketError.encodingError
        }
        try await send(data: data)
    }

    // MARK: - Platform helpers

    @discardableResult
    private func bsdClose(_ fd: Int32) -> Int32 {
        #if canImport(Darwin)
        return Darwin.close(fd)
        #else
        return Glibc.close(fd)
        #endif
    }

    private func bsdSend(_ fd: Int32, _ buf: UnsafeRawPointer!, _ len: Int, _ flags: Int32) -> Int {
        #if canImport(Darwin)
        return Darwin.send(fd, buf, len, flags)
        #else
        return Glibc.send(fd, buf, len, flags)
        #endif
    }
}

#endif  // !os(Windows)
