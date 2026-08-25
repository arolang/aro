// ============================================================
// ServiceBridge.swift
// ARORuntime - C-callable Native HTTP Server Interface
// ============================================================
//
// After issue #313 this slim file owns only the native BSD-socket HTTP server
// (NativeHTTPServer with WebSocket support), the JSON conversion helpers it
// uses, the embedded-artifact registries (OpenAPI spec, templates, plugins),
// and the OpenAPI route/port parsing. HTTP client, HTTP server handle, file
// system, file watcher, and socket bridges were extracted into sibling files
// (HTTPClientBridge / HTTPServerBridge / FileSystemBridge / FileWatcherBridge /
// SocketBridge). Pure move, no behaviour change.
//
// The BSD system-call shims (systemClose/systemSend/aroSockStreamType) live in
// SocketBridge.swift and are shared across files at internal scope.

import Foundation
import AROParser

#if os(macOS)
import CommonCrypto
#elseif os(Linux)
import Crypto
#endif

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if !os(Windows)

// MARK: - Native HTTP Server (BSD Sockets)

/// A request body as the native server hands it over (GitLab #477).
///
/// Same distinction the NIO server makes: a route whose feature set reads its
/// body gets the bytes, a route that only moves them gets the stream. Compiled
/// and interpreted binaries answer an upload the same way because both decide
/// it from the same analysis.
public enum NativeRequestBody: Sendable {
    case buffered(Data?)
    case streaming(RequestBodyStream)

    /// The bytes, when they were read. Nil on the streaming path, where
    /// reading them is the thing being avoided.
    public var data: Data? {
        if case .buffered(let data) = self { return data }
        return nil
    }
}

/// What a handler answers with. `stream` is set instead of `body` when the
/// response is written as it is produced (chunked, no Content-Length).
public struct NativeHTTPResponse: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data?
    public let stream: AROStream<Data>?

    public init(_ tuple: (Int, [String: String], Data?)) {
        self.init(status: tuple.0, headers: tuple.1, body: tuple.2)
    }

    public init(status: Int, headers: [String: String], body: Data?) {
        self.status = status
        self.headers = headers
        self.body = body
        self.stream = nil
    }

    public init(status: Int, headers: [String: String], stream: AROStream<Data>) {
        self.status = status
        self.headers = headers
        self.body = nil
        self.stream = stream
    }
}

/// Request handler type for native HTTP server
public typealias NativeHTTPRequestHandler = (String, String, [String: String], NativeRequestBody) -> NativeHTTPResponse

/// Counts bytes written from inside a Task without capturing a `var`.
final class StreamedByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func add(_ count: Int) { lock.lock(); value += count; lock.unlock() }
    var total: Int { lock.lock(); defer { lock.unlock() }; return value }
}

/// Reads a request body off the socket on its own thread and hands it over a
/// bounded channel (GitLab #477).
///
/// The thread is the point. In a compiled binary the connection thread runs the
/// feature set, and the feature set is the consumer — if it also had to produce,
/// the first chunk it waited for would be one it was supposed to read next.
/// The channel bounds how far the reader may run ahead, so a slow sink leaves
/// the bytes in the socket buffer and TCP throttles the client.
final class NativeBodyProducer: @unchecked Sendable {
    private let fd: Int32
    private let prefix: Data
    private let contentLength: Int
    private let waitForData: @Sendable () -> Bool
    private let channel: BoundedChannel<Data>
    private let stateLock = NSLock()
    private var cancelled = false
    private let completed = DispatchSemaphore(value: 0)
    private var started = false

    init(fd: Int32, prefix: Data, contentLength: Int, waitForData: @escaping @Sendable () -> Bool) {
        self.fd = fd
        self.prefix = prefix
        self.contentLength = contentLength
        self.waitForData = waitForData
        self.channel = BoundedChannel<Data>(
            capacity: max(1, RuntimeDefaults.streamPrefetchCapacity),
            label: "http-body-native"
        )
    }

    func stream() -> AROStream<Data> {
        let channel = self.channel
        return AROStream<Data> {
            AsyncThrowingStream { continuation in
                Task {
                    do {
                        while let chunk = try await channel.next() {
                            continuation.yield(chunk)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
        }
    }

    func start() {
        stateLock.lock()
        guard !started else { stateLock.unlock(); return }
        started = true
        stateLock.unlock()

        let thread = Thread { [self] in
            var delivered = 0
            if !prefix.isEmpty {
                deliver(prefix)
                delivered += prefix.count
            }

            var buffer = [UInt8](repeating: 0, count: RuntimeDefaults.bodyChunkSize)
            while delivered < contentLength, !isCancelled {
                guard waitForData() else { break }
                let want = min(buffer.count, contentLength - delivered)
                let read = recv(fd, &buffer, want, 0)
                if read <= 0 { break }
                deliver(Data(buffer[0..<read]))
                delivered += read
            }

            MetricsCollector.shared.recordBodyStreamed(bytes: delivered)
            finishChannel()
            completed.signal()
        }
        thread.name = "aro.http.body"
        thread.start()
    }

    /// Stop reading and release anyone waiting on the channel. Called once the
    /// handler has returned, before the socket is closed underneath us.
    func finish() {
        stateLock.lock()
        let wasStarted = started
        cancelled = true
        stateLock.unlock()
        guard wasStarted else { return }

        finishChannel()
        // Give the reader a moment to notice; it is about to lose its socket.
        _ = completed.wait(timeout: .now() + 5)
    }

    private var isCancelled: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return cancelled
    }

    private func finishChannel() {
        let channel = self.channel
        let done = DispatchSemaphore(value: 0)
        Task { await channel.finish(); done.signal() }
        _ = done.wait(timeout: .now() + 5)
    }

    /// Hand one chunk to the channel, waiting while it is full — the
    /// backpressure that keeps memory at the window rather than the body.
    private func deliver(_ chunk: Data) {
        let channel = self.channel
        let done = DispatchSemaphore(value: 0)
        Task { await channel.send(chunk); done.signal() }
        done.wait()
    }
}

/// Native HTTP Server using BSD sockets
/// This provides a working HTTP server for compiled binaries with WebSocket support
///
/// Sendable-safety: all mutable state is guarded by explicit locks, not the
/// type system. `serverFd`, `isRunning`, and `requestHandler` are read/written
/// under `lock`; the WebSocket connection table (`wsConnections`) is read/written
/// under `wsLock` (see `wsConnectionCount` / `broadcastWebSocket`). The remaining
/// mutable vars (`eventBus`, `wsPath`) are configuration set once via
/// `setEventBus` / `setWebSocketPath` during server setup, before the accept loop
/// begins to serve requests, and are only read afterward.
public final class NativeHTTPServer: @unchecked Sendable {
    private var serverFd: Int32 = -1
    private var isRunning = false
    private let lock = NSLock()
    private var requestHandler: NativeHTTPRequestHandler?

    /// Per-route body policy (GitLab #477). Installed from the contract and
    /// the materialization analysis, both baked into the binary at build time.
    private var bodyPolicyResolver: BodyPolicyResolver?

    /// WebSocket connection storage
    private var wsConnections: [String: Int32] = [:]
    private let wsLock = NSLock()

    /// WebSocket path to listen on
    private var wsPath: String = "/ws"

    /// Event bus for WebSocket events
    public var eventBus: EventBus?

    public let port: Int

    /// Number of active WebSocket connections
    public var wsConnectionCount: Int {
        wsLock.lock()
        defer { wsLock.unlock() }
        return wsConnections.count
    }

    public init(port: Int) {
        self.port = port
    }

    /// Configure WebSocket path
    public func setWebSocketPath(_ path: String) {
        wsPath = path
    }

    /// Set event bus for WebSocket events
    public func setEventBus(_ eventBus: EventBus) {
        self.eventBus = eventBus
    }

    deinit {
        stop()
    }

    /// Set request handler
    public func onRequest(_ handler: @escaping NativeHTTPRequestHandler) {
        requestHandler = handler
    }

    /// Set the per-route body policy resolver (GitLab #477).
    public func onBodyPolicy(_ resolver: @escaping BodyPolicyResolver) {
        bodyPolicyResolver = resolver
    }

    /// Wait for data to be available on the socket using select()
    /// Returns true if data is available, false on timeout or error
    private func waitForData(fd: Int32, timeoutMs: Int) -> Bool {
        var readfds = fd_set()
        withUnsafeMutablePointer(to: &readfds) { ptr in
            // Zero out the fd_set
            let rawPtr = UnsafeMutableRawPointer(ptr)
            memset(rawPtr, 0, MemoryLayout<fd_set>.size)
        }

        // Set the fd bit manually - FD_SET macro equivalent
        let fdIndex = Int(fd)
        let bitsPerInt = MemoryLayout<Int32>.size * 8
        let arrayIndex = fdIndex / bitsPerInt
        let bitIndex = fdIndex % bitsPerInt

        withUnsafeMutablePointer(to: &readfds) { ptr in
            let intPtr = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: Int32.self)
            intPtr[arrayIndex] |= Int32(1 << bitIndex)
        }

        var timeout = timeval()
        timeout.tv_sec = timeoutMs / 1000
        #if os(Linux)
        timeout.tv_usec = Int(timeoutMs % 1000) * 1000
        #else
        timeout.tv_usec = Int32(timeoutMs % 1000) * 1000
        #endif

        let result = select(fd + 1, &readfds, nil, nil, &timeout)
        return result > 0
    }

    /// Start the server
    public func start() -> Bool {
        // Ignore SIGPIPE process-wide: a client that closes the connection
        // before we finish writing the response would otherwise raise SIGPIPE
        // on send(), whose default disposition terminates the process. This
        // manifested as the compiled server dying mid-request on Linux CI
        // (every subsequent request then failing to connect). NIO handles this
        // for the interpreter; the native BSD-socket path must do it explicitly.
        signal(SIGPIPE, SIG_IGN)

        // Create socket
        serverFd = socket(AF_INET, aroSockStreamType, 0)
        guard serverFd >= 0 else {
            print("[NativeHTTPServer] Failed to create socket")
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
            print("[NativeHTTPServer] Failed to bind to port \(port)")
            _ = systemClose(serverFd)
            serverFd = -1
            return false
        }

        // Listen
        guard listen(serverFd, 10) == 0 else {
            print("[NativeHTTPServer] Failed to listen")
            _ = systemClose(serverFd)
            serverFd = -1
            return false
        }

        isRunning = true
        print("HTTP Server started on port \(port)")

        // Start accept loop on a dedicated thread — GCD utility QoS can
        // delay dispatch under system load, causing accepted connections to stall
        let server = self
        let acceptThread = Thread {
            server.acceptLoop()
        }
        acceptThread.name = "aro.http.accept"
        acceptThread.start()

        return true
    }

    /// Stop the server
    public func stop() {
        isRunning = false

        // Close server socket
        if serverFd >= 0 {
            _ = systemClose(serverFd)
            serverFd = -1
        }

        print("[NativeHTTPServer] Stopped")
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

            // Handle client on a dedicated thread
            let server = self
            let thread = Thread {
                server.handleClient(fd: clientFd)
            }
            thread.start()
        }
    }

    private func handleClient(fd: Int32) {
        // Set recv timeout so blocking recv() calls don't hang threads indefinitely
        var timeout = timeval()
        timeout.tv_sec = 5
        timeout.tv_usec = 0
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var buffer = [UInt8](repeating: 0, count: 8192)
        var totalData = Data()

        // Read initial request data
        let bytesRead = recv(fd, &buffer, buffer.count, 0)

        guard bytesRead > 0 else {
            _ = systemClose(fd)
            return
        }

        totalData.append(contentsOf: buffer[0..<bytesRead])

        guard let requestString = String(data: totalData, encoding: .utf8) else {
            sendResponse(fd: fd, statusCode: 400, body: "Bad Request")
            _ = systemClose(fd)
            return
        }

        // Parse HTTP request
        let lines = requestString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendResponse(fd: fd, statusCode: 400, body: "Bad Request")
            _ = systemClose(fd)
            return
        }

        let parts = requestLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else {
            sendResponse(fd: fd, statusCode: 400, body: "Bad Request")
            _ = systemClose(fd)
            return
        }

        let method = String(parts[0])
        let path = String(parts[1])

        // Parse headers
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            let headerParts = line.split(separator: ":", maxSplits: 1)
            if headerParts.count == 2 {
                let name = String(headerParts[0]).trimmingCharacters(in: .whitespaces)
                let value = String(headerParts[1]).trimmingCharacters(in: .whitespaces)
                headers[name] = value
            }
        }

