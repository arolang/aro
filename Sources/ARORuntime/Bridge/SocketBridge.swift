// ============================================================
// SocketBridge.swift
// ARORuntime - C-callable Socket Interface
// ============================================================
//
// Owns the C-ABI bridge for the native BSD socket server (NativeSocketServer,
// broadcast helpers) plus the legacy socket-handle API, and the Windows stubs.
// Also owns the shared BSD system-call shims (systemClose/systemSend/aroSockStreamType),
// which were widened from `private` to internal so the native HTTP server in
// ServiceBridge.swift can share them.
// Extracted from ServiceBridge.swift (issue #313) — pure move, no behaviour change.

import Foundation
import AROParser

#if !os(Windows)

// MARK: - Native Socket Server (BSD Sockets)

#if canImport(Darwin)
import Darwin

// #313: widened from `private` to internal — shared with NativeHTTPServer in ServiceBridge.swift.
@inline(__always)
func systemClose(_ fd: Int32) -> Int32 {
    Darwin.close(fd)
}

@inline(__always)
func systemSend(_ fd: Int32, _ buf: UnsafeRawPointer!, _ len: Int, _ flags: Int32) -> Int {
    Darwin.send(fd, buf, len, flags)
}

// #313: the SOCK_STREAM value as an Int32 for socket() calls, shared with
// NativeHTTPServer in ServiceBridge.swift. On Darwin the C symbol is already
// Int32. Deliberately NOT named `SOCK_STREAM`: a module-scope (internal)
// constant with that name shadows the C `SOCK_STREAM` across the whole
// ARORuntime module, which on Linux breaks `SOCK_STREAM.rawValue` in
// SocketServer / DAPTCPListener / MetricsSocketServer (the C symbol there is
// the `__socket_type` enum, not an Int32).
let aroSockStreamType: Int32 = SOCK_STREAM
#elseif canImport(Glibc)
import Glibc

// #313: widened from `private` to internal — shared with NativeHTTPServer in ServiceBridge.swift.
@inline(__always)
func systemClose(_ fd: Int32) -> Int32 {
    Glibc.close(fd)
}

@inline(__always)
func systemSend(_ fd: Int32, _ buf: UnsafeRawPointer!, _ len: Int, _ flags: Int32) -> Int {
    Glibc.send(fd, buf, len, flags)
}

// #313: on Glibc SOCK_STREAM is the `__socket_type` enum; normalise to Int32.
// See the Darwin branch above for why this must NOT be named `SOCK_STREAM`.
let aroSockStreamType: Int32 = Int32(SOCK_STREAM.rawValue)
#endif

/// Native TCP Socket Server using BSD sockets
/// This provides a working socket server for compiled binaries
public final class NativeSocketServer: @unchecked Sendable {
    private var serverFd: Int32 = -1
    private var isRunning = false
    private let lock = NSLock()
    private var connections: [String: Int32] = [:]
    private var dataHandler: ((String, Data) -> Void)?
    private var connectHandler: ((String, String) -> Void)?
    private var disconnectHandler: ((String) -> Void)?

    public let port: Int

    public init(port: Int) {
        self.port = port
    }

    deinit {
        stop()
    }

    /// Set handler for incoming data
    public func onData(_ handler: @escaping (String, Data) -> Void) {
        dataHandler = handler
    }

    /// Set handler for new connections
    public func onConnect(_ handler: @escaping (String, String) -> Void) {
        connectHandler = handler
    }

    /// Set handler for disconnections
    public func onDisconnect(_ handler: @escaping (String) -> Void) {
        disconnectHandler = handler
    }

    /// Start the server
    public func start() -> Bool {
        // Ignore SIGPIPE process-wide so a broadcast/send to a client that has
        // gone away cannot terminate the process (default SIGPIPE disposition).
        signal(SIGPIPE, SIG_IGN)

        // Create socket
        serverFd = socket(AF_INET, aroSockStreamType, 0)
        guard serverFd >= 0 else {
            print("[NativeSocketServer] Failed to create socket")
            return false
        }

        // Set SO_REUSEADDR
        var reuseAddr: Int32 = 1
        setsockopt(serverFd, SOL_SOCKET, SO_REUSEADDR, &reuseAddr, socklen_t(MemoryLayout<Int32>.size))

        // Bind to port
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian

        let bindResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(serverFd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult == 0 else {
            print("[NativeSocketServer] Failed to bind to port \(port)")
            _ = systemClose(serverFd)
            serverFd = -1
            return false
        }

        // Listen
        guard listen(serverFd, 10) == 0 else {
            print("[NativeSocketServer] Failed to listen")
            _ = systemClose(serverFd)
            serverFd = -1
            return false
        }

        isRunning = true
        print("Socket Server started on port \(port)")

        // Start accept loop in background
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.acceptLoop()
        }

        return true
    }

