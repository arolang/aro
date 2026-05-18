// ============================================================
// HTTPClient.swift
// ARO Runtime - HTTP Client (AsyncHTTPClient)
// ============================================================

import Foundation

#if !os(Windows)
import AsyncHTTPClient
import NIO
import NIOHTTP1
import NIOFoundationCompat

/// Bounded async semaphore — actor-based, no busy-wait.
/// Acquire suspends until a slot is free; release hands the slot to the next
/// waiting acquirer if any, otherwise decrements the in-flight count.
fileprivate actor HTTPConcurrencyLimiter {
    private let limit: Int
    private var inFlight: Int = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func acquire() async {
        if inFlight < limit {
            inFlight += 1
            return
        }
        await withCheckedContinuation { cont in
            waiters.append(cont)
        }
        // On resume the slot has been transferred from the releaser; inFlight
        // stays at `limit` rather than dipping and re-incrementing.
    }

    func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            inFlight = max(0, inFlight - 1)
        }
    }
}

/// HTTP Client implementation using AsyncHTTPClient
///
/// Provides HTTP client functionality for making outgoing requests
/// from ARO feature sets.
public final class AROHTTPClient: HTTPClientService, @unchecked Sendable {
    /// Process-wide cap on concurrent HTTP fetches. Bounds the number of
    /// response bodies in memory during a burst (crawlers, fan-out emitters).
    /// Override with the `ARO_HTTP_CONCURRENCY` environment variable.
    private static let sharedLimiter: HTTPConcurrencyLimiter = {
        let env = ProcessInfo.processInfo.environment["ARO_HTTP_CONCURRENCY"]
        let limit = env.flatMap(Int.init) ?? 8
        return HTTPConcurrencyLimiter(limit: limit)
    }()
    // MARK: - Properties

    private let client: HTTPClient
    private let eventBus: EventBus
    private let timeout: TimeAmount

    // MARK: - Initialization

    public init(
        eventBus: EventBus = .shared,
        timeout: TimeAmount = .seconds(30)
    ) {
        self.client = HTTPClient(eventLoopGroupProvider: .singleton)
        self.eventBus = eventBus
        self.timeout = timeout
    }

    deinit {
        try? client.syncShutdown()
    }

    // MARK: - HTTPClientService

    public func get(url: String) async throws -> any Sendable {
        try await request(method: .GET, url: url, body: nil)
    }

    public func post(url: String, body: any Sendable) async throws -> any Sendable {
        let bodyData: Data
        if let data = body as? Data {
            bodyData = data
        } else if let string = body as? String {
            bodyData = string.data(using: .utf8) ?? Data()
        } else {
            bodyData = try JSONSerialization.data(withJSONObject: body)
        }
        return try await request(method: .POST, url: url, body: bodyData)
    }

    // MARK: - Extended API

    /// Perform a GET request
    public func get(url: String, headers: [String: String] = [:]) async throws -> HTTPClientResponse {
        try await performRequest(
            method: .GET,
            url: url,
            headers: headers,
            body: nil
        )
    }

    /// Perform a POST request
    public func post(
        url: String,
        headers: [String: String] = [:],
        body: Data?
    ) async throws -> HTTPClientResponse {
        try await performRequest(
            method: .POST,
            url: url,
            headers: headers,
            body: body
        )
    }

    /// Perform a PUT request
    public func put(
        url: String,
        headers: [String: String] = [:],
        body: Data?
    ) async throws -> HTTPClientResponse {
        try await performRequest(
            method: .PUT,
            url: url,
            headers: headers,
            body: body
        )
    }

    /// Perform a DELETE request
    public func delete(
        url: String,
        headers: [String: String] = [:]
    ) async throws -> HTTPClientResponse {
        try await performRequest(
            method: .DELETE,
            url: url,
            headers: headers,
            body: nil
        )
    }