        // Check for WebSocket upgrade request
        if isWebSocketUpgrade(path: path, headers: headers) {
            if performWebSocketHandshake(fd: fd, headers: headers) {
                let connectionId = UUID().uuidString
                handleWebSocket(fd: fd, connectionId: connectionId)
            } else {
                sendResponse(fd: fd, statusCode: 400, body: "WebSocket handshake failed")
                _ = systemClose(fd)
            }
            return
        }

        // Body policy for this route (GitLab #477). Resolved before a body
        // byte is read, so a declared length over the limit is refused without
        // allocating anything — the same order the NIO server uses.
        let pathWithoutQuery = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        let policy = bodyPolicyResolver?(method, pathWithoutQuery) ?? .default
        let declaredLength = (headers["Content-Length"] ?? headers["content-length"]).flatMap { Int($0) }

        if let limit = policy.limit, let declared = declaredLength, declared > limit {
            sendOversizedBodyResponse(fd: fd, method: method, path: pathWithoutQuery, limit: limit, observed: declared)
            _ = shutdown(fd, Int32(SHUT_WR))
            _ = systemClose(fd)
            return
        }

        // Find where body starts (after \r\n\r\n) in byte data
        var requestBody: NativeRequestBody = .buffered(nil)
        var bodyProducer: NativeBodyProducer? = nil
        let headerSeparator = Data("\r\n\r\n".utf8)
        if let separatorRange = totalData.range(of: headerSeparator) {
            let bodyStartIndex = separatorRange.upperBound
            let prefix = totalData.count > bodyStartIndex
                ? totalData.subdata(in: bodyStartIndex..<totalData.count)
                : Data()

            switch policy.mode {
            case .streamed where (declaredLength ?? 0) > 0:
                // Nothing accumulates: a producer thread reads the socket and
                // hands chunks over a bounded channel, so the feature set can
                // consume them while the client is still sending. It has to be
                // a separate thread — this one is about to run the feature set,
                // and a consumer waiting on its own producer never finishes.
                let producer = NativeBodyProducer(
                    fd: fd,
                    prefix: prefix,
                    contentLength: declaredLength ?? 0,
                    waitForData: { [weak self] in self?.waitForData(fd: fd, timeoutMs: 5000) ?? false }
                )
                bodyProducer = producer
                requestBody = .streaming(RequestBodyStream(
                    chunks: producer.stream(),
                    declaredLength: declaredLength,
                    limit: policy.materializationLimit
                ))
                producer.start()

            default:
                // Buffered: read to the declared length, checking the limit
                // before each append so the memory over it is never allocated.
                var accumulated = prefix
                if let contentLength = declaredLength, contentLength > 0 {
                    var remainingToRead = contentLength - accumulated.count
                    while remainingToRead > 0 {
                        // Wait for data with select() before reading
                        // This is critical on Linux where TCP fragmentation may cause
                        // headers and body to arrive in separate packets
                        if !waitForData(fd: fd, timeoutMs: 5000) {
                            break // Timeout or error waiting for data
                        }

                        let bytesToRead = min(buffer.count, remainingToRead)
                        let additionalBytesRead = recv(fd, &buffer, bytesToRead, 0)
                        if additionalBytesRead <= 0 {
                            break // Connection closed or error
                        }
                        if let limit = policy.limit, accumulated.count + additionalBytesRead > limit {
                            sendOversizedBodyResponse(fd: fd, method: method, path: pathWithoutQuery, limit: limit, observed: nil)
                            _ = shutdown(fd, Int32(SHUT_WR))
                            _ = systemClose(fd)
                            return
                        }
                        accumulated.append(contentsOf: buffer[0..<additionalBytesRead])
                        remainingToRead -= additionalBytesRead
                    }
                }
                if !accumulated.isEmpty {
                    MetricsCollector.shared.recordBodyMaterialized(bytes: accumulated.count)
                    requestBody = .buffered(accumulated)
                }
            }
        }

        // Call request handler
        if let handler = requestHandler {
            let response = handler(method, path, headers, requestBody)
            // The producer is done either way once the handler has returned:
            // whatever it did or didn't read, nothing else will.
            bodyProducer?.finish()
            if let stream = response.stream {
                sendStreamedResponse(fd: fd, statusCode: response.status, headers: response.headers, stream: stream)
            } else {
                sendResponse(fd: fd, statusCode: response.status, headers: response.headers, bodyData: response.body)
            }
        } else {
            bodyProducer?.finish()
            // Default response
            sendResponse(fd: fd, statusCode: 200, body: "{\"status\":\"ok\"}")
        }

