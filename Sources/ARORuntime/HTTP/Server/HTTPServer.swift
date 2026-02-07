// ============================================================
// HTTPServer.swift
// ARO Runtime - HTTP Server (SwiftNIO)
// ============================================================

import Foundation

// MARK: - HTTP Types (Available on all platforms)

/// Request handler type for processing HTTP requests
public typealias HTTPRequestHandler = @Sendable (HTTPRequest) async -> HTTPResponse

/// HTTP Request abstraction
public struct HTTPRequest: Sendable {
    public let id: String
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data?
    public let queryParameters: [String: String]

    public init(
        id: String = UUID().uuidString,
        method: String,
        path: String,
        headers: [String: String] = [:],
        body: Data? = nil,
        queryParameters: [String: String] = [:]
    ) {
        self.id = id
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
        self.queryParameters = queryParameters
    }

    /// Parse body as JSON
    public func json<T: Decodable>(_ type: T.Type) throws -> T {
        guard let data = body else {
            throw HTTPError.noBody
        }
        return try JSONDecoder().decode(type, from: data)
    }

    /// Get body as string
    public var bodyString: String? {
        body.flatMap { String(data: $0, encoding: .utf8) }
    }
}

/// HTTP Response abstraction
public struct HTTPResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data?

    public init(
        statusCode: Int = 200,
        headers: [String: String] = [:],
        body: Data? = nil
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    /// Create JSON response
    public static func json<T: Encodable>(_ value: T, status: Int = 200) throws -> HTTPResponse {
        let data = try JSONEncoder().encode(value)
        return HTTPResponse(
            statusCode: status,
            headers: ["Content-Type": "application/json"],
            body: data
        )
    }

    /// Create text response
    public static func text(_ string: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(
            statusCode: status,
            headers: ["Content-Type": "text/plain"],
            body: string.data(using: .utf8)
        )
    }

    /// Common responses
    public static let ok = HTTPResponse(statusCode: 200)
    public static let notFound = HTTPResponse(statusCode: 404)
    public static let badRequest = HTTPResponse(statusCode: 400)
    public static let serverError = HTTPResponse(statusCode: 500)
}

/// HTTP Errors
public enum HTTPError: Error, Sendable {
    case noBody
    case invalidJSON
    case connectionFailed
    case timeout
    case serverError(Int)
    case custom(String)
}

// MARK: - HTTP Server Events (Available on all platforms)

/// Event emitted when HTTP server starts
public struct HTTPServerStartedEvent: RuntimeEvent {
    public static var eventType: String { "http.server.started" }
    public let timestamp: Date
    public let port: Int

    public init(port: Int) {
        self.timestamp = Date()
        self.port = port
    }
}

/// Event emitted when HTTP server stops
public struct HTTPServerStoppedEvent: RuntimeEvent {
    public static var eventType: String { "http.server.stopped" }
    public let timestamp: Date

    public init() {
        self.timestamp = Date()
    }
}

// MARK: - SwiftNIO Implementation (macOS/Linux only)

#if !os(Windows)

import NIO
import NIOHTTP1
import NIOFoundationCompat
import NIOWebSocket

/// HTTP Server implementation using SwiftNIO
///
/// Provides an event-driven HTTP server that integrates with ARO's
/// event system for handling incoming requests.
public final class AROHTTPServer: HTTPServerService, @unchecked Sendable {
    // MARK: - Properties

    private let eventBus: EventBus
    private var channel: Channel?
    private let group: MultiThreadedEventLoopGroup
    private let lock = NSLock()

    /// Request handler for processing requests through feature sets
    private var requestHandler: HTTPRequestHandler?

    /// WebSocket server for handling WebSocket connections
    private var webSocketServer: AROWebSocketServer?

    /// Current port the server is listening on
    public private(set) var port: Int = 0

    /// Whether the server is running
    public var isRunning: Bool {
        withLock { channel != nil }
    }

    // MARK: - Thread-safe helpers

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func setChannel(_ newChannel: Channel?, port: Int? = nil) {
        withLock {
            channel = newChannel
            if let port = port {
                self.port = port
            }
        }
    }