    /// Perform a PATCH request
    public func patch(
        url: String,
        headers: [String: String] = [:],
        body: Data?
    ) async throws -> HTTPClientResponse {
        try await performRequest(
            method: .PATCH,
            url: url,
            headers: headers,
            body: body
        )
    }

    // MARK: - Private

    private func request(method: HTTPMethod, url: String, body: Data?) async throws -> any Sendable {
        let response = try await performRequest(method: method, url: url, headers: [:], body: body)
        return response.bodyString ?? ""
    }

    private func performRequest(
        method: HTTPMethod,
        url: String,
        headers: [String: String],
        body: Data?
    ) async throws -> HTTPClientResponse {
        let startTime = Date()

        var request = HTTPClientRequest(url: url)
        request.method = method

        for (name, value) in headers {
            request.headers.add(name: name, value: value.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        if let body = body {
            request.body = .bytes(ByteBuffer(data: body))
        }

        // Gate concurrent HTTP fetches across the entire process. The slot is
        // held only for the fetch + body collection — once we return the
        // buffered response, downstream parsing/handlers don't keep it.
        await Self.sharedLimiter.acquire()
        let response: HTTPClientResponse
        do {
            let httpResponse = try await client.execute(request, timeout: timeout)

            var bodyBuffer = try await httpResponse.body.collect(upTo: 10 * 1024 * 1024)
            let bodyData = bodyBuffer.readData(length: bodyBuffer.readableBytes)

            response = HTTPClientResponse(
                statusCode: Int(httpResponse.status.code),
                headers: Dictionary(httpResponse.headers.map { ($0.name, $0.value) }) { _, last in last },
                body: bodyData
            )
            await Self.sharedLimiter.release()
        } catch {
            await Self.sharedLimiter.release()
            eventBus.publish(HTTPClientErrorEvent(url: url, error: error.localizedDescription))
            throw HTTPError.connectionFailed
        }

        let duration = Date().timeIntervalSince(startTime) * 1000
        eventBus.publish(HTTPClientRequestCompletedEvent(
            url: url,
            method: method.rawValue,
            statusCode: response.statusCode,
            durationMs: duration
        ))

        return response
    }
}

#endif  // !os(Windows)

// MARK: - HTTP Client Response
// These types are available on all platforms (including Windows)
// so that URLSessionHTTPClient can use them

/// Response from HTTP client request
public struct HTTPClientResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data?

    public init(statusCode: Int, headers: [String: String] = [:], body: Data? = nil) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    /// Check if response is successful (2xx)
    public var isSuccess: Bool {
        (200..<300).contains(statusCode)
    }

    /// Get body as string
    public var bodyString: String? {
        body.flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Parse body as JSON
    public func json<T: Decodable>(_ type: T.Type) throws -> T {
        guard let data = body else {
            throw HTTPError.noBody
        }
        return try JSONDecoder().decode(type, from: data)
    }

    /// Parse body as JSON dictionary
    public func jsonDictionary() throws -> [String: Any] {
        guard let data = body else {
            throw HTTPError.noBody
        }
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HTTPError.invalidJSON
        }
        return dict
    }
}

// MARK: - HTTP Client Events

/// Event emitted when HTTP client request completes
public struct HTTPClientRequestCompletedEvent: RuntimeEvent {
    public static var eventType: String { "http.client.completed" }
    public let timestamp: Date
    public let url: String
    public let method: String
    public let statusCode: Int
    public let durationMs: Double

    public init(url: String, method: String, statusCode: Int, durationMs: Double) {
        self.timestamp = Date()
        self.url = url
        self.method = method
        self.statusCode = statusCode
        self.durationMs = durationMs
    }
}

/// Event emitted when HTTP client request fails
public struct HTTPClientErrorEvent: RuntimeEvent {
    public static var eventType: String { "http.client.error" }
    public let timestamp: Date
    public let url: String
    public let error: String

    public init(url: String, error: String) {
        self.timestamp = Date()
        self.url = url
        self.error = error
    }
}