    /// Stop the server
    public func stop() {
        isRunning = false

        lock.lock()
        let conns = connections
        connections.removeAll()
        lock.unlock()

        // Close all client connections
        for (_, fd) in conns {
            _ = systemClose(fd)
        }

        // Close server socket
        if serverFd >= 0 {
            _ = systemClose(serverFd)
            serverFd = -1
        }

        print("[NativeSocketServer] Stopped")
    }

    /// Send data to a specific connection
    public func send(data: Data, to connectionId: String) -> Bool {
        lock.lock()
        guard let fd = connections[connectionId] else {
            lock.unlock()
            print("[NativeSocketServer] Connection not found: \(connectionId)")
            return false
        }
        lock.unlock()

        let result = data.withUnsafeBytes { buffer in
            systemSend(fd, buffer.baseAddress!, data.count, 0)
        }

        return result >= 0
    }

    /// Broadcast data to all connections
    public func broadcast(data: Data) -> Int {
        lock.lock()
        let conns = connections
        lock.unlock()

        var successCount = 0
        for (_, fd) in conns {
            let result = data.withUnsafeBytes { buffer in
                systemSend(fd, buffer.baseAddress!, data.count, 0)
            }
            if result >= 0 {
                successCount += 1
            }
        }

        return successCount
    }

    /// Broadcast data to all connections except the sender
    public func broadcast(data: Data, excluding senderId: String) -> Int {
        lock.lock()
        let conns = connections
        lock.unlock()

        var successCount = 0
        for (connId, fd) in conns {
            if connId == senderId { continue }
            let result = data.withUnsafeBytes { buffer in
                systemSend(fd, buffer.baseAddress!, data.count, 0)
            }
            if result >= 0 {
                successCount += 1
            }
        }

        return successCount
    }

    private func acceptLoop() {
        while isRunning {
            var clientAddr = sockaddr_in()
            var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)

            let clientFd = withUnsafeMutablePointer(to: &clientAddr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    accept(serverFd, sockaddrPtr, &addrLen)
                }
            }

            guard clientFd >= 0, isRunning else { continue }

            let connectionId = UUID().uuidString
            let addrPtr = inet_ntoa(clientAddr.sin_addr)
            let remoteAddress = addrPtr != nil ? "[IPv4]\(String(cString: addrPtr!))" : "[IPv4]unknown"

            lock.lock()
            connections[connectionId] = clientFd
            lock.unlock()

            // Notify connect handler
            connectHandler?(connectionId, remoteAddress)

            // Handle client in background
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.handleClient(fd: clientFd, connectionId: connectionId)
            }
        }
    }

    private func handleClient(fd: Int32, connectionId: String) {
        var buffer = [UInt8](repeating: 0, count: 4096)

        while isRunning {
            let bytesRead = recv(fd, &buffer, buffer.count, 0)

            if bytesRead <= 0 {
                // Connection closed or error
                break
            }

            let data = Data(buffer[0..<bytesRead])
            dataHandler?(connectionId, data)
        }

        // Clean up
        lock.lock()
        connections.removeValue(forKey: connectionId)
        lock.unlock()

        _ = systemClose(fd)
        disconnectHandler?(connectionId)
    }
}

/// Global native socket server instance
nonisolated(unsafe) public var nativeSocketServer: NativeSocketServer?
private let socketServerLock = NSLock()

