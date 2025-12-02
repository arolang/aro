// ============================================================
// HTTPServer.swift
// ARO Runtime - HTTP Server (SwiftNIO)
// ============================================================

#if !os(Windows)

import Foundation
import NIO
import NIOHTTP1
import NIOFoundationCompat

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
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
    }

    deinit {
        try? group.syncShutdownGracefully()
    }

    // MARK: - HTTPServerService

    public func start(port: Int) async throws {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(HTTPHandler(eventBus: self.eventBus))
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)

        let channel = try await bootstrap.bind(host: "0.0.0.0", port: port).get()

        setChannel(channel, port: port)

        eventBus.publish(HTTPServerStartedEvent(port: port))

        print("HTTP Server started on port \(port)")
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
    private var requestHead: HTTPRequestHead?
    private var bodyBuffer: ByteBuffer?
    private let startTime = Date()

    init(eventBus: EventBus) {
        self.eventBus = eventBus
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let reqPart = unwrapInboundIn(data)

        switch reqPart {
        case .head(let head):
            requestHead = head
            bodyBuffer = context.channel.allocator.buffer(capacity: 0)

        case .body(var buffer):
            bodyBuffer?.writeBuffer(&buffer)

        case .end:
            guard let head = requestHead else { return }

            let requestId = UUID().uuidString
            let bodyData = bodyBuffer.flatMap { Data(buffer: $0) }

            // Emit HTTP request event
            let event = HTTPRequestReceivedEvent(
                requestId: requestId,
                method: head.method.rawValue,
                path: head.uri,
                headers: Dictionary(head.headers.map { ($0.name, $0.value) }) { _, last in last },
                body: bodyData
            )
            eventBus.publish(event)

            // For now, return a simple response
            // In a full implementation, this would wait for the ARO program to respond
            let response = createResponse(for: head, requestId: requestId)
            writeResponse(context: context, response: response, requestId: requestId)

            // Reset for next request
            requestHead = nil
            bodyBuffer = nil
        }
    }

    private func createResponse(for head: HTTPRequestHead, requestId: String) -> HTTPResponse {
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

// MARK: - HTTP Types

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
}

// MARK: - HTTP Server Events

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

#endif  // !os(Windows)
