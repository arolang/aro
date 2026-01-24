// ============================================================
// WindowsHTTPServer.swift
// ARO Runtime - HTTP Server for Windows (FlyingFox)
// ============================================================
//
// Windows-specific HTTP server implementation using FlyingFox.
// FlyingFox uses BSD sockets with Swift Concurrency, providing
// experimental Windows support via a polling-based socket pool.

#if os(Windows)

import Foundation
import FlyingFox

/// HTTP Server implementation for Windows using FlyingFox
///
/// Provides HTTP server functionality on Windows platform where
/// SwiftNIO is not available.
public final class WindowsHTTPServer: HTTPServerService, @unchecked Sendable {
    // MARK: - Properties

    private let eventBus: EventBus
    private var server: HTTPServer?
    private var serverTask: Task<Void, Error>?
    private let lock = NSLock()

    /// Request handler for processing requests through feature sets
    private var requestHandler: HTTPRequestHandler?

    /// Current port the server is listening on
    public private(set) var port: Int = 0

    /// Whether the server is running
    public var isRunning: Bool {
        withLock { server != nil }
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

    // MARK: - Request Handler Configuration

    /// Set the request handler for processing incoming HTTP requests
    public func setRequestHandler(_ handler: @escaping HTTPRequestHandler) {
        lock.lock()
        defer { lock.unlock() }
        self.requestHandler = handler
    }

    // MARK: - HTTPServerService

    public func start(port: Int) async throws {
        let handler = withLock { requestHandler }

        // Create FlyingFox server
        let foxServer = HTTPServer(port: UInt16(port))

        // Configure catch-all route handler
        await foxServer.appendRoute("*") { [weak self] foxRequest in
            guard let self = self else {
                return FlyingFox.HTTPResponse(statusCode: .internalServerError)
            }
            return await self.handleRequest(foxRequest, with: handler)
        }

        // Store server reference
        lock.lock()
        self.server = foxServer
        self.port = port
        lock.unlock()

        // Start the server in a task
        serverTask = Task {
            try await foxServer.run()
        }

        // Wait briefly for server to start
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms

        eventBus.publish(HTTPServerStartedEvent(port: port))

        print("HTTP Server started on port \(port) (Windows/FlyingFox)")
    }

    public func stop() async throws {
        lock.lock()
        let foxServer = server
        let task = serverTask
        server = nil
        serverTask = nil
        lock.unlock()

        if let foxServer = foxServer {
            await foxServer.stop()
            task?.cancel()

            eventBus.publish(HTTPServerStoppedEvent())
            print("HTTP Server stopped (Windows/FlyingFox)")
        }
    }

    // MARK: - Request Handling

    private func handleRequest(
        _ foxRequest: FlyingFox.HTTPRequest,
        with handler: HTTPRequestHandler?
    ) async -> FlyingFox.HTTPResponse {
        let requestId = UUID().uuidString

        // Parse query parameters from path
        var queryParams: [String: String] = [:]
        var path = foxRequest.path
        if let questionMark = path.firstIndex(of: "?") {
            let queryString = String(path[path.index(after: questionMark)...])
            path = String(path[..<questionMark])
            for pair in queryString.split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    let key = String(parts[0]).removingPercentEncoding ?? String(parts[0])
                    let value = String(parts[1]).removingPercentEncoding ?? String(parts[1])
                    queryParams[key] = value
                }
            }
        }

        // Convert FlyingFox headers to dictionary
        var headers: [String: String] = [:]
        for header in foxRequest.headers {
            headers[header.name] = header.value
        }

        // Create ARO request
        let aroRequest = HTTPRequest(
            id: requestId,
            method: foxRequest.method.rawValue,
            path: path,
            headers: headers,
            body: foxRequest.body,
            queryParameters: queryParams
        )

        // Emit request received event
        eventBus.publish(HTTPRequestReceivedEvent(
            requestId: requestId,
            method: aroRequest.method,
            path: aroRequest.path,
            headers: aroRequest.headers,
            body: aroRequest.body
        ))

        // Handle the request
        let aroResponse: HTTPResponse
        if let handler = handler {
            aroResponse = await handler(aroRequest)
        } else {
            aroResponse = HTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json", "X-Request-ID": requestId],
                body: """
                    {"status":"ok","message":"Request received","requestId":"\(requestId)"}
                    """.data(using: .utf8)
            )
        }

        // Emit response sent event
        eventBus.publish(HTTPResponseSentEvent(
            requestId: requestId,
            statusCode: aroResponse.statusCode,
            durationMs: 0 // TODO: Track duration
        ))

        // Convert ARO response to FlyingFox response
        var foxHeaders: [FlyingFox.HTTPHeader] = []
        for (name, value) in aroResponse.headers {
            foxHeaders.append(FlyingFox.HTTPHeader(name: name, value: value))
        }

        return FlyingFox.HTTPResponse(
            statusCode: HTTPStatusCode(UInt16(aroResponse.statusCode)),
            headers: foxHeaders,
            body: aroResponse.body ?? Data()
        )
    }
}

#endif  // os(Windows)
