// ============================================================
// WindowsSocketServer.swift
// ARO Runtime - Socket Server for Windows (FlyingSocks)
// ============================================================
//
// Windows-specific TCP socket server implementation using FlyingSocks.
// FlyingSocks is part of FlyingFox and provides BSD socket support
// with Swift Concurrency, including experimental Windows support.

#if os(Windows)

import Foundation
import FlyingSocks

/// Socket Server implementation for Windows using FlyingSocks
///
/// Provides TCP socket server functionality on Windows platform where
/// SwiftNIO is not available.
public final class WindowsSocketServer: SocketServerService, @unchecked Sendable {
    // MARK: - Properties

    private let eventBus: EventBus
    private var socket: Socket?
    private var serverTask: Task<Void, Error>?
    private var connections: [String: Socket] = [:]
    private let lock = NSLock()

    /// Current port the server is listening on
    public private(set) var port: Int = 0

    /// Whether the server is running
    public var isRunning: Bool {
        withLock { socket != nil }
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

    // MARK: - Initialization

    public init(eventBus: EventBus = .shared) {
        self.eventBus = eventBus
    }

    // MARK: - SocketServerService

    public func start(port: Int) async throws {
        // Create listening socket
        let address = try Socket.makeAddressINET(port: UInt16(port))
        let serverSocket = try Socket(domain: Int32(AF_INET), type: Int32(SOCK_STREAM))
        try serverSocket.setValue(true, for: .localAddressReuse)
        try serverSocket.bind(to: address)
        try serverSocket.listen()

        // Store socket reference (using withLock for async-safe access)
        withLock {
            self.socket = serverSocket
            self.port = port
        }

        // Start accepting connections
        serverTask = Task {
            await self.acceptConnections(serverSocket)
        }

        eventBus.publish(SocketServerStartedEvent(port: port))

        print("Socket Server started on port \(port) (Windows/FlyingSocks)")
    }

    public func stop() async throws {
        // Get current state atomically
        let (serverSocket, task, conns) = withLock {
            let s = socket
            let t = serverTask
            let c = Array(connections.values)
            socket = nil
            serverTask = nil
            connections.removeAll()
            return (s, t, c)
        }

        // Close all connections
        for conn in conns {
            try? conn.close()
        }

        // Close server socket and cancel task
        if let serverSocket = serverSocket {
            try? serverSocket.close()
            task?.cancel()

            eventBus.publish(SocketServerStoppedEvent())
            print("Socket Server stopped (Windows/FlyingSocks)")
        }
    }

    // MARK: - Send Data

    public func send(data: Data, to connectionId: String) async throws {
        guard let conn = withLock({ connections[connectionId] }) else {
            throw SocketError.connectionNotFound(connectionId)
        }

        try conn.write(data)
    }

    public func send(string: String, to connectionId: String) async throws {
        guard let data = string.data(using: .utf8) else {
            throw SocketError.encodingError
        }
        try await send(data: data, to: connectionId)
    }

    public func broadcast(data: Data) async throws {
        let conns = withLock { Array(connections.values) }

        for conn in conns {
            try? conn.write(data)
        }
    }

    // MARK: - Private

    private func acceptConnections(_ serverSocket: Socket) async {
        while !Task.isCancelled {
            do {
                let clientSocket = try await serverSocket.accept()
                let connectionId = UUID().uuidString

                // Store connection (using withLock for async-safe access)
                withLock {
                    connections[connectionId] = clientSocket
                }

                // Get remote address (if available)
                let remoteAddress = "unknown"

                eventBus.publish(ClientConnectedEvent(connectionId: connectionId, remoteAddress: remoteAddress))

                // Handle client in separate task
                Task {
                    await self.handleClient(clientSocket, connectionId: connectionId)
                }
            } catch {
                if !Task.isCancelled {
                    print("Socket accept error: \(error)")
                }
                break
            }
        }
    }

    private func handleClient(_ socket: Socket, connectionId: String) async {
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)

        while !Task.isCancelled {
            do {
                let bytesRead = try socket.read(&buffer, length: bufferSize)
                if bytesRead == 0 {
                    // Connection closed
                    break
                }

                let data = Data(bytes: buffer, count: bytesRead)
                eventBus.publish(DataReceivedEvent(connectionId: connectionId, data: data))
            } catch {
                eventBus.publish(SocketErrorEvent(connectionId: connectionId, error: error.localizedDescription))
                break
            }
        }

        // Clean up (using withLock for async-safe access)
        withLock {
            _ = connections.removeValue(forKey: connectionId)
        }

        try? socket.close()
        eventBus.publish(ClientDisconnectedEvent(connectionId: connectionId, reason: "connection closed"))
    }
}

#endif  // os(Windows)
