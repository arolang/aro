// ============================================================
// StreamAction.swift
// ARO Runtime - SSE Client Action
// ============================================================

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import AROParser

/// Subscribes to a Server-Sent Events (SSE) stream and emits domain events for each message.
///
/// The Stream action opens a persistent HTTP connection with `Accept: text/event-stream`,
/// parses the SSE protocol frames, and publishes a `DomainEvent` for each complete SSE
/// message. Reconnects automatically with exponential backoff if the connection drops.
///
/// The application stays alive (Keepalive remains in service mode) while the stream is active.
///
/// ## Syntax
/// ```aro
/// Stream the <event-name> from <url>.
/// Stream the <event-name> from <url> with {
///     headers: { "Authorization": "Bearer token" },
///     retry: 3.0,
///     timeout: 30.0
/// }.
/// ```
///
/// ## Example
/// ```aro
/// (Application-Start: Price Monitor) {
///     Create the <sse-url> with "https://example.com/prices/stream".
///     Stream the <price-update> from <sse-url>.
///     Keepalive the <application> for the <events>.
///     Return an <OK: status> for the <startup>.
/// }
///
/// (Handle Price: price-update Handler) {
///     Extract the <symbol> from the <event: symbol>.
///     Extract the <price> from the <event: price>.
///     Log "Price update: ${symbol} = ${price}" to the <console>.
///     Return an <OK: status> for the <update>.
/// }
/// ```
///
/// ## SSE Frame Parsing
/// Each SSE message is collected from `data:`, `event:`, and `retry:` lines.
/// When a blank line is received, the complete message is emitted as a DomainEvent:
/// - `eventType`: the `event:` field value, or the `result.base` name if absent
/// - `payload`: parsed JSON from `data:` field, or `{ "data": rawString }` if not JSON
///   The SSE `event:` field value is included in payload as `"kind"` (not `"type"`,
///   which is a reserved keyword in ARO and would be inaccessible).
///
/// ## Reconnection
/// On connection loss or error, the action waits using exponential backoff
/// (starting from the `retry:` server directive or 3 seconds, up to 30 seconds),
/// then reconnects automatically.
public struct StreamAction: ActionImplementation {
    public static let role: ActionRole = .request
    public static let verbs: Set<String> = ["stream", "subscribe"]
    public static let validPrepositions: Set<Preposition> = [.from, .with]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        #if !os(Windows)
        // Resolve URL
        let url: String
        if context.exists(object.base) {
            if let resolved = context.resolveAny(object.base) as? String {
                url = resolved
            } else {
                url = object.base
            }
        } else if let literal = context.resolveAny("_literal_") as? String, literal.hasPrefix("http") {
            url = literal
        } else {
            url = object.base
        }

        guard url.hasPrefix("http://") || url.hasPrefix("https://")
           || url.hasPrefix("ws://") || url.hasPrefix("wss://") else {
            throw ActionError.invalidURL(url)
        }

        // Extract optional config from with { ... } clause
        let config = getConfig(context: context)
        let extraHeaders = extractHeaders(from: config)
        let configTimeout = extractTimeout(from: config)
        let initialRetry = extractRetry(from: config) ?? 3.0

        let eventName = result.base

        // Register as an active event source so Keepalive stays in service mode
        await EventBus.shared.registerEventSource()

        // Capture values for the detached task (must be Sendable)
        let capturedURL = url
        let capturedHeaders = extraHeaders
        let capturedTimeout = configTimeout
        let capturedRetry = initialRetry
        let capturedEventName = eventName

        let isWebSocket = url.hasPrefix("ws://") || url.hasPrefix("wss://")

        let streamTask = Task.detached {
            if isWebSocket {
                await WebSocketStreamRunner.run(
                    url: capturedURL,
                    eventName: capturedEventName,
                    headers: capturedHeaders,
                    initialRetryInterval: capturedRetry
                )
            } else {
                await SSEStreamRunner.run(
                    url: capturedURL,
                    eventName: capturedEventName,
                    headers: capturedHeaders,
                    timeout: capturedTimeout,
                    initialRetryInterval: capturedRetry
                )
            }
        }

        // Watch for shutdown and cancel the stream
        Task.detached {
            await ShutdownCoordinator.shared.waitForShutdown()
            streamTask.cancel()
            await EventBus.shared.unregisterEventSource()
        }