    private func getChannel() -> Channel? {
        withLock { channel }
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

    // MARK: - Request Handler Configuration

    /// Set the request handler for processing incoming HTTP requests
    public func setRequestHandler(_ handler: @escaping HTTPRequestHandler) {
        lock.lock()
        defer { lock.unlock() }
        self.requestHandler = handler
    }

    /// Set the WebSocket server for handling WebSocket upgrades
    public func setWebSocketServer(_ server: AROWebSocketServer) {
        lock.lock()
        defer { lock.unlock() }
        self.webSocketServer = server
        server.enable()
    }

    /// Get the WebSocket server
    public func getWebSocketServer() -> AROWebSocketServer? {
        withLock { webSocketServer }
    }

    // MARK: - HTTPServerService

    public func start(port: Int) async throws {
        let handler = withLock { requestHandler }
        let wsServer = withLock { webSocketServer }

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                // Configure HTTP pipeline with optional WebSocket upgrade support
                if let wsServer = wsServer {
                    // Configure with WebSocket upgrader
                    let upgrader = createWebSocketUpgrader(server: wsServer, path: wsServer.path)
                    let upgradeConfig: NIOHTTPServerUpgradeConfiguration = (
                        upgraders: [upgrader],
                        completionHandler: { _ in }
                    )
                    return channel.pipeline.configureHTTPServerPipeline(
                        withServerUpgrade: upgradeConfig
                    ).flatMap {
                        // Add HTTP handler with a name so we can remove it on WebSocket upgrade
                        channel.pipeline.addHandler(
                            HTTPHandler(eventBus: self.eventBus, requestHandler: handler),
                            name: "AROHTTPHandler"
                        )
                    }
                } else {
                    // Standard HTTP pipeline without WebSocket
                    return channel.pipeline.configureHTTPServerPipeline().flatMap {
                        channel.pipeline.addHandler(
                            HTTPHandler(eventBus: self.eventBus, requestHandler: handler)
                        )
                    }
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)

        let channel = try await bootstrap.bind(host: "0.0.0.0", port: port).get()

        setChannel(channel, port: port)

        eventBus.publish(HTTPServerStartedEvent(port: port))

        if wsServer != nil {
            print("HTTP Server started on port \(port) (WebSocket enabled on \(wsServer!.path))")
        } else {
            print("HTTP Server started on port \(port)")
        }
    }

    public func stop() async throws {
        let ch = getChannel()

        if let channel = ch {
            try await channel.close()

            setChannel(nil)

            eventBus.publish(HTTPServerStoppedEvent())
            print("HTTP Server stopped")
        }
    }
}

// MARK: - HTTP Handler

private final class HTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let eventBus: EventBus
    private let requestHandler: HTTPRequestHandler?
    private var requestHead: HTTPRequestHead?
    private var bodyBuffer: ByteBuffer?
    private var startTime = Date()

    init(eventBus: EventBus, requestHandler: HTTPRequestHandler?) {
        self.eventBus = eventBus
        self.requestHandler = requestHandler
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let reqPart = unwrapInboundIn(data)

        switch reqPart {
        case .head(let head):
            requestHead = head
            bodyBuffer = context.channel.allocator.buffer(capacity: 0)
            startTime = Date()

        case .body(var buffer):
            bodyBuffer?.writeBuffer(&buffer)

        case .end:
            guard let head = requestHead else { return }

            let requestId = UUID().uuidString
            let bodyData = bodyBuffer.flatMap { Data(buffer: $0) }

            // Parse query parameters from URI
            var queryParams: [String: String] = [:]
            if let questionMark = head.uri.firstIndex(of: "?") {
                let queryString = String(head.uri[head.uri.index(after: questionMark)...])
                for pair in queryString.split(separator: "&") {
                    let parts = pair.split(separator: "=", maxSplits: 1)
                    if parts.count == 2 {
                        let key = String(parts[0]).removingPercentEncoding ?? String(parts[0])
                        let value = String(parts[1]).removingPercentEncoding ?? String(parts[1])
                        queryParams[key] = value
                    }
                }
            }

            // Extract path without query string
            let path: String
            if let questionMark = head.uri.firstIndex(of: "?") {
                path = String(head.uri[..<questionMark])
            } else {
                path = head.uri
            }

            // Create HTTP request
            let request = HTTPRequest(
                id: requestId,
                method: head.method.rawValue,
                path: path,
                headers: Dictionary(head.headers.map { ($0.name, $0.value) }) { _, last in last },
                body: bodyData,
                queryParameters: queryParams
            )

            // Emit HTTP request event
            let event = HTTPRequestReceivedEvent(
                requestId: requestId,
                method: request.method,
                path: request.path,
                headers: request.headers,
                body: request.body
            )
            eventBus.publish(event)

            // Handle the request
            if let handler = requestHandler {
                // Use the request handler (async feature set execution)
                let eventLoop = context.eventLoop
                let ctxBox = NIOLoopBound(context, eventLoop: eventLoop)

                Task {
                    let response = await handler(request)
                    eventLoop.execute {
                        self.writeResponse(context: ctxBox.value, response: response, requestId: requestId)
                    }
                }
            } else {
                // No handler - return default response
                let response = createDefaultResponse(for: head, requestId: requestId)
                writeResponse(context: context, response: response, requestId: requestId)
            }

            // Reset for next request
            requestHead = nil
            bodyBuffer = nil
        }
    }

    private func createDefaultResponse(for head: HTTPRequestHead, requestId: String) -> HTTPResponse {
        HTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "application/json", "X-Request-ID": requestId],
            body: """
                {"status":"ok","message":"Request received","requestId":"\(requestId)"}
                """.data(using: .utf8)
        )
    }

    private func writeResponse(context: ChannelHandlerContext, response: HTTPResponse, requestId: String) {
        var headers = HTTPHeaders()
        for (name, value) in response.headers {
            headers.add(name: name, value: value)
        }

        if let body = response.body {
            headers.add(name: "Content-Length", value: String(body.count))
        }

        let head = HTTPResponseHead(
            version: .http1_1,
            status: HTTPResponseStatus(statusCode: response.statusCode),
            headers: headers
        )

        context.write(wrapOutboundOut(.head(head)), promise: nil)

        if let body = response.body {
            var buffer = context.channel.allocator.buffer(capacity: body.count)
            buffer.writeBytes(body)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        }

        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)

        // Emit response sent event
        let duration = Date().timeIntervalSince(startTime) * 1000
        eventBus.publish(HTTPResponseSentEvent(
            requestId: requestId,
            statusCode: response.statusCode,
            durationMs: duration
        ))
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("HTTP Server error: \(error)")
        context.close(promise: nil)
    }
}

#endif  // !os(Windows)