        // Graceful socket close: signal end of transmission before closing
        // This prevents "Connection reset by peer" errors for some HTTP clients (like HTTP::Tiny)
        _ = shutdown(fd, Int32(SHUT_WR))
        // Brief drain: let the client read the response before closing
        var drainBuf = [UInt8](repeating: 0, count: 64)
        _ = recv(fd, &drainBuf, drainBuf.count, Int32(MSG_DONTWAIT))
        _ = systemClose(fd)
    }

    /// 413, worded exactly as the NIO server words it, because a client should
    /// not be able to tell which server refused it.
    private func sendOversizedBodyResponse(
        fd: Int32,
        method: String,
        path: String,
        limit: Int,
        observed: Int?
    ) {
        let size = observed.map { "it is \(ByteSize.describe($0))" } ?? "it is larger"
        let message = "Cannot read the request body for \(method) \(path): "
            + "\(size), above this route's \(ByteSize.describe(limit)) limit. "
            + "Raise x-aro-max-body for this operation, or stream the body instead of reading it."
        MetricsCollector.shared.recordBodyRejected(method: method, path: path)
        let payload = "{\"error\":\"\(message.replacingOccurrences(of: "\"", with: "\\\""))\"}"
        sendResponse(
            fd: fd,
            statusCode: 413,
            headers: ["Content-Type": "application/json"],
            bodyData: Data(payload.utf8)
        )
    }

    /// Write a response body as it is produced, chunk by chunk (GitLab #477).
    ///
    /// Chunked transfer encoding, because the length is not known when the head
    /// goes out — which is the whole reason this path exists.
    private func sendStreamedResponse(
        fd: Int32,
        statusCode: Int,
        headers: [String: String],
        stream: AROStream<Data>
    ) {
        var head = "HTTP/1.1 \(statusCode) \(Self.statusText(statusCode))\r\n"
        var finalHeaders = headers
        if finalHeaders["Content-Type"] == nil {
            finalHeaders["Content-Type"] = "application/octet-stream"
        }
        finalHeaders["Transfer-Encoding"] = "chunked"
        finalHeaders["Connection"] = "close"
        for (name, value) in finalHeaders {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        let headData = Data(head.utf8)
        headData.withUnsafeBytes { buffer in
            _ = systemSend(fd, buffer.baseAddress!, headData.count, 0)
        }

        // Drain on this thread: the connection is ours until the response is
        // complete, and the producer is somewhere else.
        let done = DispatchSemaphore(value: 0)
        let counter = StreamedByteCounter()
        Task {
            do {
                for try await chunk in stream.stream {
                    var frame = Data("\(String(chunk.count, radix: 16))\r\n".utf8)
                    frame.append(chunk)
                    frame.append(Data("\r\n".utf8))
                    frame.withUnsafeBytes { buffer in
                        _ = systemSend(fd, buffer.baseAddress!, frame.count, 0)
                    }
                    counter.add(chunk.count)
                }
            } catch {
                // The head is already on the wire; a truncated chunked body is
                // what a client sees, which is the honest signal.
            }
            done.signal()
        }
        done.wait()

        let terminator = Data("0\r\n\r\n".utf8)
        terminator.withUnsafeBytes { buffer in
            _ = systemSend(fd, buffer.baseAddress!, terminator.count, 0)
        }
        MetricsCollector.shared.recordResponseStreamed(bytes: counter.total)
    }

    private static func statusText(_ statusCode: Int) -> String {
        switch statusCode {
        case 200: return "OK"
        case 201: return "Created"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 413: return "Payload Too Large"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        default: return "Unknown"
        }
    }

    private func sendResponse(fd: Int32, statusCode: Int, headers: [String: String] = [:], body: String) {
        sendResponse(fd: fd, statusCode: statusCode, headers: headers, bodyData: body.data(using: .utf8))
    }

    private func sendResponse(fd: Int32, statusCode: Int, headers: [String: String] = [:], bodyData: Data?) {
        let statusText: String
        switch statusCode {
        case 200: statusText = "OK"
        case 201: statusText = "Created"
        case 400: statusText = "Bad Request"
        case 404: statusText = "Not Found"
        case 500: statusText = "Internal Server Error"
        case 501: statusText = "Not Implemented"
        default: statusText = "Unknown"
        }

        var response = "HTTP/1.1 \(statusCode) \(statusText)\r\n"

        var finalHeaders = headers
        if finalHeaders["Content-Type"] == nil {
            finalHeaders["Content-Type"] = "application/json"
        }
        if let body = bodyData {
            finalHeaders["Content-Length"] = String(body.count)
        }
        finalHeaders["Connection"] = "close"

        for (name, value) in finalHeaders {
            response += "\(name): \(value)\r\n"
        }
        response += "\r\n"

        // Send headers
        let headerData = Data(response.utf8)
        headerData.withUnsafeBytes { buffer in
            _ = systemSend(fd, buffer.baseAddress!, headerData.count, 0)
        }

        // Send body
        if let body = bodyData {
            body.withUnsafeBytes { buffer in
                _ = systemSend(fd, buffer.baseAddress!, body.count, 0)
            }
        }
    }

    // MARK: - WebSocket Support

    /// Check if request is a WebSocket upgrade request
    private func isWebSocketUpgrade(path: String, headers: [String: String]) -> Bool {
        guard path == wsPath || path.hasPrefix(wsPath + "?") else { return false }
        let upgrade = headers["Upgrade"]?.lowercased() ?? headers["upgrade"]?.lowercased()
        let connection = headers["Connection"]?.lowercased() ?? headers["connection"]?.lowercased()
        return upgrade == "websocket" && (connection?.contains("upgrade") ?? false)
    }

    /// Perform WebSocket handshake
    private func performWebSocketHandshake(fd: Int32, headers: [String: String]) -> Bool {
        guard let key = headers["Sec-WebSocket-Key"] ?? headers["sec-websocket-key"] else {
            return false
        }

        // WebSocket magic string
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let combined = key + magic

        // SHA-1 hash and base64 encode
        guard let data = combined.data(using: .utf8),
              let hash = sha1(data) else {
            return false
        }

        let acceptKey = hash.base64EncodedString()

        // Build handshake response
        var response = "HTTP/1.1 101 Switching Protocols\r\n"
        response += "Upgrade: websocket\r\n"
        response += "Connection: Upgrade\r\n"
        response += "Sec-WebSocket-Accept: \(acceptKey)\r\n"
        response += "\r\n"

        // Send response
        guard let responseData = response.data(using: .utf8) else { return false }
        var sent = 0
        while sent < responseData.count {
            let result = responseData.withUnsafeBytes { buffer in
                systemSend(fd, buffer.baseAddress!.advanced(by: sent), responseData.count - sent, 0)
            }
            if result <= 0 { return false }
            sent += result
        }

        return true
    }

    /// SHA-1 hash implementation
    private func sha1(_ data: Data) -> Data? {
        #if os(macOS)
        var hash = [UInt8](repeating: 0, count: 20)
        data.withUnsafeBytes { buffer in
            _ = CC_SHA1(buffer.baseAddress, CC_LONG(data.count), &hash)
        }
        return Data(hash)
        #elseif os(Linux)
        // Use Swift Crypto on Linux
        let digest = Insecure.SHA1.hash(data: data)
        return Data(digest)
        #else
        return nil
        #endif
    }

    /// Handle WebSocket connection
    private func handleWebSocket(fd: Int32, connectionId: String) {
        // Register connection
        wsLock.lock()
        wsConnections[connectionId] = fd
        wsLock.unlock()

        // Emit connect event
        eventBus?.publish(WebSocketConnectedEvent(
            connectionId: connectionId,
            path: wsPath,
            remoteAddress: "unknown"
        ))
        // DomainEvent co-publish for binary mode compiled handlers.
        // DomainEvent eventType: "websocket.connected"
        // DomainEvent payload:   { "connectionId": String, "path": String, "remoteAddress": String }
        EventBus.shared.publish(DomainEvent(eventType: "websocket.connected", payload: [
            "connectionId": connectionId,
            "path": wsPath,
            "remoteAddress": "unknown"
        ]))

        defer {
            // Cleanup on disconnect
            wsLock.lock()
            wsConnections.removeValue(forKey: connectionId)
            wsLock.unlock()

            // Emit disconnect event
            eventBus?.publish(WebSocketDisconnectedEvent(
                connectionId: connectionId,
                reason: "connection closed"
            ))
            // DomainEvent co-publish for binary mode compiled handlers.
            // DomainEvent eventType: "websocket.disconnected"
            // DomainEvent payload:   { "connectionId": String, "reason": String }
            EventBus.shared.publish(DomainEvent(eventType: "websocket.disconnected", payload: [
                "connectionId": connectionId,
                "reason": "connection closed"
            ]))

            _ = systemClose(fd)
        }

        // WebSocket frame reading loop
        var buffer = [UInt8](repeating: 0, count: 8192)
        while isRunning {
            // Wait for data with timeout
            if !waitForData(fd: fd, timeoutMs: 1000) {
                continue // Timeout, check if still running
            }

            let bytesRead = recv(fd, &buffer, buffer.count, 0)
            guard bytesRead > 0 else {
                break // Connection closed or error
            }

            // Parse WebSocket frame
            guard let frame = parseWebSocketFrame(Data(buffer[0..<bytesRead])) else {
                continue
            }

            switch frame.opcode {
            case 0x1: // Text frame
                if let text = String(data: frame.payload, encoding: .utf8) {
                    // Emit message event
                    eventBus?.publish(WebSocketMessageEvent(
                        connectionId: connectionId,
                        message: text
                    ))
                    // DomainEvent co-publish for binary mode compiled handlers.
                    // DomainEvent eventType: "websocket.message"
                    // DomainEvent payload:   { "connectionId": String, "message": String }
                    EventBus.shared.publish(DomainEvent(eventType: "websocket.message", payload: [
                        "connectionId": connectionId,
                        "message": text
                    ]))
                }

            case 0x8: // Close frame
                // Send close frame back
                sendWebSocketFrame(fd: fd, opcode: 0x8, payload: Data())
                return

            case 0x9: // Ping frame
                // Send pong
                sendWebSocketFrame(fd: fd, opcode: 0xA, payload: frame.payload)

            default:
                break
            }
        }
    }

    /// Parse a WebSocket frame
    private func parseWebSocketFrame(_ data: Data) -> (opcode: UInt8, payload: Data)? {
        guard data.count >= 2 else { return nil }

        let byte0 = data[0]
        let byte1 = data[1]

        let opcode = byte0 & 0x0F
        let masked = (byte1 & 0x80) != 0
        var payloadLen = UInt64(byte1 & 0x7F)
        var offset = 2

        // Extended payload length
        if payloadLen == 126 {
            guard data.count >= 4 else { return nil }
            payloadLen = UInt64(data[2]) << 8 | UInt64(data[3])
            offset = 4
        } else if payloadLen == 127 {
            guard data.count >= 10 else { return nil }
            payloadLen = 0
            for i in 0..<8 {
                payloadLen |= UInt64(data[2 + i]) << (56 - 8 * i)
            }
            offset = 10
        }

        // Read mask key if present
        var maskKey: [UInt8]? = nil
        if masked {
            guard data.count >= offset + 4 else { return nil }
            maskKey = Array(data[offset..<offset + 4])
            offset += 4
        }

        // Extract payload
        guard data.count >= offset + Int(payloadLen) else { return nil }
        var payload = Data(data[offset..<offset + Int(payloadLen)])

        // Unmask payload
        if let mask = maskKey {
            for i in 0..<payload.count {
                payload[i] ^= mask[i % 4]
            }
        }

        return (opcode, payload)
    }

    /// Send a WebSocket frame
    private func sendWebSocketFrame(fd: Int32, opcode: UInt8, payload: Data) {
        var frame = Data()

        // First byte: FIN + opcode
        frame.append(0x80 | opcode)

        // Payload length (no masking for server-to-client)
        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else if payload.count < 65536 {
            frame.append(126)
            frame.append(UInt8((payload.count >> 8) & 0xFF))
            frame.append(UInt8(payload.count & 0xFF))
        } else {
            frame.append(127)
            for i in (0..<8).reversed() {
                frame.append(UInt8((payload.count >> (8 * i)) & 0xFF))
            }
        }

        // Payload
        frame.append(payload)

        // Send
        frame.withUnsafeBytes { buffer in
            _ = systemSend(fd, buffer.baseAddress!, frame.count, 0)
        }
    }

    /// Broadcast a message to all WebSocket connections
    public func broadcastWebSocket(message: String) -> Int {
        guard let payload = message.data(using: .utf8) else { return 0 }

        wsLock.lock()
        let connections = wsConnections
        wsLock.unlock()

        var sentCount = 0
        for (_, fd) in connections {
            sendWebSocketFrame(fd: fd, opcode: 0x1, payload: payload)
            sentCount += 1
        }

        return sentCount
    }
}

