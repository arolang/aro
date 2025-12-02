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

        let event = HTTPOperationEvent(
            requestId: request.id,
            operationId: match.operationId,
            method: request.method,
            path: path,
            pathTemplate: match.pathTemplate,
            pathParameters: match.pathParameters,
            queryParameters: request.queryParameters,
            headers: request.headers,
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
            headers: [
                "Content-Type": "application/json",
                "X-Request-ID": request.id,
                "X-Operation-ID": match.operationId
            ],
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

#endif  // !os(Windows)
