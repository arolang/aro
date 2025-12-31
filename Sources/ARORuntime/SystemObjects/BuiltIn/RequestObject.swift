// ============================================================
// RequestObject.swift
// ARO Runtime - HTTP Request System Object
// ============================================================

import Foundation

// MARK: - Request Object

/// HTTP request system object
///
/// A source-only context object that provides access to the current HTTP request.
/// Only available in HTTP handler feature sets.
///
/// ## ARO Usage
/// ```aro
/// <Extract> the <data> from the <request: body>.
/// <Extract> the <id> from the <request: pathParameters.id>.
/// <Extract> the <method> from the <request: method>.
/// ```
public struct RequestObject: SystemObject {
    public static let identifier = "request"
    public static let description = "HTTP request context"

    public var capabilities: SystemObjectCapabilities { .source }

    private let method: String
    private let path: String
    private let headers: [String: String]
    private let body: (any Sendable)?
    private let queryParameters: [String: String]
    private let pathParameters: [String: String]

    /// Create a request object from HTTP request data
    public init(
        method: String,
        path: String,
        headers: [String: String],
        body: (any Sendable)?,
        queryParameters: [String: String],
        pathParameters: [String: String]
    ) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
        self.queryParameters = queryParameters
        self.pathParameters = pathParameters
    }

    public func read(property: String?) async throws -> any Sendable {
        guard let property = property else {
            // Return the full request as a dictionary
            var request: [String: any Sendable] = [
                "method": method,
                "path": path,
                "headers": headers,
                "queryParameters": queryParameters,
                "pathParameters": pathParameters
            ]
            if let body = body {
                request["body"] = body
            }
            return request
        }

        // Support nested paths like "headers.Authorization"
        let parts = property.split(separator: ".").map(String.init)

        switch parts[0] {
        case "method":
            return method
        case "path":
            return path
        case "url":
            return path // Same as path in this context
        case "headers":
            if parts.count > 1 {
                let headerName = parts[1]
                // Case-insensitive header lookup
                let key = headers.keys.first { $0.lowercased() == headerName.lowercased() }
                guard let key = key, let value = headers[key] else {
                    throw SystemObjectError.propertyNotFound(property, in: Self.identifier)
                }
                return value
            }
            return headers
        case "body":
            return body ?? [String: any Sendable]()
        case "queryParameters", "query":
            if parts.count > 1 {
                let paramName = parts[1]
                guard let value = queryParameters[paramName] else {
                    throw SystemObjectError.propertyNotFound(property, in: Self.identifier)
                }
                return value
            }
            return queryParameters
        case "pathParameters":
            if parts.count > 1 {
                let paramName = parts[1]
                guard let value = pathParameters[paramName] else {
                    throw SystemObjectError.propertyNotFound(property, in: Self.identifier)
                }
                return value
            }
            return pathParameters
        default:
            throw SystemObjectError.propertyNotFound(property, in: Self.identifier)
        }
    }

    public func write(_ value: any Sendable) async throws {
        throw SystemObjectError.notWritable(Self.identifier)
    }
}

// MARK: - Path Parameters Object

/// Path parameters system object
///
/// Direct access to URL path parameters. Convenience alias for request.pathParameters.
///
/// ## ARO Usage
/// ```aro
/// <Extract> the <id> from the <pathParameters: id>.
/// ```
public struct PathParametersObject: SystemObject {
    public static let identifier = "pathParameters"
    public static let description = "URL path parameters"

    public var capabilities: SystemObjectCapabilities { .source }

    private let parameters: [String: String]

    public init(parameters: [String: String]) {
        self.parameters = parameters
    }

    public func read(property: String?) async throws -> any Sendable {
        guard let key = property else {
            return parameters
        }

        guard let value = parameters[key] else {
            throw SystemObjectError.propertyNotFound(key, in: Self.identifier)
        }

        return value
    }

    public func write(_ value: any Sendable) async throws {
        throw SystemObjectError.notWritable(Self.identifier)
    }
}

// MARK: - Query Parameters Object

/// Query parameters system object
///
/// Direct access to URL query parameters.
///
/// ## ARO Usage
/// ```aro
/// <Extract> the <search> from the <queryParameters: q>.
/// ```
public struct QueryParametersObject: SystemObject {
    public static let identifier = "queryParameters"
    public static let description = "URL query parameters"

