// ============================================================
// SocketClientTests.swift
// ARO Runtime - Socket Client Unit Tests (#208)
// ============================================================

import Foundation
import Testing
@testable import ARORuntime

#if !os(Windows)

// MARK: - SocketError Tests

@Suite("SocketError Tests")
struct SocketErrorTests {

    @Test("SocketError.notConnected description")
    func testNotConnectedError() {
        let error = SocketError.notConnected
        #expect(error.description == "Not connected")
    }

    @Test("SocketError.connectionNotFound description")
    func testConnectionNotFoundError() {
        let error = SocketError.connectionNotFound("conn-123")
        #expect(error.description == "Connection not found: conn-123")
    }

    @Test("SocketError.connectionFailed description")
    func testConnectionFailedError() {
        let error = SocketError.connectionFailed("refused")
        #expect(error.description == "Connection failed: refused")
    }

    @Test("SocketError.connectionTimeout description")
    func testConnectionTimeoutError() {
        let error = SocketError.connectionTimeout(host: "10.255.255.1", port: 9999)
        #expect(error.description == "Connection to 10.255.255.1:9999 timed out")
    }

    @Test("SocketError.encodingError description")
    func testEncodingError() {
        let error = SocketError.encodingError
        #expect(error.description == "String encoding error")
    }

    @Test("SocketError.timeout description")
    func testTimeoutError() {
        let error = SocketError.timeout
        #expect(error.description == "Connection timeout")
    }
}

// MARK: - AROSocketClient Initialization Tests

@Suite("AROSocketClient Initialization Tests")
struct SocketClientInitTests {

    @Test("Client initializes with unique connection ID")
    func testUniqueConnectionId() {
        let client1 = AROSocketClient()
        let client2 = AROSocketClient()
        #expect(!client1.connectionId.isEmpty)
        #expect(!client2.connectionId.isEmpty)
        #expect(client1.connectionId != client2.connectionId)
    }

    @Test("Client starts disconnected")
    func testInitiallyDisconnected() {
        let client = AROSocketClient()
        #expect(client.isConnected == false)
    }

    @Test("Client has correct default timeout values")
    func testDefaultTimeouts() {
        let client = AROSocketClient()
        #expect(client.connectTimeout == 30)
        #expect(client.receiveTimeout == 30)
    }

    @Test("Client has correct default buffer size")
    func testDefaultBufferSize() {
        let client = AROSocketClient()
        #expect(client.receiveBufferSize == 8192)
    }

    @Test("Client timeouts are configurable")
    func testConfigurableTimeouts() {
        let client = AROSocketClient()
        client.connectTimeout = 5
        client.receiveTimeout = 10
        #expect(client.connectTimeout == 5)
        #expect(client.receiveTimeout == 10)
    }

    @Test("Client buffer size is configurable")
    func testConfigurableBufferSize() {
        let client = AROSocketClient()
        client.receiveBufferSize = 16384
        #expect(client.receiveBufferSize == 16384)
    }

    @Test("Client accepts custom EventBus")
    func testCustomEventBus() {
        let bus = EventBus()
        let client = AROSocketClient(eventBus: bus)
        #expect(client.isConnected == false)
        #expect(!client.connectionId.isEmpty)
    }
}

// MARK: - Send Without Connection Tests

@Suite("AROSocketClient Send Without Connection Tests")
struct SocketClientSendTests {

    @Test("Sending data when not connected throws notConnected")
    func testSendDataNotConnected() async throws {
        let client = AROSocketClient()
        await #expect(throws: SocketError.self) {
            try await client.send(data: Data([0x01, 0x02]))
        }
    }

    @Test("Sending string when not connected throws notConnected")
    func testSendStringNotConnected() async throws {
        let client = AROSocketClient()
        await #expect(throws: SocketError.self) {
            try await client.send(string: "hello")
        }
    }
}

// MARK: - Connection Failure Tests

@Suite("AROSocketClient Connection Failure Tests")
struct SocketClientConnectionFailureTests {

