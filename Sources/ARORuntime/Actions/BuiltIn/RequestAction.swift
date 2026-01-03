// ============================================================
// RequestAction.swift
// ARO Runtime - HTTP Request Action
// ============================================================

import Foundation
import AROParser

/// Makes HTTP requests to external services
///
/// The Request action performs HTTP requests using the HTTP client service.
/// It supports GET, POST, PUT, DELETE, and PATCH methods.
///
/// ## Syntax
/// ```aro
/// (* Simple GET request *)
/// <Request> the <response> from <url>.
///
/// (* POST request *)
/// <Request> the <response> to <url> with <data>.
///
/// (* With config object for custom headers, method, timeout *)
/// <Request> the <response> from <url> with {
///     method: "POST",
///     headers: { "Content-Type": "application/json", "Authorization": "Bearer token" },
///     body: <data>,
///     timeout: 60
/// }.
/// ```
///
/// ## Example
/// ```aro
/// (Fetch Weather: External API) {
///     <Create> the <api-url> with "https://api.weather.com/current".
///     <Request> the <weather> from <api-url>.
///     <Extract> the <temperature> from the <weather: temp>.
///     <Return> an <OK: status> with <temperature>.
/// }
/// ```
public struct RequestAction: ActionImplementation {
    public static let role: ActionRole = .request
    public static let verbs: Set<String> = ["request", "http"]
    public static let validPrepositions: Set<Preposition> = [.from, .to, .via, .with]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        // Get HTTP client service
        #if !os(Windows)
        // Try to get existing URLSession-based client first (better compatibility
        // with compiled binaries that use sync-to-async bridging)
        let urlClient: URLSessionHTTPClient
        if let existingClient = context.service(URLSessionHTTPClient.self) {
            urlClient = existingClient
        } else {
            // Create a URLSession-based client for better compatibility with
            // compiled binaries that use sync-to-async bridging.
            // The NIO-based AsyncHTTPClient can have issues with semaphore blocking.
            let newClient = URLSessionHTTPClient()
            context.register(newClient)
            urlClient = newClient
        }

        // Extract config from with { ... } clause
        let config = getConfig(context: context)
        let configMethod = config["method"] as? String
        let configHeaders = extractHeaders(from: config)
        let configBody = config["body"]
        let configTimeout = extractTimeout(from: config)

        // Determine URL
        let url: String
        if let resolvedUrl: String = context.resolve(object.base) {
            url = resolvedUrl
        } else if config.isEmpty, let literalUrl = context.resolveAny("_literal_") as? String,
                  literalUrl.hasPrefix("http") {
            // Only use _literal_ as URL if no config (backwards compatibility)
            url = literalUrl
        } else {
            // Use object base as literal URL
            url = object.base
        }

        // Validate URL
        guard url.hasPrefix("http://") || url.hasPrefix("https://") else {
            throw ActionError.runtimeError("Invalid URL: \(url). URL must start with http:// or https://")
        }

        // Determine HTTP method (config overrides preposition)
        let method: String
        if let m = configMethod?.uppercased() {
            method = m
        } else {
            method = switch object.preposition {
            case .from: "GET"
            case .to: "POST"
            case .via: object.specifiers.first?.uppercased() ?? "GET"
            case .with: "GET"  // Default for standalone with
            default: "GET"
            }
        }

        // Get request body (from config or legacy)
        let body: Data?
        if let b = configBody {
            body = convertToData(b)
        } else if config.isEmpty {
            body = getRequestBody(context: context)
        } else {
            body = nil
        }