/// Global native HTTP server instance
///
/// Sendable-safety: assigned exactly once when the compiled binary starts its
/// HTTP server, before any request-handling thread runs, and only read (never
/// reassigned) thereafter. Route mutation that happens alongside it is guarded
/// by `httpServerLock` below.
nonisolated(unsafe) public var nativeHTTPServer: NativeHTTPServer?
private let httpServerLock = NSLock()

// MARK: - JSON Conversion Helpers

/// Unwrap AnySendable for JSON serialization (uses get<T>() to access private value)
/// If the value is a JSON string, parse it back to an object
private func unwrapAnySendableForJSON(_ anySendable: AnySendable) -> Any {
    // Try each concrete type using the public get<T>() method
    if let str: String = anySendable.get() {
        // Check if the string is JSON - if so, parse it.
        // try? is acceptable: this is a probe — a string that merely starts
        // with "{"/"[" need not be JSON, and the raw string is returned
        // unchanged when parsing fails, so nothing is lost.
        if str.hasPrefix("{") || str.hasPrefix("[") {
            if let jsonData = str.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: jsonData) {
                return parsed
            }
        }
        return str
    }
    if let int: Int = anySendable.get() {
        return int
    }
    if let double: Double = anySendable.get() {
        return double
    }
    if let bool: Bool = anySendable.get() {
        return bool
    }
    if let dict: [String: any Sendable] = anySendable.get() {
        var result: [String: Any] = [:]
        for (k, v) in dict {
            result[k] = unwrapSendableForJSON(v)
        }
        return result
    }
    if let array: [any Sendable] = anySendable.get() {
        return array.map { unwrapSendableForJSON($0) }
    }
    // Fallback for unknown types
    return "{}"
}

/// Unwrap any Sendable value for JSON serialization
private func unwrapSendableForJSON(_ value: any Sendable) -> Any {
    switch value {
    case let str as String:
        return str
    case let int as Int:
        return int
    case let double as Double:
        return double
    case let bool as Bool:
        return bool
    case let dict as [String: any Sendable]:
        var result: [String: Any] = [:]
        for (k, v) in dict {
            result[k] = unwrapSendableForJSON(v)
        }
        return result
    case let array as [any Sendable]:
        return array.map { unwrapSendableForJSON($0) }
    case let anySendable as AnySendable:
        return unwrapAnySendableForJSON(anySendable)
    default:
        return String(describing: value)
    }
}

/// Convert Any (from JSON) to Sendable
private func convertAnyToSendable(_ value: Any) -> any Sendable {
    switch value {
    case let str as String:
        return str
    case let int as Int:
        return int
    case let double as Double:
        return double
    case let bool as Bool:
        return bool
    case let dict as [String: Any]:
        var result: [String: any Sendable] = [:]
        for (k, v) in dict {
            result[k] = convertAnyToSendable(v)
        }
        return result
    case let array as [Any]:
        return array.map { convertAnyToSendable($0) }
    case is NSNull:
        return "" // Represent null as empty string
    default:
        return String(describing: value)
    }
}

// MARK: - Compiled-binary bootstrap registries
//
// Sendable-safety (applies to every `nonisolated(unsafe)` global in this
// section): these are write-once-at-startup / read-only-at-runtime tables. In a
// compiled ARO binary the generated `main` calls the `@_cdecl` registration and
// `aro_set_*` entry points (`aro_http_register_route`,
// `aro_register_static_plugin`, `aro_set_embedded_openapi`, …) sequentially on a
// single thread during bootstrap, BEFORE the HTTP server accept loop / event
// loop starts. Once serving begins these tables are only ever read, so the
// concurrent readers never overlap a writer. `httpRoutes` mutation is
// additionally taken under `httpServerLock` at its append sites as belt-and-
// braces. There is no post-startup mutation path.

/// Registered feature set handlers for HTTP routing
/// Maps operationId to a function that executes the feature set
/// Sendable-safety: see "Compiled-binary bootstrap registries" note above.
nonisolated(unsafe) public var httpRouteHandlers: [String: (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?] = [:]

/// Route registry for matching paths to operationIds
/// Sendable-safety: see bootstrap note above; appends also hold `httpServerLock`.
nonisolated(unsafe) public var httpRoutes: [(method: String, path: String, operationId: String)] = []

/// Response content type registry for operationIds (extracted from OpenAPI spec)
/// Sendable-safety: see "Compiled-binary bootstrap registries" note above.
nonisolated(unsafe) public var httpResponseContentTypes: [String: String] = [:]

/// Global storage for embedded OpenAPI spec (JSON string, set at compile time)
/// Sendable-safety: see "Compiled-binary bootstrap registries" note above.
nonisolated(unsafe) public var embeddedOpenAPISpec: String? = nil

/// Global storage for embedded templates (JSON dictionary: path -> content, set at compile time)
/// Sendable-safety: see "Compiled-binary bootstrap registries" note above.
nonisolated(unsafe) public var embeddedTemplates: [String: String]? = nil

/// Global registry for embedded plugin libraries (base64-encoded .so files compiled into the binary)
/// Key: plugin name, Value: (yaml: plugin.yaml content, base64So: base64-encoded library bytes)
/// Sendable-safety: see "Compiled-binary bootstrap registries" note above.
nonisolated(unsafe) public var embeddedPluginRegistry: [String: (yaml: String, base64So: String)] = [:]

/// Entry for a statically-linked plugin whose function pointers are baked into the binary
public struct StaticPluginEntry {
    public let yaml: String
    public let infoFunc: UnsafeRawPointer?
    public let executeFunc: UnsafeRawPointer?
    public let freeFunc: UnsafeRawPointer?
    public let qualifierFunc: UnsafeRawPointer?
    public let initFunc: UnsafeRawPointer?
    public let shutdownFunc: UnsafeRawPointer?
}

/// Global registry for statically-linked plugins (function pointers, no dlopen)
/// Key: plugin name, Value: StaticPluginEntry with function pointers and YAML metadata
/// Sendable-safety: see "Compiled-binary bootstrap registries" note above.
nonisolated(unsafe) public var staticPluginRegistry: [String: StaticPluginEntry] = [:]

/// Entry for an embedded Python plugin (source + deps bundled in binary)
public struct EmbeddedPythonPluginEntry {
    public let yaml: String
    public let source: String
    public let stdlibZip: Data?
    public let depsZip: Data?
}

/// Global registry for embedded Python plugins (source + deps, executed in-process)
/// Key: plugin name, Value: EmbeddedPythonPluginEntry
/// Sendable-safety: see "Compiled-binary bootstrap registries" note above.
nonisolated(unsafe) public var embeddedPythonPluginRegistry: [String: EmbeddedPythonPluginEntry] = [:]

/// Embedded Python stdlib zip data (shared across all Python plugins)
/// Sendable-safety: see "Compiled-binary bootstrap registries" note above.
nonisolated(unsafe) public var embeddedPythonStdlibZip: Data? = nil

/// Embedded Python site-packages zip data (all pip deps bundled together)
/// Sendable-safety: see "Compiled-binary bootstrap registries" note above.
nonisolated(unsafe) public var embeddedPythonDepsZip: Data? = nil

/// Set the embedded OpenAPI spec (called from generated main)
@_cdecl("aro_set_embedded_openapi")
public func aro_set_embedded_openapi(_ specPtr: UnsafePointer<CChar>?) {
    guard let ptr = specPtr else { return }
    embeddedOpenAPISpec = String(cString: ptr)
}

/// Set the embedded templates (called from generated main) - ARO-0050
@_cdecl("aro_set_embedded_templates")
public func aro_set_embedded_templates(_ jsonPtr: UnsafePointer<CChar>?) {
    guard let ptr = jsonPtr else { return }
    let jsonString = String(cString: ptr)

    // Parse the JSON dictionary. The JSON is generated at compile time, so a
    // parse failure means the embedded template table is corrupt: returning
    // silently would make every Render fail later with no clue why — log it.
    guard let data = jsonString.data(using: .utf8),
          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
        FileHandle.standardError.write(Data("[ServiceBridge] Warning: unparseable embedded templates JSON, templates unavailable\n".utf8))
        return
    }
    embeddedTemplates = dict
}