    @Test("Connecting to unresolvable host throws connectionFailed")
    func testUnresolvableHost() async {
        let client = AROSocketClient()
        await #expect(throws: SocketError.self) {
            try await client.connect(host: "this-host-does-not-exist.invalid", port: 12345)
        }
        #expect(client.isConnected == false)
    }

    @Test("Connecting to refused port throws connectionFailed")
    func testConnectionRefused() async {
        let client = AROSocketClient()
        client.connectTimeout = 2
        await #expect(throws: SocketError.self) {
            try await client.connect(host: "127.0.0.1", port: 1)
        }
        #expect(client.isConnected == false)
    }

    @Test("Connection timeout throws connectionTimeout with short deadline")
    func testConnectionTimeout() async {
        let client = AROSocketClient()
        // Use a non-routable IP to force a timeout; 1 second is enough to prove poll() fires
        client.connectTimeout = 1
        let start = Date()
        await #expect(throws: SocketError.self) {
            try await client.connect(host: "10.255.255.1", port: 9999)
        }
        let elapsed = Date().timeIntervalSince(start)
        // Should have timed out within ~1-2s, not hung indefinitely
        #expect(elapsed < 5.0)
        #expect(client.isConnected == false)
    }
}

// MARK: - Disconnect Tests

@Suite("AROSocketClient Disconnect Tests")
struct SocketClientDisconnectTests {

    @Test("Disconnect when not connected does not throw")
    func testDisconnectWhenNotConnected() async throws {
        let client = AROSocketClient()
        try await client.disconnect()
        #expect(client.isConnected == false)
    }
}

// MARK: - Loopback Integration Tests

@Suite("AROSocketClient Loopback Integration Tests")
struct SocketClientLoopbackTests {

    /// Start a minimal TCP listener on a random port using BSD sockets.
    /// Returns (server fd, port).
    private func startListener() throws -> (Int32, Int) {
        #if canImport(Darwin)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else { throw SocketError.connectionFailed("socket() failed") }

        var opt: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0  // OS picks a free port
        addr.sin_addr.s_addr = UInt32(INADDR_LOOPBACK).bigEndian

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            #if canImport(Darwin)
            Darwin.close(fd)
            #else
            Glibc.close(fd)
            #endif
            throw SocketError.connectionFailed("bind() failed")
        }

        listen(fd, 1)