        context.bind(result.base, value: url)
        return url
        #else
        throw ActionError.unsupportedPlatform("Stream action")
        #endif
    }

    // MARK: - Private Helpers

    private func getConfig(context: ExecutionContext) -> [String: any Sendable] {
        if let config = context.resolveAny("_expression_") as? [String: any Sendable] {
            return config
        }
        if let config = context.resolveAny("_with_") as? [String: any Sendable] {
            return config
        }
        if let config = context.resolveAny("_literal_") as? [String: any Sendable] {
            return config
        }
        return [:]
    }

    private func extractHeaders(from config: [String: any Sendable]) -> [String: String] {
        guard let headersValue = config["headers"] else { return [:] }
        var headers: [String: String] = [:]
        if let headersDict = headersValue as? [String: String] {
            headers = headersDict
        } else if let headersDict = headersValue as? [String: any Sendable] {
            for (key, value) in headersDict {
                headers[key] = String(describing: value)
            }
        }
        return headers
    }

    private func extractTimeout(from config: [String: any Sendable]) -> TimeInterval? {
        if let timeout = config["timeout"] as? Int { return TimeInterval(timeout) }
        if let timeout = config["timeout"] as? Double { return timeout }
        return nil
    }

    private func extractRetry(from config: [String: any Sendable]) -> TimeInterval? {
        if let retry = config["retry"] as? Int { return TimeInterval(retry) }
        if let retry = config["retry"] as? Double { return retry }
        return nil
    }
}

// MARK: - WebSocket Stream Runner

/// WebSocket-based stream runner for wss:// and ws:// URLs.
/// Handles Mastodon-style WebSocket streaming: JSON messages with
/// {"event":"update","payload":"{...}"} where payload is a JSON-encoded string.
enum WebSocketStreamRunner {
    static let maxRetryInterval: TimeInterval = 30.0

    static func run(
        url: String,
        eventName: String,
        headers: [String: String],
        initialRetryInterval: TimeInterval
    ) async {
        var retryInterval = initialRetryInterval
        while !Task.isCancelled {
            do {
                try await connect(url: url, eventName: eventName, headers: headers)
                retryInterval = initialRetryInterval  // reset on clean close
            } catch {
                try? await Task.sleep(nanoseconds: UInt64(retryInterval * 1_000_000_000))
                retryInterval = min(retryInterval * 2, maxRetryInterval)
            }
        }
    }

    private static func connect(
        url: String,
        eventName: String,
        headers: [String: String]
    ) async throws {
        guard let requestURL = URL(string: url) else {
            throw ActionError.runtimeError("WebSocket: malformed URL '\(url)'")
        }
        var request = URLRequest(url: requestURL)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: request)
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }

        while !Task.isCancelled {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                throw error
            }

            let text: String
            switch message {
            case .string(let s): text = s
            case .data(let d): text = String(data: d, encoding: .utf8) ?? ""
            @unknown default: continue
            }

            guard let data = text.data(using: .utf8),
                  let outer = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let eventType = outer["event"] as? String else {
                continue
            }

            // Build payload: parse inner "payload" JSON string if present,
            // otherwise use empty dict. Add "kind" = eventType.
            var payload: [String: any Sendable]
            if let payloadStr = outer["payload"] as? String,
               let payloadData = payloadStr.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] {
                payload = convertToSendable(parsed)
            } else {
                payload = [:]
            }
            payload["kind"] = eventType

            EventBus.shared.publish(DomainEvent(eventType: eventName, payload: payload))
        }
    }

    private static func convertToSendable(_ dict: [String: Any]) -> [String: any Sendable] {
        var result: [String: any Sendable] = [:]
        for (key, val) in dict {
            result[key] = convertValue(val)
        }
        return result
    }

    private static func convertValue(_ value: Any) -> any Sendable {
        if let str = value as? String { return str }
        if let int = value as? Int { return int }
        if let double = value as? Double { return double }
        if let bool = value as? Bool { return bool }
        if let array = value as? [Any] { return array.map { convertValue($0) } }
        if let dict = value as? [String: Any] { return convertToSendable(dict) }
        return String(describing: value)
    }
}

// MARK: - SSE Stream Runner

/// Stateless namespace for the SSE connection loop — kept separate so it
/// can be called from a `Task.detached` context without actor isolation issues.
enum SSEStreamRunner {
    /// Maximum backoff interval in seconds.
    static let maxRetryInterval: TimeInterval = 30.0

    /// Opens a URLSession data-task SSE stream, parses frames, publishes DomainEvents.
    /// Reconnects with exponential backoff on any error until the task is cancelled.
    static func run(
        url: String,
        eventName: String,
        headers: [String: String],
        timeout: TimeInterval?,
        initialRetryInterval: TimeInterval
    ) async {
        var retryInterval = initialRetryInterval

        while !Task.isCancelled {
            do {
                retryInterval = try await openAndParse(
                    url: url,
                    eventName: eventName,
                    headers: headers,
                    timeout: timeout,
                    currentRetryInterval: retryInterval
                )
            } catch {
                // Connection failed — wait, then retry
                try? await Task.sleep(nanoseconds: UInt64(retryInterval * 1_000_000_000))
                retryInterval = min(retryInterval * 2, maxRetryInterval)
            }
        }
    }

