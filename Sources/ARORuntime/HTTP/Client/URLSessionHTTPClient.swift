// ============================================================
// URLSessionHTTPClient.swift
// ARORuntime - URLSession-based HTTP Client
// ============================================================
//
// Alternative HTTP client implementation using URLSession.
// This is more compatible with sync-to-async bridging in compiled
// binaries where NIO event loops may not be properly available.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// URLSession-based HTTP Client
///
/// Provides HTTP client functionality using Foundation's URLSession,
/// which is more compatible with compiled binaries that use sync-to-async
/// bridging via semaphores.
public final class URLSessionHTTPClient: HTTPClientService, @unchecked Sendable {
    // MARK: - Properties

    private let session: URLSession
    private let eventBus: EventBus
    private let timeout: TimeInterval

    // MARK: - Initialization

    public init(
        eventBus: EventBus = .shared,
        timeout: TimeInterval = 30.0
    ) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 2
        self.session = URLSession(configuration: config)
        self.eventBus = eventBus
        self.timeout = timeout
    }

    // MARK: - HTTPClientService

    public func get(url: String) async throws -> any Sendable {
        let response = try await performRequest(method: "GET", url: url, headers: [:], body: nil)
        return response.bodyString ?? ""
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
        let response = try await performRequest(method: "POST", url: url, headers: [:], body: bodyData)
        return response.bodyString ?? ""
    }

    // MARK: - Extended API

    /// Perform a GET request
    public func get(url: String, headers: [String: String] = [:]) async throws -> HTTPClientResponse {
        try await performRequest(method: "GET", url: url, headers: headers, body: nil)
    }

    /// Perform a POST request
    public func post(
        url: String,
        headers: [String: String] = [:],
        body: Data?
    ) async throws -> HTTPClientResponse {
        try await performRequest(method: "POST", url: url, headers: headers, body: body)
    }

    /// Perform a PUT request
    public func put(
        url: String,
        headers: [String: String] = [:],
        body: Data?
    ) async throws -> HTTPClientResponse {
        try await performRequest(method: "PUT", url: url, headers: headers, body: body)
    }

    /// Perform a DELETE request
    public func delete(
        url: String,
        headers: [String: String] = [:]
    ) async throws -> HTTPClientResponse {
        try await performRequest(method: "DELETE", url: url, headers: headers, body: nil)
    }

    /// Perform a PATCH request
    public func patch(
        url: String,
        headers: [String: String] = [:],
        body: Data?
    ) async throws -> HTTPClientResponse {
        try await performRequest(method: "PATCH", url: url, headers: headers, body: body)
    }

    // MARK: - Private

    private func performRequest(
        method: String,
        url: String,
        headers: [String: String],
        body: Data?
    ) async throws -> HTTPClientResponse {
        guard let requestURL = URL(string: url) else {
            throw HTTPError.custom("Invalid URL: \(url)")
        }

        let startTime = Date()

        var request = URLRequest(url: requestURL)
        request.httpMethod = method
        request.timeoutInterval = timeout

        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        if let body = body {
            request.httpBody = body
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            eventBus.publish(HTTPClientErrorEvent(url: url, error: error.localizedDescription))
            throw HTTPError.connectionFailed
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw HTTPError.custom("Invalid response type")
        }

        var responseHeaders: [String: String] = [:]
        for (key, value) in httpResponse.allHeaderFields {
            if let keyStr = key as? String, let valueStr = value as? String {
                responseHeaders[keyStr] = valueStr
            }
        }

        let clientResponse = HTTPClientResponse(
            statusCode: httpResponse.statusCode,
            headers: responseHeaders,
            body: data
        )

        let duration = Date().timeIntervalSince(startTime) * 1000
        eventBus.publish(HTTPClientRequestCompletedEvent(
            url: url,
            method: method,
            statusCode: httpResponse.statusCode,
            durationMs: duration
        ))

        return clientResponse
    }
}

