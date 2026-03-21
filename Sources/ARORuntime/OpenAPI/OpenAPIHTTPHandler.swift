// ============================================================
// OpenAPIHTTPHandler.swift
// ARO Runtime - OpenAPI-Aware HTTP Request Handling
// ============================================================

#if !os(Windows)

import Foundation

/// Handles HTTP requests using OpenAPI routing
public final class OpenAPIHTTPHandler: @unchecked Sendable {
    private let routeRegistry: OpenAPIRouteRegistry
    private let eventBus: EventBus
    private let spec: OpenAPISpec

    public init(routeRegistry: OpenAPIRouteRegistry, eventBus: EventBus) {
        self.routeRegistry = routeRegistry
        self.eventBus = eventBus
        self.spec = routeRegistry.spec
    }

    /// Handle an incoming HTTP request using OpenAPI routing
    public func handleRequest(_ request: HTTPRequest) async -> HTTPResponse {
        let pathComponents = request.path.split(separator: "?", maxSplits: 1)
        let path = String(pathComponents[0])

        guard let match = routeRegistry.match(method: request.method, path: path) else {
            return HTTPResponse(
                statusCode: 404,
                headers: ["Content-Type": "application/json"],
                body: """
                    {"error":"Not Found","message":"No route matches \(request.method) \(path)"}
                    """.data(using: .utf8)
            )
        }

        // Enforce security requirements declared in the OpenAPI spec.
        if let unauthorized = SecurityEnforcer.enforce(
            operation: match.operation,
            globalSecurity: spec.security,
            securitySchemes: spec.components?.securitySchemes,
            headers: request.headers,
            queryParameters: request.queryParameters
        ) {
            return unauthorized
        }

        // Check for deprecated operation
        var responseHeaders: [String: String] = [
            "Content-Type": "application/json",
            "X-Request-ID": request.id,
            "X-Operation-ID": match.operationId
        ]

        if match.operation.deprecated == true {
            print("[DEPRECATION WARNING] Operation '\(match.operationId)' is deprecated")
            responseHeaders["Deprecation"] = "true"
        }

        // Check for deprecated parameters present in the request (includes path-level parameters)
        let effectiveParameters = match.effectiveParameters
        if !effectiveParameters.isEmpty {
            for param in effectiveParameters where param.deprecated == true {
                let isPresent: Bool
                switch param.in {
                case "query":
                    isPresent = request.queryParameters[param.name] != nil
                case "header":
                    isPresent = request.headers[param.name] != nil
                case "path":
                    isPresent = match.pathParameters[param.name] != nil
                default:
                    isPresent = false
                }

                if isPresent {
                    print("[DEPRECATION WARNING] Parameter '\(param.name)' on operation '\(match.operationId)' is deprecated")
                }
            }
        }

        // Build allowEmptyValue lookup for query parameters defined in the spec.
        // Parameters not listed in the spec are not subject to this filter.
        var allowEmptyValueByName: [String: Bool] = [:]
        for param in effectiveParameters where param.in == "query" {
            allowEmptyValueByName[param.name] = param.allowEmptyValue ?? false
        }

        // Filter query parameters: remove entries where the value is empty string
        // and allowEmptyValue is not explicitly true for that parameter.
        let filteredQueryParameters: [String: String] = request.queryParameters.filter { name, value in
            guard value.isEmpty else { return true }
            // If the parameter is not in the spec, always pass through.
            guard let allowEmpty = allowEmptyValueByName[name] else { return true }
            return allowEmpty
        }

        // Inject default values for absent query parameters declared in the spec.
        var enrichedQueryParams = filteredQueryParameters
        for param in effectiveParameters where param.in == "query" {
            guard enrichedQueryParams[param.name] == nil else { continue }
            if let defaultVal = param.schema?.value.defaultValue {
                enrichedQueryParams[param.name] = "\(defaultVal.anyValue)"
            }
        }

        // Parse cookie parameters from Cookie header (case-insensitive lookup)
        let rawCookieHeader = request.headers.first(where: { $0.key.lowercased() == "cookie" })?.value ?? ""
        let allCookies = parseCookieHeader(rawCookieHeader)

        // Filter to only cookies declared as `in: cookie` in the spec
        let declaredCookieNames = Set(
            effectiveParameters
                .filter { $0.in == "cookie" }
                .map { $0.name }
        )
        var cookieParams: [String: String] = [:]
        for name in declaredCookieNames {
            if let value = allCookies[name] {
                cookieParams[name] = value
            }
        }

        // Validate required parameters (query, header, and cookie)
        for param in effectiveParameters where param.required == true {
            switch param.in {
            case "query":
                if enrichedQueryParams[param.name] == nil {
                    return HTTPResponse(
                        statusCode: 400,
                        headers: ["Content-Type": "application/json"],
                        body: "{\"error\":\"Bad Request\",\"message\":\"Required query parameter '\(param.name)' is missing\"}".data(using: .utf8)
                    )
                }
            case "header":
                let lower = param.name.lowercased()
                if !request.headers.keys.contains(where: { $0.lowercased() == lower }) {
                    return HTTPResponse(
                        statusCode: 400,
                        headers: ["Content-Type": "application/json"],
                        body: "{\"error\":\"Bad Request\",\"message\":\"Required header '\(param.name)' is missing\"}".data(using: .utf8)
                    )
                }
            case "cookie":
                if cookieParams[param.name] == nil {
                    return HTTPResponse(
                        statusCode: 400,
                        headers: ["Content-Type": "application/json"],
                        body: "{\"error\":\"Bad Request\",\"message\":\"Required cookie '\(param.name)' is missing\"}".data(using: .utf8)
                    )
                }
            default:
                break
            }
        }

        // Content-type negotiation for request bodies
        if let requestBody = match.operation.requestBody, let body = request.body, !body.isEmpty {
            let rawContentType = request.headers.first(where: { $0.key.lowercased() == "content-type" })?.value

            if let rawContentType = rawContentType {
                // A Content-Type header was sent — verify it is declared in the spec
                if findMatchingMediaType(in: requestBody.content, for: rawContentType) == nil {
                    let supported = requestBody.content.keys.sorted().joined(separator: ", ")
                    return HTTPResponse(
                        statusCode: 415,
                        headers: ["Content-Type": "application/json"],
                        body: """
                            {"error":"Unsupported Media Type","message":"Content-Type '\(rawContentType)' is not supported. Supported types: \(supported)"}
                            """.data(using: .utf8)
                    )
                }
            }
            // If no Content-Type header, fall through and use existing behavior (first media type)
        }

        let event = HTTPOperationEvent(
            requestId: request.id,
            operationId: match.operationId,
            method: request.method,
            path: path,
            pathTemplate: match.pathTemplate,
            pathParameters: match.pathParameters,
            queryParameters: enrichedQueryParams,
            headers: request.headers,
            cookieParameters: cookieParams,
            body: request.body,
            operation: match.operation
        )

        eventBus.publish(event)

        let legacyEvent = HTTPRequestReceivedEvent(
            requestId: request.id,
            method: request.method,
            path: request.path,
            headers: request.headers,
            body: request.body
        )
        eventBus.publish(legacyEvent)

        return HTTPResponse(
            statusCode: 200,
            headers: responseHeaders,
            body: """
                {"status":"ok","operationId":"\(match.operationId)","requestId":"\(request.id)"}
                """.data(using: .utf8)
        )
    }
}