/// Register an embedded plugin library (called from generated main for each compiled plugin)
/// - Parameters:
///   - namePtr: Plugin name (e.g., "postgres")
///   - yamlPtr: Content of plugin.yaml
///   - base64Ptr: Base64-encoded bytes of the compiled .so/.dylib
@_cdecl("aro_register_embedded_plugin")
public func aro_register_embedded_plugin(
    _ namePtr: UnsafePointer<CChar>?,
    _ yamlPtr: UnsafePointer<CChar>?,
    _ base64Ptr: UnsafePointer<CChar>?
) {
    guard let namePtr, let yamlPtr, let base64Ptr else { return }
    let name = String(cString: namePtr)
    let yaml = String(cString: yamlPtr)
    let base64 = String(cString: base64Ptr)
    embeddedPluginRegistry[name] = (yaml: yaml, base64So: base64)
}

/// Register a statically-linked plugin with function pointers (no dlopen needed)
/// Called from generated main() for each native plugin compiled into the binary.
/// - Parameters:
///   - namePtr: Plugin name
///   - yamlPtr: Content of plugin.yaml
///   - infoFunc: Pointer to renamed aro_plugin_info function (or null)
///   - executeFunc: Pointer to renamed aro_plugin_execute function (or null)
///   - freeFunc: Pointer to renamed aro_plugin_free function (or null)
///   - qualifierFunc: Pointer to renamed aro_plugin_qualifier function (or null)
///   - initFunc: Pointer to renamed aro_plugin_init function (or null)
///   - shutdownFunc: Pointer to renamed aro_plugin_shutdown function (or null)
@_cdecl("aro_register_static_plugin")
public func aro_register_static_plugin(
    _ namePtr: UnsafePointer<CChar>?,
    _ yamlPtr: UnsafePointer<CChar>?,
    _ infoFunc: UnsafeRawPointer?,
    _ executeFunc: UnsafeRawPointer?,
    _ freeFunc: UnsafeRawPointer?,
    _ qualifierFunc: UnsafeRawPointer?,
    _ initFunc: UnsafeRawPointer?,
    _ shutdownFunc: UnsafeRawPointer?
) {
    guard let namePtr, let yamlPtr else { return }
    let name = String(cString: namePtr)
    let yaml = String(cString: yamlPtr)
    staticPluginRegistry[name] = StaticPluginEntry(
        yaml: yaml,
        infoFunc: infoFunc,
        executeFunc: executeFunc,
        freeFunc: freeFunc,
        qualifierFunc: qualifierFunc,
        initFunc: initFunc,
        shutdownFunc: shutdownFunc
    )
}

/// Register an embedded Python plugin (source code + YAML metadata)
/// Called from generated main() for each Python plugin compiled into the binary.
@_cdecl("aro_register_embedded_python_plugin")
public func aro_register_embedded_python_plugin(
    _ namePtr: UnsafePointer<CChar>?,
    _ yamlPtr: UnsafePointer<CChar>?,
    _ sourcePtr: UnsafePointer<CChar>?
) {
    guard let namePtr, let yamlPtr, let sourcePtr else { return }
    let name = String(cString: namePtr)
    let yaml = String(cString: yamlPtr)
    let source = String(cString: sourcePtr)
    embeddedPythonPluginRegistry[name] = EmbeddedPythonPluginEntry(
        yaml: yaml,
        source: source,
        stdlibZip: nil,
        depsZip: nil
    )
}

/// Set the embedded Python stdlib zip data (called once from generated main)
@_cdecl("aro_set_python_stdlib")
public func aro_set_python_stdlib(_ dataPtr: UnsafePointer<UInt8>?, _ length: Int64) {
    guard let dataPtr, length > 0 else { return }
    embeddedPythonStdlibZip = Data(bytes: dataPtr, count: Int(length))
}

/// Set the embedded Python deps zip data (called once from generated main)
@_cdecl("aro_set_python_deps")
public func aro_set_python_deps(_ dataPtr: UnsafePointer<UInt8>?, _ length: Int64) {
    guard let dataPtr, length > 0 else { return }
    embeddedPythonDepsZip = Data(bytes: dataPtr, count: Int(length))
}

/// Register a feature set handler for HTTP routing
@_cdecl("aro_http_register_route")
public func aro_http_register_route(
    _ method: UnsafePointer<CChar>?,
    _ path: UnsafePointer<CChar>?,
    _ operationId: UnsafePointer<CChar>?
) {
    guard let methodStr = method.map({ String(cString: $0) }),
          let pathStr = path.map({ String(cString: $0) }),
          let opId = operationId.map({ String(cString: $0) }) else { return }

    httpServerLock.lock()
    httpRoutes.append((method: methodStr, path: pathStr, operationId: opId))
    httpServerLock.unlock()
}

/// Per-route body policy, baked in at build time (GitLab #477).
///
/// The compiled binary has no AST to analyse at startup, so the answer travels
/// with it: `aro build` runs the materialization analysis, reads the route's
/// `x-aro-max-body`, and emits one of these calls per operation into `main`.
/// The interpreter computes the same two facts from the same analysis when it
/// installs its resolver — one analysis, two front ends, same behaviour.
nonisolated(unsafe) private var httpBodyPolicies: [String: BodyPolicy] = [:]

/// Register the body policy for one operation.
/// - Parameters:
///   - operationId: the operation the policy applies to
///   - streams: 1 when the feature set only moves its body, 0 when it reads it
///   - limit: `x-aro-max-body` as written (`256KB`), or empty for the default
@_cdecl("aro_http_set_body_policy")
public func aro_http_set_body_policy(
    _ operationId: UnsafePointer<CChar>?,
    _ streams: Int32,
    _ limit: UnsafePointer<CChar>?
) {
    guard let opId = operationId.map({ String(cString: $0) }), !opId.isEmpty else { return }
    let declaredText = limit.map { String(cString: $0) } ?? ""
    let declared = declaredText.isEmpty ? nil : ByteSize.parse(declaredText)
    let ceiling = declared ?? RuntimeDefaults.maxMaterializedBody

    httpServerLock.lock()
    httpBodyPolicies[opId] = streams != 0
        ? .streamed(materializationLimit: ceiling)
        : .buffered(limit: ceiling)
    httpServerLock.unlock()
}

