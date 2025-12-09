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

/// HTTP Client implementation using AsyncHTTPClient
///
/// Provides HTTP client functionality for making outgoing requests
/// from ARO feature sets.
public final class AROHTTPClient: HTTPClientService, @unchecked Sendable {
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
            request.headers.add(name: name, value: value)
        }

        if let body = body {
            request.body = .bytes(ByteBuffer(data: body))
        }

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
        } catch {
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