        // Make the request
        let response: HTTPClientResponse
        switch method {
        case "GET":
            response = try await urlClient.get(url: url, headers: configHeaders, timeout: configTimeout)
        case "POST":
            response = try await urlClient.post(url: url, headers: configHeaders, body: body, timeout: configTimeout)
        case "PUT":
            response = try await urlClient.put(url: url, headers: configHeaders, body: body, timeout: configTimeout)
        case "DELETE":
            response = try await urlClient.delete(url: url, headers: configHeaders, timeout: configTimeout)
        case "PATCH":
            response = try await urlClient.patch(url: url, headers: configHeaders, body: body, timeout: configTimeout)
        default:
            response = try await urlClient.get(url: url, headers: configHeaders, timeout: configTimeout)
        }

        // Parse response body as JSON if possible
        let resultValue: any Sendable
        if let bodyData = response.body,
           let json = try? JSONSerialization.jsonObject(with: bodyData) {
            if let dict = json as? [String: Any] {
                resultValue = convertToSendable(dict)
            } else if let array = json as? [Any] {
                resultValue = array.map { convertToSendable($0) }
            } else {
                resultValue = response.bodyString ?? ""
            }
        } else {
            resultValue = response.bodyString ?? ""
        }

        // Return result - FeatureSetExecutor will bind it
        // Response metadata (statusCode, headers, isSuccess) could be added
        // to resultValue if needed, but for now we return the parsed body
        return resultValue
        #else
        throw ActionError.runtimeError("HTTP client not available on Windows")
        #endif
    }

    // MARK: - Private Helpers

    /// Extract config object from context (_expression_ or _literal_)
    private func getConfig(context: ExecutionContext) -> [String: any Sendable] {
        if let config = context.resolveAny("_expression_") as? [String: any Sendable] {
            return config
        }
        if let config = context.resolveAny("_literal_") as? [String: any Sendable] {
            return config
        }
        return [:]
    }

    /// Extract headers from config, handling nested maps
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

    /// Extract timeout from config
    private func extractTimeout(from config: [String: any Sendable]) -> TimeInterval? {
        if let timeout = config["timeout"] as? Int {
            return TimeInterval(timeout)
        }
        if let timeout = config["timeout"] as? Double {
            return timeout
        }
        return nil
    }

    /// Convert a value to Data for request body
    private func convertToData(_ value: any Sendable) -> Data? {
        if let data = value as? Data {
            return data
        } else if let string = value as? String {
            return string.data(using: .utf8)
        } else if let dict = value as? [String: Any] {
            return try? JSONSerialization.data(withJSONObject: dict)
        } else if let dict = value as? [String: any Sendable] {
            // Convert Sendable dict to Any dict for serialization
            var anyDict: [String: Any] = [:]
            for (key, val) in dict {
                anyDict[key] = val
            }
            return try? JSONSerialization.data(withJSONObject: anyDict)
        }
        return nil
    }

    /// Get request body from context (legacy support)
    private func getRequestBody(context: ExecutionContext) -> Data? {
        // Check for literal value from "with" clause
        if let literal = context.resolveAny("_literal_") {
            if let data = literal as? Data {
                return data
            } else if let string = literal as? String {
                return string.data(using: .utf8)
            } else if let dict = literal as? [String: Any] {
                return try? JSONSerialization.data(withJSONObject: dict)
            }
        }

        // Check for expression value
        if let expr = context.resolveAny("_expression_") {
            if let data = expr as? Data {
                return data
            } else if let string = expr as? String {
                return string.data(using: .utf8)
            } else if let dict = expr as? [String: Any] {
                return try? JSONSerialization.data(withJSONObject: dict)
            }
        }

        return nil
    }

    /// Convert Any to Sendable
    private func convertToSendable(_ value: Any) -> any Sendable {
        if let str = value as? String { return str }
        if let int = value as? Int { return int }
        if let double = value as? Double { return double }
        if let bool = value as? Bool { return bool }
        if let array = value as? [Any] {
            return array.map { convertToSendable($0) }
        }
        if let dict = value as? [String: Any] {
            var result: [String: any Sendable] = [:]
            for (key, val) in dict {
                result[key] = convertToSendable(val)
            }
            return result
        }
        return String(describing: value)
    }
}