    /// Opens the SSE connection, reads frames, returns the updated retry interval.
    /// Throws on connection error; returns normally on server close.
    ///
    /// Uses `URLSessionDataDelegate` + `AsyncStream` for cross-platform compatibility.
    /// (`URLSession.bytes(for:)` is Darwin-only and not available in swift-corelibs-foundation.)
    private static func openAndParse(
        url: String,
        eventName: String,
        headers: [String: String],
        timeout: TimeInterval?,
        currentRetryInterval: TimeInterval
    ) async throws -> TimeInterval {
        guard let requestURL = URL(string: url) else {
            throw ActionError.invalidURL(url)
        }

        var request = URLRequest(url: requestURL)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let t = timeout {
            request.timeoutInterval = t
        }

        // Bridge URLSessionDataDelegate callbacks to AsyncStream<String> lines.
        // This pattern works on all platforms (Darwin + Linux / swift-corelibs-foundation).
        let (lineStream, continuation) = AsyncStream<String>.makeStream()
        let delegate = SSEDataDelegate(continuation: continuation, headers: headers)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let task = session.dataTask(with: request)
        task.resume()

        // SSE frame accumulator
        var currentEventType: String? = nil
        var currentData: [String] = []
        var retryInterval = currentRetryInterval

        func dispatch() {
            guard !currentData.isEmpty else { return }
            let dataString = currentData.joined(separator: "\n")
            var payload = parseSSEData(dataString)
            if let sseType = currentEventType {
                payload["kind"] = sseType
            }
            // DomainEvent payload: parsed JSON from SSE data: field, or { "data": String } if not JSON.
            //   Optional "type": String added when SSE event: field is present.
            //   eventType: the SSE event: field value, or result.base name if absent.
            EventBus.shared.publish(DomainEvent(eventType: eventName, payload: payload))
            currentEventType = nil
            currentData = []
        }

        for await line in lineStream {
            guard !Task.isCancelled else { break }

            if line.isEmpty {
                dispatch()
            } else if line.hasPrefix(":") {
                continue
            } else if line.hasPrefix("event:") {
                if !currentData.isEmpty { dispatch() }
                currentEventType = String(line.dropFirst("event:".count))
                    .trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                let value = String(line.dropFirst("data:".count))
                    .trimmingCharacters(in: .whitespaces)
                currentData.append(value)
            } else if line.hasPrefix("retry:") {
                let retryStr = String(line.dropFirst("retry:".count))
                    .trimmingCharacters(in: .whitespaces)
                if let ms = Double(retryStr) {
                    retryInterval = ms / 1000.0
                }
            }
        }
        dispatch()

        // Propagate any connection error the delegate captured
        if let error = delegate.connectionError {
            throw error
        }

        return retryInterval
    }

    /// Parse the raw SSE data string into a payload dictionary.
    /// If the data is valid JSON, returns it directly.
    /// Otherwise wraps it as `{ "data": rawString }`.
    private static func parseSSEData(_ raw: String) -> [String: any Sendable] {
        if let data = raw.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data),
           let dict = json as? [String: Any] {
            return convertToSendable(dict)
        }
        return ["data": raw]
    }

    private static func convertToSendable(_ dict: [String: Any]) -> [String: any Sendable] {
        var result: [String: any Sendable] = [:]
        for (key, val) in dict {
            result[key] = convertValue(val)
        }
        return result
    }

    private static func convertValue(_ value: Any) -> any Sendable {
        if let str = value as? String { return str }
        if let int = value as? Int { return int }
        if let double = value as? Double { return double }
        if let bool = value as? Bool { return bool }
        if let array = value as? [Any] { return array.map { convertValue($0) } }
        if let dict = value as? [String: Any] { return convertToSendable(dict) }
        return String(describing: value)
    }
}

// MARK: - SSE Data Delegate

/// URLSessionDataDelegate that bridges streaming response bytes into an AsyncStream of lines.
/// Works on all platforms (Darwin + Linux / swift-corelibs-foundation).
private final class SSEDataDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let continuation: AsyncStream<String>.Continuation
    private let originalHeaders: [String: String]
    private var buffer = ""
    var connectionError: Error? = nil

    init(continuation: AsyncStream<String>.Continuation, headers: [String: String]) {
        self.continuation = continuation
        self.originalHeaders = headers
    }

    // Re-attach original headers (e.g. Authorization) when following cross-domain redirects.
    // URLSession strips sensitive headers on host changes for security, but SSE streaming
    // requires them on the streaming subdomain (e.g. streaming.mastodon.social).
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        var mutableRequest = request
        for (key, value) in originalHeaders {
            mutableRequest.setValue(value, forHTTPHeaderField: key)
        }
        completionHandler(mutableRequest)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer += String(data: data, encoding: .utf8) ?? ""
        while let range = buffer.range(of: "\n") {
            let line = String(buffer[buffer.startIndex..<range.lowerBound])
                .trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            buffer = String(buffer[range.upperBound...])
            continuation.yield(line)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        connectionError = error
        continuation.finish()
    }
}