/// Start native HTTP server
@_cdecl("aro_native_http_server_start")
public func aro_native_http_server_start(_ port: Int32, _ contextPtr: UnsafeMutableRawPointer?) -> Int32 {
    httpServerLock.lock()
    defer { httpServerLock.unlock() }

    // Create server if needed
    if nativeHTTPServer == nil {
        nativeHTTPServer = NativeHTTPServer(port: Int(port))

        // Set eventBus - use context's eventBus if available, otherwise use shared
        let eventBus: EventBus
        if let ptr = contextPtr {
            let ctxHandle = Unmanaged<AROCContextHandle>.fromOpaque(ptr).takeUnretainedValue()
            eventBus = ctxHandle.context.eventBus ?? EventBus.shared
        } else {
            eventBus = EventBus.shared
        }
        nativeHTTPServer?.setEventBus(eventBus)

        // Subscribe to WebSocket broadcast events
        eventBus.subscribe(to: WebSocketBroadcastRequestedEvent.self) { event in
            _ = nativeHTTPServer?.broadcastWebSocket(message: event.message)
        }

        // Per-route body policy (GitLab #477), from the calls the generated
        // `main` made before starting the server.
        nativeHTTPServer?.onBodyPolicy { method, path in
            for route in httpRoutes where route.method == method {
                if matchPath(pattern: route.path, actual: path) != nil {
                    return httpBodyPolicies[route.operationId] ?? .default
                }
            }
            return .default
        }

        // Set up request handler
        nativeHTTPServer?.onRequest { method, path, headers, body in
            // Parse path and query string
            let pathComponents = path.split(separator: "?", maxSplits: 1)
            let pathWithoutQuery = String(pathComponents[0])
            var queryParams: [String: String] = [:]
            if pathComponents.count > 1 {
                let queryString = String(pathComponents[1])
                for pair in queryString.split(separator: "&") {
                    let kv = pair.split(separator: "=", maxSplits: 1)
                    if kv.count == 2 {
                        let key = decodeQueryComponent(String(kv[0]))
                        let value = decodeQueryComponent(String(kv[1]))
                        queryParams[key] = value
                    } else if kv.count == 1 {
                        let key = decodeQueryComponent(String(kv[0]))
                        queryParams[key] = ""
                    }
                }
            }

            // Match route to operationId (using path without query string)
            // Supports OpenAPI path parameters like /users/{id}
            var matchedOperationId: String? = nil
            var pathParams: [String: String] = [:]

            for route in httpRoutes {
                if route.method == method {
                    if let params = matchPath(pattern: route.path, actual: pathWithoutQuery) {
                        matchedOperationId = route.operationId
                        pathParams = params
                        break
                    }
                }
            }

            /// A `Return` of an unread body writes it straight back out, chunk
            /// by chunk (GitLab #477) — the same answer the interpreter gives,
            /// so an echo or a proxy costs a chunk in either mode.
            func streamedResponse(_ ctxPtr: UnsafeMutableRawPointer?) -> NativeHTTPResponse? {
                guard let ptr = ctxPtr else { return nil }
                let ctxHandle = Unmanaged<AROCContextHandle>.fromOpaque(ptr).takeUnretainedValue()
                guard ctxHandle.context.getExecutionError() == nil,
                      let response = ctxHandle.context.getResponse() else { return nil }

                for value in response.data.values {
                    let body: (any UnreadBody)? = (value.get() as RequestBodyValue?)
                        ?? (value.get() as AnchoredBody?)
                    guard let body else { continue }
                    let statement = "Return a <\(response.status): status> with the request body"
                    // try? is acceptable: a body already consumed by an earlier
                    // statement cannot be streamed again, and that case belongs
                    // to the normal response path — which reports it as the
                    // consumed-twice error rather than swallowing it here.
                    guard let chunks = try? body.chunkStream(consumer: statement) else { continue }
                    let statusLower = response.status.lowercased()
                    let statusCode = statusLower == "created" ? 201 :
                                     statusLower == "accepted" ? 202 :
                                     statusLower == "error" ? 400 : 200
                    return NativeHTTPResponse(
                        status: statusCode,
                        headers: ["Content-Type": body.contentType ?? "application/octet-stream"],
                        stream: chunks
                    )
                }
                return nil
            }

            // Helper function to extract response from context and serialize appropriately
            func getContextResponse(_ ctxPtr: UnsafeMutableRawPointer?, operationId: String?, requestPath: String = "") -> (Int, [String: String], Data?) {
                guard let ptr = ctxPtr else {
                    return (500, ["Content-Type": "application/json"], "{\"error\":\"No context\"}".data(using: .utf8))
                }
                let ctxHandle = Unmanaged<AROCContextHandle>.fromOpaque(ptr).takeUnretainedValue()

                // Check for execution errors first (e.g., from Accept action validation failures)
                if let error = ctxHandle.context.getExecutionError() {
                    let errorMsg = error.localizedDescription

                    // Check for template not found errors - return 404
                    // In binary mode, errors are wrapped as ActionError.runtimeError with the message
                    if let templateError = error as? TemplateError {
                        if case .notFound = templateError {
                            let msg = templateError.errorDescription ?? "Template not found"
                            let errorJson = "{\"error\":\"Not Found\",\"message\":\"\(msg.replacingOccurrences(of: "\"", with: "\\\""))\"}".data(using: .utf8)
                            return (404, ["Content-Type": "application/json"], errorJson)
                        }
                    }
                    // Check for template not found pattern in error message (binary mode)
                    else if errorMsg.contains("Template not found:") || errorMsg.contains("notFound(path:") {
                        let escapedMsg = errorMsg.replacingOccurrences(of: "\"", with: "\\\"")
                        let errorJson = "{\"error\":\"Not Found\",\"message\":\"\(escapedMsg)\"}".data(using: .utf8)
                        return (404, ["Content-Type": "application/json"], errorJson)
                    }

                    let escapedMsg = errorMsg.replacingOccurrences(of: "\"", with: "\\\"")
                    let errorJson = "{\"error\":\"\(escapedMsg)\"}".data(using: .utf8)
                    return (500, ["Content-Type": "application/json"], errorJson)
                }

                if let response = ctxHandle.context.getResponse() {
                    // Convert Response.data to JSON, returning just the data portion
                    let statusLower = response.status.lowercased()
                    let statusCode = statusLower == "ok" ? 200 :
                                   statusLower == "created" ? 201 :
                                   statusLower == "accepted" ? 202 :
                                   statusLower == "nocontent" ? 204 :
                                   statusLower == "error" ? 400 : 200

                    // For 204 No Content, return empty body
                    if statusCode == 204 {
                        return (204, [:], nil)
                    }

                    // Get expected content type from OpenAPI spec
                    let expectedContentType = operationId.flatMap { httpResponseContentTypes[$0] }

                    // Check for single-value response that should be returned as-is
                    if response.data.count == 1, let (_, anySendable) = response.data.first {
                        if let str: String = anySendable.get() {
                            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)

                            // Priority 1: Detect MIME type from request path file extension
                            let lowercasePath = requestPath.lowercased()
                            if lowercasePath.hasSuffix(".css") {
                                return (statusCode, ["Content-Type": "text/css; charset=utf-8"], str.data(using: .utf8))
                            } else if lowercasePath.hasSuffix(".js") {
                                return (statusCode, ["Content-Type": "text/javascript; charset=utf-8"], str.data(using: .utf8))
                            } else if lowercasePath.hasSuffix(".json") {
                                return (statusCode, ["Content-Type": "application/json; charset=utf-8"], str.data(using: .utf8))
                            } else if lowercasePath.hasSuffix(".html") || lowercasePath.hasSuffix(".htm") {
                                return (statusCode, ["Content-Type": "text/html; charset=utf-8"], str.data(using: .utf8))
                            } else if lowercasePath.hasSuffix(".xml") {
                                return (statusCode, ["Content-Type": "application/xml; charset=utf-8"], str.data(using: .utf8))
                            } else if lowercasePath.hasSuffix(".txt") {
                                return (statusCode, ["Content-Type": "text/plain; charset=utf-8"], str.data(using: .utf8))
                            } else if lowercasePath.hasSuffix(".svg") {
                                return (statusCode, ["Content-Type": "image/svg+xml"], str.data(using: .utf8))
                            }

                            // Priority 2: If OpenAPI specifies a content type, honor it
                            if expectedContentType == "text/html" {
                                return (statusCode, ["Content-Type": "text/html; charset=utf-8"], str.data(using: .utf8))
                            }

                            // ARO-0044: Honor text/plain for metrics endpoint (Prometheus format)
                            if expectedContentType == "text/plain" {
                                return (statusCode, ["Content-Type": "text/plain; version=0.0.4; charset=utf-8"], str.data(using: .utf8))
                            }

                            // Priority 3: Content-based detection (fallback)
                            // Detect HTML content
                            if trimmed.hasPrefix("<!DOCTYPE") || trimmed.hasPrefix("<!doctype") ||
                               trimmed.hasPrefix("<html") || trimmed.hasPrefix("<HTML") {
                                return (statusCode, ["Content-Type": "text/html; charset=utf-8"], str.data(using: .utf8))
                            }

                            // Detect JavaScript content
                            if trimmed.hasPrefix("var ") || trimmed.hasPrefix("let ") ||
                               trimmed.hasPrefix("const ") || trimmed.hasPrefix("function ") ||
                               trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") ||
                               trimmed.hasPrefix("'use strict'") || trimmed.hasPrefix("\"use strict\"") ||
                               trimmed.hasPrefix("(function") || trimmed.hasPrefix("import ") ||
                               trimmed.hasPrefix("export ") {
                                return (statusCode, ["Content-Type": "text/javascript; charset=utf-8"], str.data(using: .utf8))
                            }

                            // Detect CSS content
                            if !trimmed.hasPrefix("{") && !trimmed.hasPrefix("<") {
                                // try? is acceptable: the pattern is a hardcoded
                                // literal that always compiles; a nil here only
                                // skips the CSS content-type sniff and the body
                                // falls through to JSON handling below.
                                let cssPattern = try? NSRegularExpression(
                                    pattern: "^(@|\\*|[a-zA-Z][a-zA-Z0-9-]*|\\.[a-zA-Z]|#[a-zA-Z])[^{]*\\{",
                                    options: []
                                )
                                if let match = cssPattern?.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
                                   match.range.location != NSNotFound {
                                    return (statusCode, ["Content-Type": "text/css; charset=utf-8"], str.data(using: .utf8))
                                }
                            }
                        }
                    }

                    // Build JSON from response data
                    var jsonDict: [String: Any] = [:]
                    for (key, anySendable) in response.data {
                        jsonDict[key] = unwrapAnySendableForJSON(anySendable)
                    }

                    // If no data, include status as fallback
                    if jsonDict.isEmpty {
                        jsonDict["status"] = response.status
                    }

                    // Serialize the response body. A failure here means the
                    // handler produced a value JSONSerialization can't encode
                    // (e.g. a non-JSON object slipped into response.data) — the
                    // client would get a bare {"status":"ok"} with the real data
                    // silently dropped, so surface it.
                    if let jsonData = try? JSONSerialization.data(withJSONObject: jsonDict, options: [.sortedKeys]) {
                        return (statusCode, ["Content-Type": "application/json"], jsonData)
                    }
                    FileHandle.standardError.write(Data("[ServiceBridge] Warning: response data not JSON-serializable, returning status-only body: keys=\(Array(jsonDict.keys))\n".utf8))
                }
                return (200, ["Content-Type": "application/json"], "{\"status\":\"ok\"}".data(using: .utf8))
            }

            // Helper to bind request data to context
            func bindRequestToContext(_ ctxPtr: UnsafeMutableRawPointer?, body: NativeRequestBody, headers: [String: String], path: String, queryParams: [String: String], pathParams: [String: String]) {
                guard let ptr = ctxPtr else { return }
                let ctxHandle = Unmanaged<AROCContextHandle>.fromOpaque(ptr).takeUnretainedValue()

                // Bind request as a dictionary with body, headers, etc.
                var requestDict: [String: any Sendable] = [:]

                // A body that has not been read binds as itself (GitLab #477).
                // The actions resolve it out of this same context, so a stream
                // never has to cross the C ABI — only the descriptors do.
                if case .streaming(let source) = body {
                    let contentType = headers.first { $0.key.lowercased() == "content-type" }?.value
                    let unread = RequestBodyValue(
                        source: source,
                        contentType: contentType,
                        route: "\(headers["X-ARO-Method"] ?? "POST") \(path)"
                    )
                    requestDict["body"] = unread
                    ctxHandle.context.bind("body", value: unread)
                }

                // Parse body as JSON if possible, otherwise as string.
                // try? is acceptable: request bodies are legitimately either JSON
                // or plain text/form data, so a parse failure is expected content
                // negotiation — the body is bound as a raw string instead, no loss.
                if let bodyData = body.data {
                    if let json = try? JSONSerialization.jsonObject(with: bodyData),
                       let dict = json as? [String: Any] {
                        // Body is JSON - convert to Sendable dict
                        var bodyDict: [String: any Sendable] = [:]
                        for (k, v) in dict {
                            bodyDict[k] = convertAnyToSendable(v)
                        }
                        requestDict["body"] = bodyDict
                        // Also bind body directly for <Extract> the <x> from the <body: field>.
                        ctxHandle.context.bind("body", value: bodyDict)
                    } else if let bodyStr = String(data: bodyData, encoding: .utf8) {
                        requestDict["body"] = bodyStr
                        ctxHandle.context.bind("body", value: bodyStr)
                    }
                }

                requestDict["path"] = path
                requestDict["headers"] = headers

                ctxHandle.context.bind("request", value: requestDict)

                // Bind query parameters for <Extract> the <x> from the <queryParameters: y>
                ctxHandle.context.bind("queryParameters", value: queryParams)

                // Bind path parameters for <Extract> the <id> from the <pathParameters: id>
                ctxHandle.context.bind("pathParameters", value: pathParams)
            }

            // If route matched, try to invoke the feature set
            if let opId = matchedOperationId {
                // Create a fresh context for this request if none provided
                let requestContext: UnsafeMutableRawPointer?
                if let providedCtx = contextPtr {
                    requestContext = providedCtx
                } else {
                    // Create new context via aro_context_create using global runtime
                    requestContext = aro_context_create(globalRuntimePtr)
                }

                // Lookup business activity for this feature set and bind published variables
                if let activity = aro_lookup_business_activity(opId) {
                    aro_context_bind_published_variables(requestContext, activity)
                    free(activity)  // Free the C string returned by lookup
                } else {
                    // No business activity found, bind with empty string
                    aro_context_bind_published_variables(requestContext, nil)
                }

                // Bind request data to context before invoking handler
                bindRequestToContext(requestContext, body: body, headers: headers, path: pathWithoutQuery, queryParams: queryParams, pathParams: pathParams)

                // First check for registered handler
                if let handler = httpRouteHandlers[opId] {
                    _ = handler(requestContext)
                    if let streamed = streamedResponse(requestContext) {
                        if contextPtr == nil, let ctx = requestContext {
                            aro_context_destroy(ctx)
                        }
                        return streamed
                    }
                    let response = getContextResponse(requestContext, operationId: opId, requestPath: pathWithoutQuery)
                    // Clean up if we created the context
                    if contextPtr == nil, let ctx = requestContext {
                        aro_context_destroy(ctx)
                    }
                    return NativeHTTPResponse(response)
                }

                // Try to find the compiled feature set function via dlsym
                // Must match LLVMCodeGenerator.mangleFeatureSetName()
                let functionName = "aro_fs_" + opId
                    .replacingOccurrences(of: "-", with: "_")
                    .replacingOccurrences(of: " ", with: "_")
                    .lowercased()
                if let handle = dlopen(nil, RTLD_NOW),
                   let sym = dlsym(handle, functionName) {
                    typealias FSFunction = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
                    let function = unsafeBitCast(sym, to: FSFunction.self)
                    _ = function(requestContext)
                    if let streamed = streamedResponse(requestContext) {
                        if contextPtr == nil, let ctx = requestContext {
                            aro_context_destroy(ctx)
                        }
                        return streamed
                    }
                    let response = getContextResponse(requestContext, operationId: opId, requestPath: pathWithoutQuery)
                    // Clean up if we created the context
                    if contextPtr == nil, let ctx = requestContext {
                        aro_context_destroy(ctx)
                    }
                    return NativeHTTPResponse(response)
                }

                // Clean up if we created the context but didn't find handler
                if contextPtr == nil, let ctx = requestContext {
                    aro_context_destroy(ctx)
                }

                // Route matched but no handler - return 501 Not Implemented (matches interpreter behavior)
                return NativeHTTPResponse((501, ["Content-Type": "application/json"], "{\"error\":\"Not Implemented\",\"operationId\":\"\(opId)\"}".data(using: .utf8)))
            }

            // Default: Not found
            return NativeHTTPResponse((404, ["Content-Type": "application/json"], "{\"error\":\"Not Found\"}".data(using: .utf8)))
        }
    }

    return nativeHTTPServer?.start() == true ? 0 : -1
}

