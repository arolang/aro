// ============================================================
// HTTPServer.swift
// ARO Runtime - HTTP Server (SwiftNIO)
// ============================================================

import Foundation

// MARK: - HTTP Types (Available on all platforms)

/// Request handler type for processing HTTP requests
public typealias HTTPRequestHandler = @Sendable (HTTPRequest) async -> HTTPResponse

/// Shared JSON coders for the HTTP types. JSONDecoder and JSONEncoder
/// are thread-safe and reusable in modern Foundation; allocating one
/// per request showed up in #315 as wasteful at request rate.
enum HTTPJSON {
    static let decoder = JSONDecoder()
    static let encoder = JSONEncoder()
}

/// HTTP Request abstraction
public struct HTTPRequest: Sendable {
    public let id: String
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data?
    public let queryParameters: [String: String]
    /// The raw query string from the URL (everything after `?`), without percent-decoding.
    /// Empty string when there is no query string.
    /// Used for multi-value parameter deserialization (style/explode).
    public let rawQueryString: String

    /// The body as it arrives, for routes whose feature set only moves it
    /// (GitLab #477). Present exactly when `body` is nil because nothing was
    /// buffered; the two are never both set.
    public let bodyStream: RequestBodyStream?

    public init(
        id: String = UUID().uuidString,
        method: String,
        path: String,
        headers: [String: String] = [:],
        body: Data? = nil,
        queryParameters: [String: String] = [:],
        rawQueryString: String = "",
        bodyStream: RequestBodyStream? = nil
    ) {
        self.id = id
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
        self.queryParameters = queryParameters
        self.rawQueryString = rawQueryString
        self.bodyStream = bodyStream
    }

