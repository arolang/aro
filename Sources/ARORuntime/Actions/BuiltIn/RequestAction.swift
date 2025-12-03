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
/// (* GET request *)
/// <Request> the <response> from <url>.
///
/// (* POST request *)
/// <Request> the <response> to <url> with <data>.
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
    public static let validPrepositions: Set<Preposition> = [.from, .to, .via]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        // Get HTTP client service
        #if !os(Windows)
        let httpClient: AROHTTPClient
        if let existingClient = context.service(AROHTTPClient.self) {
            httpClient = existingClient
        } else {
            // Create a new client if not registered
            httpClient = AROHTTPClient()
            context.register(httpClient)
        }

        // Determine URL
        let url: String
        if let resolvedUrl: String = context.resolve(object.base) {
            url = resolvedUrl
        } else if let literalUrl = context.resolveAny("_literal_") as? String,
                  literalUrl.hasPrefix("http") {
            url = literalUrl
        } else {
            // Use object base as literal URL
            url = object.base
        }

        // Validate URL
        guard url.hasPrefix("http://") || url.hasPrefix("https://") else {
            throw ActionError.runtimeError("Invalid URL: \(url). URL must start with http:// or https://")
        }

        // Determine method based on preposition
        let response: HTTPClientResponse
        switch object.preposition {
        case .from:
            // GET request
            response = try await httpClient.get(url: url)

        case .to:
            // POST request
            let body = getRequestBody(context: context)
            response = try await httpClient.post(url: url, headers: [:], body: body)

        case .via:
            // Determine method from specifiers
            let method = object.specifiers.first?.uppercased() ?? "GET"
            let body = getRequestBody(context: context)

            switch method {
            case "GET":
                response = try await httpClient.get(url: url)
            case "POST":
                response = try await httpClient.post(url: url, headers: [:], body: body)
            case "PUT":
                response = try await httpClient.put(url: url, headers: [:], body: body)
            case "DELETE":
                response = try await httpClient.delete(url: url)
            case "PATCH":
                response = try await httpClient.patch(url: url, headers: [:], body: body)
            default:
                response = try await httpClient.get(url: url)
            }

        default:
            throw ActionError.invalidPreposition(
                action: "request",
                received: object.preposition,
                expected: Self.validPrepositions
            )
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

        // Bind the result
        context.bind(result.base, value: resultValue)

        // Also bind response metadata
        context.bind("\(result.base).statusCode", value: response.statusCode)
        context.bind("\(result.base).headers", value: response.headers)
        context.bind("\(result.base).isSuccess", value: response.isSuccess)

        return resultValue
        #else
        throw ActionError.runtimeError("HTTP client not available on Windows")
        #endif
    }

    /// Get request body from context
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