/// Start native HTTP server with OpenAPI spec (embedded or from file)
/// If port is 0, reads port from OpenAPI spec's server URL
@_cdecl("aro_native_http_server_start_with_openapi")
public func aro_native_http_server_start_with_openapi(_ port: Int32, _ contextPtr: UnsafeMutableRawPointer?) -> Int32 {
    httpServerLock.lock()

    var finalPort = port
    var openapiContent: String? = nil

    // Priority 1: Use embedded spec if available (compiled into binary)
    if let embedded = embeddedOpenAPISpec {
        openapiContent = embedded
    }
    // Priority 2: Fall back to file-based loading from binary's directory
    else {
        let executablePath = CommandLine.arguments[0]
        let binaryDir = (executablePath as NSString).deletingLastPathComponent
        let openapiPath = binaryDir + "/openapi.yaml"
        do {
            openapiContent = try String(contentsOfFile: openapiPath, encoding: .utf8)
        } catch {
            // A missing openapi.yaml is normal (no contract = no routes), but a
            // file that exists yet cannot be read means the server starts with no
            // routes for a non-obvious reason — surface that specific case.
            if FileManager.default.fileExists(atPath: openapiPath) {
                FileHandle.standardError.write(Data("[ServiceBridge] Warning: failed to read \(openapiPath), HTTP routes unavailable: \(error)\n".utf8))
            }
            openapiContent = nil
        }
    }

    // Parse routes and extract port from the spec
    if let content = openapiContent {
        parseOpenAPIRoutes(content)

        if finalPort == 0 {
            finalPort = Int32(extractPortFromOpenAPI(content))
        }
    }

    // Default to 8080 if no port found
    if finalPort == 0 {
        finalPort = 8080
    }

    httpServerLock.unlock()

    return aro_native_http_server_start(finalPort, contextPtr)
}

/// Extract port from OpenAPI spec's server URL (auto-detects YAML or JSON)
private func extractPortFromOpenAPI(_ content: String) -> Int {
    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("{") {
        return extractPortFromOpenAPIJSON(content)
    } else {
        return extractPortFromOpenAPIYAML(content)
    }
}

/// Extract port from OpenAPI YAML spec's server URL
private func extractPortFromOpenAPIYAML(_ yaml: String) -> Int {
    let lines = yaml.components(separatedBy: "\n")

    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Look for "url: http://localhost:PORT" pattern
        if trimmed.hasPrefix("- url:") || trimmed.hasPrefix("url:") {
            let urlPart = trimmed.replacingOccurrences(of: "- url:", with: "")
                .replacingOccurrences(of: "url:", with: "")
                .trimmingCharacters(in: .whitespaces)

            if let port = extractPortFromURL(urlPart) {
                return port
            }
        }
    }

    return 0
}

/// Reused decoder for OpenAPI JSON parsing — only called during binary-mode startup
/// (single-threaded), so shared access is safe.
private let openAPIJSONDecoder = JSONDecoder()