        // Read back the assigned port
        var boundAddr = sockaddr_in()
        var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &boundAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                getsockname(fd, sockPtr, &boundLen)
            }
        }
        let port = Int(UInt16(bigEndian: boundAddr.sin_port))

        return (fd, port)
    }

    private func closeSocket(_ fd: Int32) {
        #if canImport(Darwin)
        _ = Darwin.close(fd)
        #else
        _ = Glibc.close(fd)
        #endif
    }

    @Test("Client connects to local listener and reports isConnected")
    func testConnectToLocalListener() async throws {
        let (serverFd, port) = try startListener()
        defer { closeSocket(serverFd) }

        let client = AROSocketClient()
        try await client.connect(host: "127.0.0.1", port: port)
        #expect(client.isConnected == true)
        try await client.disconnect()
        #expect(client.isConnected == false)
    }

    @Test("Client sends data through loopback")
    func testSendData() async throws {
        let (serverFd, port) = try startListener()
        defer { closeSocket(serverFd) }

        let client = AROSocketClient()
        try await client.connect(host: "127.0.0.1", port: port)

        // Accept the connection on the server side
        let clientFd = accept(serverFd, nil, nil)
        defer { closeSocket(clientFd) }

        try await client.send(string: "hello")

        // Read from the accepted socket
        var buf = [UInt8](repeating: 0, count: 128)
        let n = recv(clientFd, &buf, buf.count, 0)
        #expect(n == 5)
        #expect(String(bytes: buf[0..<n], encoding: .utf8) == "hello")

        try await client.disconnect()
    }

    @Test("Client receives data and publishes DataReceivedEvent")
    func testReceiveData() async throws {
        let bus = EventBus()
        let (serverFd, port) = try startListener()
        defer { closeSocket(serverFd) }

        let client = AROSocketClient(eventBus: bus)
        client.receiveTimeout = 2
        try await client.connect(host: "127.0.0.1", port: port)

        // Accept and send data from the server side
        let peerFd = accept(serverFd, nil, nil)
        defer { closeSocket(peerFd) }

        // Subscribe to data events BEFORE sending
        let expectation = Expectation()
        bus.subscribe(to: DataReceivedEvent.self) { event in
            if event.connectionId == client.connectionId {
                expectation.fulfill()
            }
        }

        let msg = "world"
        _ = msg.utf8.withContiguousStorageIfAvailable { buf in
            send(peerFd, buf.baseAddress!, buf.count, 0)
        }

        // Wait for the receive loop to pick it up
        await expectation.wait(timeout: 3.0)
        #expect(expectation.isFulfilled)

        try await client.disconnect()
    }

    @Test("Client publishes connected event on connect")
    func testConnectedEvent() async throws {
        let bus = EventBus()
        let (serverFd, port) = try startListener()
        defer { closeSocket(serverFd) }

        let expectation = Expectation()
        bus.subscribe(to: ClientConnectedEvent.self) { event in
            expectation.fulfill()
        }

        let client = AROSocketClient(eventBus: bus)
        try await client.connect(host: "127.0.0.1", port: port)

        await expectation.wait(timeout: 2.0)
        #expect(expectation.isFulfilled)

        try await client.disconnect()
    }

    @Test("Client publishes disconnected event on disconnect")
    func testDisconnectedEvent() async throws {
        let bus = EventBus()
        let (serverFd, port) = try startListener()
        defer { closeSocket(serverFd) }

        let client = AROSocketClient(eventBus: bus)
        try await client.connect(host: "127.0.0.1", port: port)

        let expectation = Expectation()
        bus.subscribe(to: ClientDisconnectedEvent.self) { event in
            if event.connectionId == client.connectionId, event.reason == "disconnect requested" {
                expectation.fulfill()
            }
        }

        try await client.disconnect()

        await expectation.wait(timeout: 2.0)
        #expect(expectation.isFulfilled)
    }

    @Test("Client detects remote close")
    func testRemoteClose() async throws {
        let bus = EventBus()
        let (serverFd, port) = try startListener()
        defer { closeSocket(serverFd) }

        let client = AROSocketClient(eventBus: bus)
        client.receiveTimeout = 1
        try await client.connect(host: "127.0.0.1", port: port)

        let peerFd = accept(serverFd, nil, nil)

        let expectation = Expectation()
        bus.subscribe(to: ClientDisconnectedEvent.self) { event in
            if event.connectionId == client.connectionId, event.reason == "connection closed" {
                expectation.fulfill()
            }
        }

        // Close the server-side peer to trigger remote-close detection
        closeSocket(peerFd)

        await expectation.wait(timeout: 5.0)
        #expect(expectation.isFulfilled)
    }
}

// MARK: - Expectation Helper

/// Minimal async expectation helper for event-driven tests.
/// Uses nonisolated helper methods to avoid NSLock-in-async-context errors.
private final class Expectation: @unchecked Sendable {
    private let lock = NSLock()
    private var _fulfilled = false
    private var continuation: CheckedContinuation<Void, Never>?

    var isFulfilled: Bool {
        withLock { _fulfilled }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func fulfill() {
        let cont: CheckedContinuation<Void, Never>? = withLock {
            _fulfilled = true
            let c = continuation
            continuation = nil
            return c
        }
        cont?.resume()
    }

    /// Try to install a continuation. Returns true if installed, false if already fulfilled.
    private func installContinuation(_ cont: CheckedContinuation<Void, Never>) -> Bool {
        withLock {
            if _fulfilled { return false }
            continuation = cont
            return true
        }
    }

    /// Remove and return the pending continuation (for timeout).
    private func takeContinuation() -> CheckedContinuation<Void, Never>? {
        withLock {
            let c = continuation
            continuation = nil
            return c
        }
    }

    func wait(timeout: TimeInterval) async {
        if isFulfilled { return }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if !installContinuation(cont) {
                cont.resume()
                return
            }
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self.takeContinuation()?.resume()
            }
        }
    }
}

#endif // !os(Windows)