// MARK: - HTTP Operation Event

/// Event emitted when an HTTP request matches an OpenAPI operation
public struct HTTPOperationEvent: RuntimeEvent {
    public static var eventType: String { "http.operation" }
    public let timestamp: Date

    public let requestId: String
    public let operationId: String
    public let method: String
    public let path: String
    public let pathTemplate: String
    public let pathParameters: [String: String]
    public let queryParameters: [String: String]
    public let headers: [String: String]
    public let cookieParameters: [String: String]
    public let body: Data?
    public let operation: Operation

    public init(
        requestId: String,
        operationId: String,
        method: String,
        path: String,
        pathTemplate: String,
        pathParameters: [String: String],
        queryParameters: [String: String],
        headers: [String: String],
        cookieParameters: [String: String] = [:],
        body: Data?,
        operation: Operation
    ) {
        self.timestamp = Date()
        self.requestId = requestId
        self.operationId = operationId
        self.method = method
        self.path = path
        self.pathTemplate = pathTemplate
        self.pathParameters = pathParameters
        self.queryParameters = queryParameters
        self.headers = headers
        self.cookieParameters = cookieParameters
        self.body = body
        self.operation = operation
    }

    public var bodyJSON: [String: Any]? {
        guard let data = body else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    public func parseBody<T: Decodable>(_ type: T.Type) throws -> T? {
        guard let data = body else { return nil }
        return try JSONDecoder().decode(type, from: data)
    }
}

// Note: HTTPRequestReceivedEvent and HTTPResponseSentEvent are defined in Events/EventTypes.swift

// MARK: - Content-Type Negotiation

/// Find the best matching media type from an OpenAPI content map for a given Content-Type header value.
///
/// Matching is performed in priority order:
/// 1. Exact match (after stripping parameters such as `; charset=utf-8`)
/// 2. Subtype wildcard match (`application/*`)
/// 3. Catch-all wildcard (`*/*`)
///
/// - Parameters:
///   - content: The `content` map from an OpenAPI `requestBody`.
///   - contentType: The raw value of the incoming `Content-Type` header.
/// - Returns: The matched `MediaType`, or `nil` if no match was found.
func findMatchingMediaType(in content: [String: MediaType], for contentType: String) -> MediaType? {
    // Strip parameters: "application/json; charset=utf-8" -> "application/json"
    let baseType = contentType.split(separator: ";").first
        .map(String.init)?.trimmingCharacters(in: .whitespaces) ?? contentType

    // 1. Exact match
    if let exact = content[baseType] { return exact }

    // 2. Subtype wildcard: "application/*"
    let parts = baseType.split(separator: "/")
    if parts.count == 2 {
        let mainType = String(parts[0])
        if let wildcard = content["\(mainType)/*"] { return wildcard }
    }

    // 3. Catch-all wildcard
    return content["*/*"]
}

#endif  // !os(Windows)