/// Extract port from OpenAPI JSON spec's server URL
private func extractPortFromOpenAPIJSON(_ json: String) -> Int {
    // try? is acceptable: 0 signals "no explicit port", and the caller falls
    // back to the default 8080. A decode failure here does not lose data —
    // parseOpenAPIRoutesJSON separately parses (and logs) the same spec for
    // route registration.
    guard let data = json.data(using: .utf8),
          let spec = try? openAPIJSONDecoder.decode(OpenAPISpec.self, from: data),
          let servers = spec.servers,
          let firstServer = servers.first else {
        return 0
    }

    return extractPortFromURL(firstServer.url) ?? 0
}

/// Extract port number from a URL string
private func extractPortFromURL(_ urlString: String) -> Int? {
    // Extract port from URL like "http://localhost:8000"
    if let colonRange = urlString.range(of: "://") {
        let afterScheme = String(urlString[colonRange.upperBound...])
        // Look for :PORT at the end
        if let lastColon = afterScheme.lastIndex(of: ":") {
            let portString = String(afterScheme[afterScheme.index(after: lastColon)...])
                .components(separatedBy: CharacterSet(charactersIn: "/")).first ?? ""
            return Int(portString)
        }
    }
    return nil
}

/// Match an actual path against an OpenAPI pattern with path parameters
/// Returns extracted path parameters if match succeeds, nil if no match
/// Example: pattern="/users/{id}", actual="/users/123" returns ["id": "123"]
private func matchPath(pattern: String, actual: String) -> [String: String]? {
    let patternParts = pattern.split(separator: "/", omittingEmptySubsequences: false)
    let actualParts = actual.split(separator: "/", omittingEmptySubsequences: false)

    // Must have same number of path segments
    guard patternParts.count == actualParts.count else { return nil }

    var params: [String: String] = [:]

    for (patternPart, actualPart) in zip(patternParts, actualParts) {
        let patternStr = String(patternPart)
        let actualStr = String(actualPart)

        // Check if this is a path parameter like {id}
        if patternStr.hasPrefix("{") && patternStr.hasSuffix("}") {
            // Extract parameter name (remove braces)
            let paramName = String(patternStr.dropFirst().dropLast())
            params[paramName] = actualStr
        } else {
            // Must match exactly
            if patternStr != actualStr {
                return nil
            }
        }
    }

    return params
}

/// Simple OpenAPI route parser (auto-detects YAML or JSON)
private func parseOpenAPIRoutes(_ content: String) {
    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("{") {
        parseOpenAPIRoutesJSON(content)
    } else {
        parseOpenAPIRoutesYAML(content)
    }
}

/// Parse routes from OpenAPI JSON spec
private func parseOpenAPIRoutesJSON(_ json: String) {
    // The content was already detected as JSON (starts with "{"), so a decode
    // failure means the OpenAPI contract is malformed: returning silently would
    // register zero routes and every request would 404 with no explanation.
    guard let data = json.data(using: .utf8),
          let spec = try? openAPIJSONDecoder.decode(OpenAPISpec.self, from: data) else {
        FileHandle.standardError.write(Data("[ServiceBridge] Warning: failed to decode OpenAPI JSON spec, no HTTP routes registered\n".utf8))
        return
    }

    for (path, pathItem) in spec.paths {
        for (method, operation) in pathItem.allOperations {
            if let opId = operation.operationId {
                httpRoutes.append((method: method.uppercased(), path: path, operationId: opId))

                // Extract response content type from 200/201 response
                if let response = operation.responses["200"] ?? operation.responses["201"],
                   let content = response.content,
                   let firstContentType = content.keys.first {
                    httpResponseContentTypes[opId] = firstContentType
                }
            }
        }
    }

    // Top-level webhooks (OpenAPI 3.1): route POST /<name> to the feature set
    // named after the webhook (or its operationId, when present) — GitLab #187.
    for (name, item) in spec.webhooks ?? [:] {
        let path = name.hasPrefix("/") ? name : "/\(name)"
        for (method, operation) in item.allOperations {
            let handlerName = operation.operationId ?? name
            httpRoutes.append((method: method.uppercased(), path: path, operationId: handlerName))

            if let response = operation.responses["200"] ?? operation.responses["201"],
               let content = response.content,
               let firstContentType = content.keys.first {
                httpResponseContentTypes[handlerName] = firstContentType
            }
        }
    }
}

/// Parse routes from OpenAPI YAML spec
private func parseOpenAPIRoutesYAML(_ yaml: String) {
    let lines = yaml.components(separatedBy: "\n")
    var currentPath: String? = nil
    var currentMethod: String? = nil
    var currentOperationId: String? = nil
    var inResponses = false
    var in200Response = false

    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Check for path (reset state when entering new path)
        if line.hasPrefix("  /") && line.contains(":") {
            let pathPart = line.trimmingCharacters(in: .whitespaces)
            if let colonIndex = pathPart.firstIndex(of: ":") {
                currentPath = String(pathPart[..<colonIndex])
                currentMethod = nil
                currentOperationId = nil
                inResponses = false
                in200Response = false
            }
        }
        // Check for method
        else if trimmed.hasPrefix("get:") || trimmed.hasPrefix("post:") ||
                trimmed.hasPrefix("put:") || trimmed.hasPrefix("delete:") ||
                trimmed.hasPrefix("patch:") {
            currentMethod = String(trimmed.dropLast()) // Remove ":"
            currentOperationId = nil
            inResponses = false
            in200Response = false
        }
        // Check for operationId
        else if trimmed.hasPrefix("operationId:") {
            let opId = trimmed.replacingOccurrences(of: "operationId:", with: "")
                .trimmingCharacters(in: .whitespaces)
            currentOperationId = opId

            if let path = currentPath, let method = currentMethod {
                httpRoutes.append((method: method.uppercased(), path: path, operationId: opId))
            }
        }
        // Track responses section
        else if trimmed.hasPrefix("responses:") {
            inResponses = true
            in200Response = false
        }
        // Track 200/201 response
        else if inResponses && (trimmed.hasPrefix("'200':") || trimmed.hasPrefix("\"200\":") ||
                                trimmed.hasPrefix("'201':") || trimmed.hasPrefix("\"201\":")) {
            in200Response = true
        }
        // Look for content type in response content section
        else if in200Response && trimmed.hasPrefix("content:") {
            // Next non-empty line with proper indentation should be the content type
            continue
        }
        // Capture content type (e.g., "text/html:", "application/json:")
        else if in200Response && !trimmed.isEmpty && trimmed.hasSuffix(":") &&
                (trimmed.contains("/")) {
            let contentType = String(trimmed.dropLast()) // Remove ":"
            if let opId = currentOperationId {
                httpResponseContentTypes[opId] = contentType
            }
            in200Response = false // Done with this response
        }
    }
}

/// Stop native HTTP server
@_cdecl("aro_native_http_server_stop")
public func aro_native_http_server_stop() {
    httpServerLock.lock()
    defer { httpServerLock.unlock() }

    nativeHTTPServer?.stop()
    nativeHTTPServer = nil
}

#else  // os(Windows)

// MARK: - Native HTTP Server Stubs (Windows)

/// Start native HTTP server (Windows stub)
@_cdecl("aro_native_http_server_start")
public func aro_native_http_server_start(_ port: Int32, _ contextPtr: UnsafeMutableRawPointer?) -> Int32 {
    print("[NativeHTTPServer] HTTP server not yet supported on Windows")
    return -1
}

/// Start native HTTP server with OpenAPI spec (Windows stub)
@_cdecl("aro_native_http_server_start_with_openapi")
public func aro_native_http_server_start_with_openapi(_ port: Int32, _ contextPtr: UnsafeMutableRawPointer?) -> Int32 {
    print("[NativeHTTPServer] HTTP server not yet supported on Windows")
    return -1
}

/// Stop native HTTP server (Windows stub)
@_cdecl("aro_native_http_server_stop")
public func aro_native_http_server_stop() {
    // No-op on Windows
}

/// Register a route handler (Windows stub)
@_cdecl("aro_http_register_route")
public func aro_http_register_route(
    _ method: UnsafePointer<CChar>?,
    _ path: UnsafePointer<CChar>?,
    _ operationId: UnsafePointer<CChar>?
) {
    // No-op on Windows
}

/// Register a route's body policy (Windows stub, GitLab #477)
@_cdecl("aro_http_set_body_policy")
public func aro_http_set_body_policy(
    _ operationId: UnsafePointer<CChar>?,
    _ streams: Int32,
    _ limit: UnsafePointer<CChar>?
) {
    // No-op on Windows: the FlyingFox path has no streaming body to police,
    // and its cap is applied in WindowsHTTPServer.
}

/// Set the embedded OpenAPI spec (Windows stub)
@_cdecl("aro_set_embedded_openapi")
public func aro_set_embedded_openapi(_ specPtr: UnsafePointer<CChar>?) {
    // No-op on Windows
}

/// Set the embedded templates (Windows stub) - ARO-0050
@_cdecl("aro_set_embedded_templates")
public func aro_set_embedded_templates(_ jsonPtr: UnsafePointer<CChar>?) {
    // No-op on Windows
}

/// Register an embedded plugin library (Windows stub)
@_cdecl("aro_register_embedded_plugin")
public func aro_register_embedded_plugin(
    _ namePtr: UnsafePointer<CChar>?,
    _ yamlPtr: UnsafePointer<CChar>?,
    _ base64Ptr: UnsafePointer<CChar>?
) {
    // No-op on Windows
}

#endif  // !os(Windows)