/// Start native socket server
@_cdecl("aro_native_socket_server_start")
public func aro_native_socket_server_start(_ port: Int32) -> Int32 {
    socketServerLock.lock()
    defer { socketServerLock.unlock() }

    // Create server if needed
    if nativeSocketServer == nil {
        nativeSocketServer = NativeSocketServer(port: Int(port))

        // Set up handlers for broadcast behavior
        nativeSocketServer?.onConnect { connectionId, remoteAddress in
            print("[Handle Client Connected] SocketConnection(id: \"\(connectionId)\", remoteAddress: \"\(remoteAddress)\")")
        }

        nativeSocketServer?.onData { connectionId, data in
            // Broadcast to all clients (including sender for chat-style apps)
            _ = nativeSocketServer?.broadcast(data: data)
            if let str = String(data: data, encoding: .utf8) {
                print("[Handle Data Received] Broadcast: \(str.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }

        nativeSocketServer?.onDisconnect { connectionId in
            print("[Handle Client Disconnected] \(connectionId)")
        }
    }

    return nativeSocketServer?.start() == true ? 0 : -1
}

/// Stop native socket server
@_cdecl("aro_native_socket_server_stop")
public func aro_native_socket_server_stop() {
    socketServerLock.lock()
    defer { socketServerLock.unlock() }

    nativeSocketServer?.stop()
    nativeSocketServer = nil
}

/// Send data to a connection
@_cdecl("aro_native_socket_send")
public func aro_native_socket_send(
    _ connectionId: UnsafePointer<CChar>?,
    _ data: UnsafePointer<UInt8>?,
    _ length: Int
) -> Int32 {
    guard let connId = connectionId.map({ String(cString: $0) }),
          let dataPtr = data else { return -1 }

    let sendData = Data(bytes: dataPtr, count: length)

    socketServerLock.lock()
    let server = nativeSocketServer
    socketServerLock.unlock()

    return server?.send(data: sendData, to: connId) == true ? 0 : -1
}

/// Broadcast data to all connections
@_cdecl("aro_native_socket_broadcast")
public func aro_native_socket_broadcast(
    _ data: UnsafePointer<UInt8>?,
    _ length: Int
) -> Int32 {
    guard let dataPtr = data else { return -1 }

    let sendData = Data(bytes: dataPtr, count: length)

    socketServerLock.lock()
    let server = nativeSocketServer
    socketServerLock.unlock()

    return Int32(server?.broadcast(data: sendData) ?? 0)
}

/// Broadcast data to all connections except sender
@_cdecl("aro_native_socket_broadcast_excluding")
public func aro_native_socket_broadcast_excluding(
    _ senderId: UnsafePointer<CChar>?,
    _ data: UnsafePointer<UInt8>?,
    _ length: Int
) -> Int32 {
    guard let senderIdStr = senderId.map({ String(cString: $0) }),
          let dataPtr = data else { return -1 }

    let sendData = Data(bytes: dataPtr, count: length)

    socketServerLock.lock()
    let server = nativeSocketServer
    socketServerLock.unlock()

    return Int32(server?.broadcast(data: sendData, excluding: senderIdStr) ?? 0)
}

// MARK: - Socket Bridge (Legacy API)

/// Socket handle
final class SocketHandle: @unchecked Sendable {
    var isServer: Bool
    var host: String = ""
    var port: Int = 0
    var isConnected: Bool = false

    init(isServer: Bool) {
        self.isServer = isServer
    }
}

/// Create a TCP server socket
@_cdecl("aro_socket_server_create")
public func aro_socket_server_create(
    _ host: UnsafePointer<CChar>?,
    _ port: Int32
) -> UnsafeMutableRawPointer? {
    let handle = SocketHandle(isServer: true)
    handle.host = host.map { String(cString: $0) } ?? "127.0.0.1"
    handle.port = Int(port)
    return UnsafeMutableRawPointer(Unmanaged.passRetained(handle).toOpaque())
}

/// Create a TCP client socket
@_cdecl("aro_socket_client_create")
public func aro_socket_client_create() -> UnsafeMutableRawPointer? {
    let handle = SocketHandle(isServer: false)
    return UnsafeMutableRawPointer(Unmanaged.passRetained(handle).toOpaque())
}

/// Connect client to server
@_cdecl("aro_socket_connect")
public func aro_socket_connect(
    _ socketPtr: UnsafeMutableRawPointer?,
    _ host: UnsafePointer<CChar>?,
    _ port: Int32
) -> Int32 {
    guard let ptr = socketPtr,
          let hostStr = host.map({ String(cString: $0) }) else { return -1 }
    let handle = Unmanaged<SocketHandle>.fromOpaque(ptr).takeUnretainedValue()
    handle.host = hostStr
    handle.port = Int(port)
    return 0
}

/// Start listening (server) - now uses native server
@_cdecl("aro_socket_listen")
public func aro_socket_listen(_ socketPtr: UnsafeMutableRawPointer?) -> Int32 {
    guard let ptr = socketPtr else { return -1 }
    let handle = Unmanaged<SocketHandle>.fromOpaque(ptr).takeUnretainedValue()
    guard handle.isServer else { return -1 }
    return aro_native_socket_server_start(Int32(handle.port))
}

/// Send data on socket
@_cdecl("aro_socket_send")
public func aro_socket_send(
    _ socketPtr: UnsafeMutableRawPointer?,
    _ data: UnsafePointer<UInt8>?,
    _ length: Int
) -> Int {
    guard socketPtr != nil, data != nil else { return -1 }
    return length
}

/// Receive data from socket
@_cdecl("aro_socket_recv")
public func aro_socket_recv(
    _ socketPtr: UnsafeMutableRawPointer?,
    _ buffer: UnsafeMutablePointer<UInt8>?,
    _ maxLength: Int
) -> Int {
    guard socketPtr != nil, buffer != nil else { return -1 }
    return 0
}

/// Close socket
@_cdecl("aro_socket_close")
public func aro_socket_close(_ socketPtr: UnsafeMutableRawPointer?) {
    guard let ptr = socketPtr else { return }
    let handle = Unmanaged<SocketHandle>.fromOpaque(ptr).takeUnretainedValue()
    handle.isConnected = false
}

/// Destroy socket
@_cdecl("aro_socket_destroy")
public func aro_socket_destroy(_ socketPtr: UnsafeMutableRawPointer?) {
    guard let ptr = socketPtr else { return }
    Unmanaged<SocketHandle>.fromOpaque(ptr).release()
}

#else  // os(Windows)

// MARK: - Native Socket Server Stubs (Windows)

/// Start native socket server (Windows stub)
@_cdecl("aro_native_socket_server_start")
public func aro_native_socket_server_start(_ port: Int32) -> Int32 {
    print("[NativeSocketServer] Socket server not yet supported on Windows")
    return -1
}

/// Stop native socket server (Windows stub)
@_cdecl("aro_native_socket_server_stop")
public func aro_native_socket_server_stop() {
    // No-op on Windows
}

/// Send data to a connection (Windows stub)
@_cdecl("aro_native_socket_send")
public func aro_native_socket_send(
    _ connectionId: UnsafePointer<CChar>?,
    _ data: UnsafePointer<UInt8>?,
    _ length: Int
) -> Int32 {
    return -1  // Not supported
}

/// Broadcast data to all connections (Windows stub)
@_cdecl("aro_native_socket_broadcast")
public func aro_native_socket_broadcast(
    _ data: UnsafePointer<UInt8>?,
    _ length: Int
) -> Int32 {
    return -1  // Not supported
}

/// Broadcast data to all connections except sender (Windows stub)
@_cdecl("aro_native_socket_broadcast_excluding")
public func aro_native_socket_broadcast_excluding(
    _ senderId: UnsafePointer<CChar>?,
    _ data: UnsafePointer<UInt8>?,
    _ length: Int
) -> Int32 {
    return -1  // Not supported
}

// MARK: - Socket Stubs (Windows)

/// Create a TCP server socket (Windows stub)
@_cdecl("aro_socket_server_create")
public func aro_socket_server_create(
    _ host: UnsafePointer<CChar>?,
    _ port: Int32
) -> UnsafeMutableRawPointer? {
    return nil
}

/// Create a TCP client socket (Windows stub)
@_cdecl("aro_socket_client_create")
public func aro_socket_client_create() -> UnsafeMutableRawPointer? {
    return nil
}

/// Connect client to server (Windows stub)
@_cdecl("aro_socket_connect")
public func aro_socket_connect(
    _ socketPtr: UnsafeMutableRawPointer?,
    _ host: UnsafePointer<CChar>?,
    _ port: Int32
) -> Int32 {
    return -1
}

/// Start listening (Windows stub)
@_cdecl("aro_socket_listen")
public func aro_socket_listen(_ socketPtr: UnsafeMutableRawPointer?) -> Int32 {
    return -1
}

/// Send data on socket (Windows stub)
@_cdecl("aro_socket_send")
public func aro_socket_send(
    _ socketPtr: UnsafeMutableRawPointer?,
    _ data: UnsafePointer<UInt8>?,
    _ length: Int
) -> Int {
    return -1
}

/// Receive data from socket (Windows stub)
@_cdecl("aro_socket_recv")
public func aro_socket_recv(
    _ socketPtr: UnsafeMutableRawPointer?,
    _ buffer: UnsafeMutablePointer<UInt8>?,
    _ maxLength: Int
) -> Int {
    return -1
}

/// Close socket (Windows stub)
@_cdecl("aro_socket_close")
public func aro_socket_close(_ socketPtr: UnsafeMutableRawPointer?) {
    // No-op
}

/// Destroy socket (Windows stub)
@_cdecl("aro_socket_destroy")
public func aro_socket_destroy(_ socketPtr: UnsafeMutableRawPointer?) {
    // No-op
}

#endif  // !os(Windows)