    /// Parse body as JSON
    public func json<T: Decodable>(_ type: T.Type) throws -> T {
        guard let data = body else {
            throw HTTPError.noBody
        }
        return try HTTPJSON.decoder.decode(type, from: data)
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

    /// A body written as it is produced, instead of built in memory first
    /// (GitLab #477). Sent with chunked transfer encoding and no
    /// `Content-Length`, since the length isn't known when the head goes out.
    /// Set exactly when `body` is nil.
    public let bodyStream: AROStream<Data>?

    public init(
        statusCode: Int = 200,
        headers: [String: String] = [:],
        body: Data? = nil,
        bodyStream: AROStream<Data>? = nil
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.bodyStream = bodyStream
    }

    /// Create JSON response
    public static func json<T: Encodable>(_ value: T, status: Int = 200) throws -> HTTPResponse {
        let data = try HTTPJSON.encoder.encode(value)
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

@preconcurrency import NIO
@preconcurrency import NIOHTTP1
@preconcurrency import NIOFoundationCompat
@preconcurrency import NIOWebSocket

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

    /// Resolves each route's body policy at the request head (GitLab #477).
    /// Installed by `Application` from the contract and the materialization
    /// analysis; absent when the server runs without a contract, in which case
    /// every route gets the bounded default.
    private var bodyPolicyResolver: BodyPolicyResolver?

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

    /// Set the per-route body policy resolver (GitLab #477).
    public func setBodyPolicyResolver(_ resolver: @escaping BodyPolicyResolver) {
        lock.lock()
        defer { lock.unlock() }
        self.bodyPolicyResolver = resolver
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

    public func configureWebSocket(path: String) async throws {
        let wsServer = AROWebSocketServer(path: path, eventBus: eventBus)
        setWebSocketServer(wsServer)
    }

    public func start(port: Int) async throws {
        let handler = withLock { requestHandler }
        let wsServer = withLock { webSocketServer }
        // Read per connection rather than capturing once: a resolver installed
        // after `start` still applies, and the lock stays off the request path.
        let policyResolver: BodyPolicyResolver = { [weak self] method, path in
            guard let self else { return .default }
            return self.withLock { self.bodyPolicyResolver }?(method, path) ?? .default
        }

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                // Configure HTTP pipeline with optional WebSocket upgrade support
                if let wsServer = wsServer {
                    // Configure with WebSocket upgrader
                    let upgrader = createWebSocketUpgrader(server: wsServer, path: wsServer.path)
                    return channel.pipeline.configureHTTPServerPipeline(
                        withServerUpgrade: (upgraders: [upgrader], completionHandler: { _ in })
                    ).flatMap {
                        // Add HTTP handler with a name so we can remove it on WebSocket upgrade
                        channel.pipeline.addHandler(
                            HTTPHandler(
                                eventBus: self.eventBus,
                                requestHandler: handler,
                                bodyPolicyResolver: policyResolver
                            ),
                            name: "AROHTTPHandler"
                        )
                    }
                } else {
                    // Standard HTTP pipeline without WebSocket
                    return channel.pipeline.configureHTTPServerPipeline().flatMap {
                        channel.pipeline.addHandler(
                            HTTPHandler(
                                eventBus: self.eventBus,
                                requestHandler: handler,
                                bodyPolicyResolver: policyResolver
                            )
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

private final class HTTPHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let eventBus: EventBus
    private let requestHandler: HTTPRequestHandler?
    private let bodyPolicyResolver: BodyPolicyResolver
    private var requestHead: HTTPRequestHead?
    private var bodyBuffer: ByteBuffer?
    private var startTime = Date()

    // MARK: - Body policy state (GitLab #477)

    /// The policy for the request currently being read.
    private var policy: BodyPolicy = .default
    /// Bytes of this request's body seen so far, checked before each append so
    /// the memory over the limit is never allocated.
    private var bodyBytesSeen = 0
    /// Set once a request has been answered with 413; every remaining part of
    /// it is dropped rather than buffered.
    private var rejected = false

    // MARK: - Streaming body state

    /// Hand-off to the feature set for a streamed route. `send` suspends when
    /// full, which is where backpressure comes from.
    private var bodyChannel: BoundedChannel<Data>?
    /// Chunks NIO has delivered that are not yet in the channel. Bounded by
    /// how many messages one read may produce, because we stop asking for more
    /// while it is non-empty.
    private var pendingChunks: [Data] = []
    private var isSending = false
    /// The feature set finished without draining the body: keep reading the
    /// wire so the connection stays usable, and throw the bytes away.
    private var discardBody = false
    private var endSeen = false
    private var finishRequested = false
    /// The response, held until `.end` so a handler that returns early cannot
    /// answer before the request has finished arriving.
    private var streamedResponse: HTTPResponse?
    private var streamingRequestId: String?
    /// Set once a streamed response has begun writing, so `.end` does not
    /// write a second one.
    private var responseWritten = false
    private var autoReadDisabled = false

    init(
        eventBus: EventBus,
        requestHandler: HTTPRequestHandler?,
        bodyPolicyResolver: @escaping BodyPolicyResolver = { _, _ in .default }
    ) {
        self.eventBus = eventBus
        self.requestHandler = requestHandler
        self.bodyPolicyResolver = bodyPolicyResolver
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let reqPart = unwrapInboundIn(data)

        switch reqPart {
        case .head(let head):
            beginRequest(context: context, head: head)

        case .body(var buffer):
            guard !rejected else { return }
            let byteCount = buffer.readableBytes
            bodyBytesSeen += byteCount

            // Checked *before* the append: the point is that the bytes over the
            // limit never occupy memory, not that they are noticed afterwards.
            if let limit = policy.limit, bodyBytesSeen > limit {
                rejectOversizedBody(context: context, limit: limit, observed: nil)
                return
            }

            switch policy.mode {
            case .buffered:
                bodyBuffer?.writeBuffer(&buffer)
            case .streamed:
                if discardBody {
                    requestMoreBodyIfNeeded(context: context)
                    return
                }
                if let chunk = buffer.readData(length: byteCount) {
                    pendingChunks.append(chunk)
                    pumpBody(context: context)
                }
                requestMoreBodyIfNeeded(context: context)
            }

        case .end:
            guard !rejected else {
                resetRequestState(context: context)
                return
            }

            switch policy.mode {
            case .buffered:
                finishBufferedRequest(context: context)
            case .streamed:
                endSeen = true
                finishRequested = true
                finishBodyChannelIfDrained()
                restoreAutoRead(context: context)
                if responseWritten {
                    // A streamed response is already on the wire and ends
                    // itself when the body stream does.
                    MetricsCollector.shared.recordBodyStreamed(bytes: bodyBytesSeen)
                    requestHead = nil
                } else if let response = streamedResponse, let requestId = streamingRequestId {
                    MetricsCollector.shared.recordBodyStreamed(bytes: bodyBytesSeen)
                    writeResponse(context: context, response: response, requestId: requestId)
                    resetRequestState(context: context)
                }
            }
        }
    }

    // MARK: - Request head

    private func beginRequest(context: ChannelHandlerContext, head: HTTPRequestHead) {
        requestHead = head
        startTime = Date()
        rejected = false
        bodyBytesSeen = 0
        endSeen = false
        discardBody = false
        finishRequested = false
        streamedResponse = nil
        streamingRequestId = nil
        responseWritten = false
        pendingChunks.removeAll()
        isSending = false
        bodyChannel = nil
        bodyBuffer = nil

        let path = Self.pathWithoutQuery(head.uri)
        policy = bodyPolicyResolver(head.method.rawValue, path)

        // A declared length over the limit is refused here, before a body byte
        // is read. With `Expect: 100-continue` the client is still waiting for
        // permission, so it never sends the body at all.
        if let limit = policy.limit,
           let declared = head.headers.first(name: "content-length").flatMap({ Int($0) }),
           declared > limit {
            rejectOversizedBody(context: context, limit: limit, observed: declared)
            return
        }

        switch policy.mode {
        case .buffered:
            bodyBuffer = context.channel.allocator.buffer(capacity: 0)
        case .streamed:
            beginStreamedRequest(context: context, head: head, path: path)
        }
    }

    /// Answer 413 and close. Closing rather than draining is deliberate: the
    /// client is mid-body, and there is no safe point to resume the connection.
    private func rejectOversizedBody(context: ChannelHandlerContext, limit: Int, observed: Int?) {
        rejected = true
        let head = requestHead
        let method = head?.method.rawValue ?? "?"
        let path = head.map { Self.pathWithoutQuery($0.uri) } ?? "?"
        let size = observed.map { "it is \(ByteSize.describe($0))" } ?? "it is larger"
        let message = "Cannot read the request body for \(method) \(path): "
            + "\(size), above this route's \(ByteSize.describe(limit)) limit. "
            + "Raise x-aro-max-body for this operation, or stream the body instead of reading it."

        MetricsCollector.shared.recordBodyRejected(method: method, path: path)

        let payload = "{\"error\":\"\(message.replacingOccurrences(of: "\"", with: "\\\""))\"}"
        let response = HTTPResponse(
            statusCode: 413,
            headers: ["Content-Type": "application/json", "Connection": "close"],
            body: payload.data(using: .utf8)
        )
        writeResponse(
            context: context,
            response: response,
            requestId: UUID().uuidString,
            closeAfterWrite: true
        )

        requestHead = nil
        bodyBuffer = nil
        bodyChannel = nil
        pendingChunks.removeAll()
        restoreAutoRead(context: context)
    }

    // MARK: - Buffered path

    private func finishBufferedRequest(context: ChannelHandlerContext) {
        guard let head = requestHead else { return }

        let requestId = UUID().uuidString
        let bodyData = bodyBuffer.flatMap { Data(buffer: $0) }
        if let bodyData, !bodyData.isEmpty {
            MetricsCollector.shared.recordBodyMaterialized(bytes: bodyData.count)
        }

        let (path, queryParams, rawQueryString) = Self.parseURI(head.uri)

        let request = HTTPRequest(
            id: requestId,
            method: head.method.rawValue,
            path: path,
            headers: Dictionary(head.headers.map { ($0.name, $0.value) }) { _, last in last },
            body: bodyData,
            queryParameters: queryParams,
            rawQueryString: rawQueryString
        )

        eventBus.publish(HTTPRequestReceivedEvent(
            requestId: requestId,
            method: request.method,
            path: request.path,
            headers: request.headers,
            body: request.body
        ))

        if let handler = requestHandler {
            let eventLoop = context.eventLoop
            let ctxBox = NIOLoopBound(context, eventLoop: eventLoop)

            Task {
                let response = await handler(request)
                eventLoop.execute {
                    self.writeResponse(context: ctxBox.value, response: response, requestId: requestId)
                }
            }
        } else {
            let response = createDefaultResponse(for: head, requestId: requestId)
            writeResponse(context: context, response: response, requestId: requestId)
        }

        requestHead = nil
        bodyBuffer = nil
    }

    // MARK: - Streamed path

    private func beginStreamedRequest(
        context: ChannelHandlerContext,
        head: HTTPRequestHead,
        path: String
    ) {
        guard let handler = requestHandler else {
            // Nothing consumes a stream without a handler; fall back to the
            // bounded buffer rather than leaving the body unbounded.
            policy = .default
            bodyBuffer = context.channel.allocator.buffer(capacity: 0)
            return
        }

        let channel = BoundedChannel<Data>(
            capacity: max(1, RuntimeDefaults.streamPrefetchCapacity),
            label: "http-body"
        )
        bodyChannel = channel

        let requestId = UUID().uuidString
        streamingRequestId = requestId

        // Backpressure. NIO reads as fast as the client writes while autoRead
        // is on, which would buffer the difference in `pendingChunks` and undo
        // the point of streaming. Restored at `.end`.
        _ = context.channel.setOption(ChannelOptions.autoRead, value: false)
        autoReadDisabled = true

        let chunks = AROStream<Data> {
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

        let (_, queryParams, rawQueryString) = Self.parseURI(head.uri)
        let declaredLength = head.headers.first(name: "content-length").flatMap { Int($0) }

        let request = HTTPRequest(
            id: requestId,
            method: head.method.rawValue,
            path: path,
            headers: Dictionary(head.headers.map { ($0.name, $0.value) }) { _, last in last },
            body: nil,
            queryParameters: queryParams,
            rawQueryString: rawQueryString,
            bodyStream: RequestBodyStream(
                chunks: chunks,
                declaredLength: declaredLength,
                limit: policy.materializationLimit
            )
        )

        eventBus.publish(HTTPRequestReceivedEvent(
            requestId: requestId,
            method: request.method,
            path: request.path,
            headers: request.headers,
            body: nil
        ))

        let eventLoop = context.eventLoop
        let ctxBox = NIOLoopBound(context, eventLoop: eventLoop)
        Task {
            let response = await handler(request)
            eventLoop.execute {
                self.handlerFinished(context: ctxBox.value, response: response, requestId: requestId)
            }
        }

        context.read()
    }

    /// Move one chunk at a time into the channel. One in flight, in order —
    /// concurrent sends would deliver the body scrambled.
    private func pumpBody(context: ChannelHandlerContext) {
        guard let channel = bodyChannel, !isSending, !pendingChunks.isEmpty else {
            finishBodyChannelIfDrained()
            return
        }
        isSending = true
        let chunk = pendingChunks.removeFirst()
        let eventLoop = context.eventLoop
        let ctxBox = NIOLoopBound(context, eventLoop: eventLoop)
        Task {
            await channel.send(chunk)
            eventLoop.execute {
                self.isSending = false
                self.pumpBody(context: ctxBox.value)
                self.requestMoreBodyIfNeeded(context: ctxBox.value)
            }
        }
    }

    private func finishBodyChannelIfDrained() {
        guard finishRequested, !isSending, pendingChunks.isEmpty, let channel = bodyChannel else { return }
        bodyChannel = nil
        Task { await channel.finish() }
    }

    /// Ask for more only when the hand-off is not backed up. This is the read
    /// side of the same backpressure: while the consumer is behind, the socket
    /// buffer fills and the client is throttled by TCP.
    private func requestMoreBodyIfNeeded(context: ChannelHandlerContext) {
        guard autoReadDisabled, !endSeen, !rejected else { return }
        if discardBody || pendingChunks.isEmpty {
            context.read()
        }
    }

    private func handlerFinished(
        context: ChannelHandlerContext,
        response: HTTPResponse,
        requestId: String
    ) {
        guard streamingRequestId == requestId else { return }
        streamedResponse = response

        // The response *is* the request body — an echo or a proxy. The body is
        // still arriving, so it must keep flowing: writing starts now and each
        // chunk goes back out as it lands, rather than waiting for a `.end`
        // that would then have nothing left to send.
        if response.bodyStream != nil {
            responseWritten = true
            writeResponse(context: context, response: response, requestId: requestId)
            requestMoreBodyIfNeeded(context: context)
            return
        }

        // Whatever the feature set did or didn't read, it is done with the
        // body now: release the producer and drop the rest.
        discardBody = true
        pendingChunks.removeAll()
        finishRequested = true
        if let channel = bodyChannel {
            bodyChannel = nil
            Task { await channel.finish() }
        }

        if endSeen {
            MetricsCollector.shared.recordBodyStreamed(bytes: bodyBytesSeen)
            writeResponse(context: context, response: response, requestId: requestId)
            resetRequestState(context: context)
        } else {
            // Keep draining until the request has finished arriving, so the
            // response cannot overtake the request on a keep-alive connection.
            requestMoreBodyIfNeeded(context: context)
        }
    }

    private func restoreAutoRead(context: ChannelHandlerContext) {
        guard autoReadDisabled else { return }
        autoReadDisabled = false
        _ = context.channel.setOption(ChannelOptions.autoRead, value: true)
        context.read()
    }

    private func resetRequestState(context: ChannelHandlerContext) {
        requestHead = nil
        bodyBuffer = nil
        bodyChannel = nil
        pendingChunks.removeAll()
        streamedResponse = nil
        streamingRequestId = nil
        responseWritten = false
        restoreAutoRead(context: context)
    }

    // MARK: - URI helpers

    private static func pathWithoutQuery(_ uri: String) -> String {
        if let questionMark = uri.firstIndex(of: "?") {
            return String(uri[..<questionMark])
        }
        return uri
    }

    private static func parseURI(_ uri: String) -> (path: String, query: [String: String], raw: String) {
        var queryParams: [String: String] = [:]
        var rawQueryString = ""
        if let questionMark = uri.firstIndex(of: "?") {
            rawQueryString = String(uri[uri.index(after: questionMark)...])
            for pair in rawQueryString.split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    let key = decodeQueryComponent(String(parts[0]))
                    let value = decodeQueryComponent(String(parts[1]))
                    queryParams[key] = value
                }
            }
        }
        return (pathWithoutQuery(uri), queryParams, rawQueryString)
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

    private func writeResponse(
        context: ChannelHandlerContext,
        response: HTTPResponse,
        requestId: String,
        closeAfterWrite: Bool = false
    ) {
        var headers = HTTPHeaders()
        for (name, value) in response.headers {
            headers.add(name: name, value: value)
        }

        if let body = response.body {
            headers.add(name: "Content-Length", value: String(body.count))
        }
        // A streamed body has no length to declare. Leaving both framing
        // headers off makes NIO chunk it, which is the only correct framing
        // for a body whose size is not known when the head goes out.

        let head = HTTPResponseHead(
            version: .http1_1,
            status: HTTPResponseStatus(statusCode: response.statusCode),
            headers: headers
        )

        context.write(wrapOutboundOut(.head(head)), promise: nil)

        if let bodyStream = response.bodyStream {
            writeStreamedBody(context: context, stream: bodyStream, requestId: requestId, closeAfterWrite: closeAfterWrite)
            return
        }

        if let body = response.body {
            var buffer = context.channel.allocator.buffer(capacity: body.count)
            buffer.writeBytes(body)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        }

        let endPromise = context.eventLoop.makePromise(of: Void.self)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: endPromise)
        if closeAfterWrite {
            let ctxBox = NIOLoopBound(context, eventLoop: context.eventLoop)
            endPromise.futureResult.whenComplete { _ in ctxBox.value.close(promise: nil) }
        }

        // Emit response sent event
        let duration = Date().timeIntervalSince(startTime) * 1000
        eventBus.publish(HTTPResponseSentEvent(
            requestId: requestId,
            statusCode: response.statusCode,
            durationMs: duration
        ))
    }

    /// Write a response body chunk by chunk (GitLab #477). Each chunk is
    /// flushed as it is produced, so a large download costs one chunk of
    /// memory rather than its whole size.
    private func writeStreamedBody(
        context: ChannelHandlerContext,
        stream: AROStream<Data>,
        requestId: String,
        closeAfterWrite: Bool
    ) {
        let eventLoop = context.eventLoop
        let ctxBox = NIOLoopBound(context, eventLoop: eventLoop)
        let startedAt = startTime

        Task { [eventBus] in
            var bytes = 0
            do {
                for try await chunk in stream.stream {
                    bytes += chunk.count
                    let payload = chunk
                    try await eventLoop.submit {
                        let ctx = ctxBox.value
                        var buffer = ctx.channel.allocator.buffer(capacity: payload.count)
                        buffer.writeBytes(payload)
                        ctx.writeAndFlush(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                    }.get()
                }
            } catch {
                // The head is already on the wire, so there is no status left
                // to change. Close, which is what a truncated chunked response
                // looks like to the client.
                eventLoop.execute { ctxBox.value.close(promise: nil) }
                return
            }

            let sent = bytes
            eventLoop.execute {
                let ctx = ctxBox.value
                let endPromise = eventLoop.makePromise(of: Void.self)
                ctx.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: endPromise)
                if closeAfterWrite {
                    endPromise.futureResult.whenComplete { _ in ctxBox.value.close(promise: nil) }
                }
                MetricsCollector.shared.recordResponseStreamed(bytes: sent)
                let duration = Date().timeIntervalSince(startedAt) * 1000
                eventBus.publish(HTTPResponseSentEvent(
                    requestId: requestId,
                    statusCode: 200,
                    durationMs: duration
                ))
            }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("HTTP Server error: \(error)")
        context.close(promise: nil)
    }
}

#endif  // !os(Windows)