    public var capabilities: SystemObjectCapabilities { .source }

    private let parameters: [String: String]

    public init(parameters: [String: String]) {
        self.parameters = parameters
    }

    public func read(property: String?) async throws -> any Sendable {
        guard let key = property else {
            return parameters
        }

        guard let value = parameters[key] else {
            throw SystemObjectError.propertyNotFound(key, in: Self.identifier)
        }

        return value
    }

    public func write(_ value: any Sendable) async throws {
        throw SystemObjectError.notWritable(Self.identifier)
    }
}

// MARK: - Headers Object

/// HTTP headers system object
///
/// Direct access to HTTP request headers.
///
/// ## ARO Usage
/// ```aro
/// <Extract> the <auth> from the <headers: Authorization>.
/// ```
public struct HeadersObject: SystemObject {
    public static let identifier = "headers"
    public static let description = "HTTP request headers"

    public var capabilities: SystemObjectCapabilities { .source }

    private let headers: [String: String]

    public init(headers: [String: String]) {
        self.headers = headers
    }

    public func read(property: String?) async throws -> any Sendable {
        guard let key = property else {
            return headers
        }

        // Case-insensitive header lookup
        let matchingKey = headers.keys.first { $0.lowercased() == key.lowercased() }
        guard let matchingKey = matchingKey, let value = headers[matchingKey] else {
            throw SystemObjectError.propertyNotFound(key, in: Self.identifier)
        }

        return value
    }

    public func write(_ value: any Sendable) async throws {
        throw SystemObjectError.notWritable(Self.identifier)
    }
}

// MARK: - Body Object

/// Request body system object
///
/// Direct access to the parsed request body.
///
/// ## ARO Usage
/// ```aro
/// <Extract> the <data> from the <body>.
/// <Extract> the <name> from the <body: name>.
/// ```
public struct BodyObject: SystemObject {
    public static let identifier = "body"
    public static let description = "Request body"

    public var capabilities: SystemObjectCapabilities { .source }

    private let body: any Sendable

    public init(body: any Sendable) {
        self.body = body
    }

    public func read(property: String?) async throws -> any Sendable {
        guard let key = property else {
            return body
        }

        // Navigate into the body if it's a dictionary
        if let dict = body as? [String: any Sendable] {
            guard let value = dict[key] else {
                throw SystemObjectError.propertyNotFound(key, in: Self.identifier)
            }
            return value
        }

        throw SystemObjectError.propertyNotFound(key, in: Self.identifier)
    }

    public func write(_ value: any Sendable) async throws {
        throw SystemObjectError.notWritable(Self.identifier)
    }
}

// MARK: - Registration

public extension SystemObjectRegistry {
    /// Register HTTP context system objects
    ///
    /// These are registered as context-dependent objects that need
    /// HTTP request data from the execution context.
    func registerHTTPContextObjects() {
        // These need context from the feature set execution
        // Registration here provides metadata, actual instances are created per-request
        register(
            "request",
            description: RequestObject.description,
            capabilities: .source
        ) { _ in
            // Placeholder - actual request is bound at execution time
            PlaceholderRequestObject()
        }

        register(
            "pathParameters",
            description: PathParametersObject.description,
            capabilities: .source
        ) { _ in
            PlaceholderRequestObject()
        }

        register(
            "queryParameters",
            description: QueryParametersObject.description,
            capabilities: .source
        ) { _ in
            PlaceholderRequestObject()
        }

        register(
            "headers",
            description: HeadersObject.description,
            capabilities: .source
        ) { _ in
            PlaceholderRequestObject()
        }

        register(
            "body",
            description: BodyObject.description,
            capabilities: .source
        ) { _ in
            PlaceholderRequestObject()
        }
    }
}

// MARK: - Placeholder for Registration

/// Placeholder for HTTP context objects when not in an HTTP handler
private struct PlaceholderRequestObject: SystemObject {
    static let identifier = "request"
    static let description = "HTTP request context (only available in HTTP handlers)"

    var capabilities: SystemObjectCapabilities { .source }

    func read(property: String?) async throws -> any Sendable {
        throw SystemObjectError.notAvailableInContext(Self.identifier, context: "non-HTTP")
    }

    func write(_ value: any Sendable) async throws {
        throw SystemObjectError.notWritable(Self.identifier)
    }
}
