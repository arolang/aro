// ============================================================
// OpenAPIRouteRegistry.swift
// ARO Runtime - OpenAPI Route Matching
// ============================================================

import Foundation

/// Registry for matching HTTP requests to OpenAPI operations
public struct OpenAPIRouteRegistry: Sendable {
    /// Registered routes
    private let routes: [Route]

    /// The OpenAPI spec this registry was built from
    public let spec: OpenAPISpec

    /// Initialize from an OpenAPI specification
    public init(spec: OpenAPISpec) {
        self.spec = spec
        self.routes = Self.buildRoutes(from: spec)
    }

    /// Build routes from OpenAPI spec
    private static func buildRoutes(from spec: OpenAPISpec) -> [Route] {
        var routes: [Route] = []

        for (pathTemplate, pathItem) in spec.paths {
            let pattern = PathPattern(template: pathTemplate)

            for (method, operation) in pathItem.allOperations {
                guard let operationId = operation.operationId else { continue }

                routes.append(Route(
                    method: method.uppercased(),
                    pattern: pattern,
                    operationId: operationId,
                    operation: operation,
                    pathParameters: pathItem.parameters
                ))
            }
        }

        // Sort routes: more specific patterns first (fewer wildcards)
        routes.sort { $0.pattern.specificity > $1.pattern.specificity }

        return routes
    }

    /// Match an incoming request to an operation
    /// - Parameters:
    ///   - method: HTTP method (GET, POST, etc.)
    ///   - path: Request path (e.g., "/users/123")
    /// - Returns: Match result with operationId and extracted parameters
    public func match(method: String, path: String) -> RouteMatch? {
        let normalizedMethod = method.uppercased()
        let normalizedPath = normalizePath(path)

        for route in routes {
            guard route.method == normalizedMethod else { continue }

            if let params = route.pattern.match(normalizedPath) {
                return RouteMatch(
                    operationId: route.operationId,
                    pathParameters: params,
                    operation: route.operation,
                    pathTemplate: route.pattern.template
                )
            }
        }

        return nil
    }

    /// Get all registered operation IDs
    public var operationIds: [String] {
        routes.map { $0.operationId }
    }

    /// Normalize a path (remove trailing slashes, ensure leading slash)
    private func normalizePath(_ path: String) -> String {
        var normalized = path
        if !normalized.hasPrefix("/") {
            normalized = "/" + normalized
        }
        while normalized.hasSuffix("/") && normalized.count > 1 {
            normalized.removeLast()
        }
        return normalized
    }
}

// MARK: - Route

/// A registered route
struct Route: Sendable {
    let method: String
    let pattern: PathPattern
    let operationId: String
    let operation: Operation
    let pathParameters: [Parameter]?
}

// MARK: - Route Match

/// Result of matching a request to a route
public struct RouteMatch: Sendable {
    /// The matched operationId (feature set name)
    public let operationId: String

    /// Extracted path parameters (e.g., ["id": "123"])
    public let pathParameters: [String: String]

    /// The matched operation definition
    public let operation: Operation

    /// The path template that matched
    public let pathTemplate: String
}

// MARK: - Path Pattern

/// Pattern for matching URL paths with parameters
public struct PathPattern: Sendable {
    /// Original template (e.g., "/users/{id}")
    public let template: String

    /// Pattern segments
    private let segments: [Segment]

    /// Specificity score (higher = more specific)
    public let specificity: Int

    /// Initialize from a path template
    public init(template: String) {
        self.template = template
        self.segments = Self.parseTemplate(template)
        self.specificity = Self.calculateSpecificity(segments)
    }

    /// Parse template into segments
    private static func parseTemplate(_ template: String) -> [Segment] {
        let path = template.hasPrefix("/") ? String(template.dropFirst()) : template
        guard !path.isEmpty else { return [] }

        return path.split(separator: "/", omittingEmptySubsequences: false).map { part in
            let str = String(part)
            if str.hasPrefix("{") && str.hasSuffix("}") {
                let paramName = String(str.dropFirst().dropLast())
                return .parameter(paramName)
            } else {
                return .literal(str)
            }
        }
    }

    /// Calculate specificity (more literals = more specific)
    private static func calculateSpecificity(_ segments: [Segment]) -> Int {
        var score = segments.count * 10
        for segment in segments {
            if case .literal = segment {
                score += 5
            }
        }
        return score
    }

    /// Match a path and extract parameters
    /// - Parameter path: Path to match (e.g., "/users/123")
    /// - Returns: Extracted parameters if matched, nil otherwise
    public func match(_ path: String) -> [String: String]? {
        let normalizedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path

        // Handle root path "/" -> empty normalizedPath matches empty segments
        if normalizedPath.isEmpty {
            return segments.isEmpty ? [:] : nil
        }

        let pathParts = normalizedPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)

        guard pathParts.count == segments.count else {
            return nil
        }

        var params: [String: String] = [:]

        for (segment, part) in zip(segments, pathParts) {
            switch segment {
            case .literal(let expected):
                guard part == expected else { return nil }
            case .parameter(let name):
                params[name] = part
            }
        }

        return params
    }

    /// Segment types
    private enum Segment: Sendable {
        case literal(String)
        case parameter(String)
    }
}

// MARK: - Debug Extensions

extension OpenAPIRouteRegistry: CustomStringConvertible {
    public var description: String {
        var lines = ["OpenAPI Route Registry:"]
        for route in routes {
            lines.append("  \(route.method) \(route.pattern.template) -> \(route.operationId)")
        }
        return lines.joined(separator: "\n")
    }
}

extension RouteMatch: CustomStringConvertible {
    public var description: String {
        var result = "RouteMatch(operationId: \(operationId)"
        if !pathParameters.isEmpty {
            result += ", params: \(pathParameters)"
        }
        result += ")"
        return result
    }
}
