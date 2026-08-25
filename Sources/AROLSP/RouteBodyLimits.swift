// ============================================================
// RouteBodyLimits.swift
// AROLSP - Per-route body limits from the contract (GitLab #477)
// ============================================================
//
// The editor needs the same two facts the server uses: which route
// a feature set handles, and what that route's `x-aro-max-body`
// says. Both live in `openapi.yaml`, which the language server
// already knows how to find — so the inlay hint can name the real
// number rather than a generic one.

#if !os(Windows)
import Foundation
import ARORuntime

/// `operationId` → the route it serves and the body limit declared for it.
public struct RouteBodyLimits: Sendable {

    /// What applies to one route.
    public struct Limit: Sendable, Equatable {
        /// The ceiling in bytes.
        public let bytes: Int
        /// Whether the contract said so, or this is the runtime default.
        public let declared: Bool

        /// `256KB`, for a label that has to stay short.
        public var shortLabel: String { ByteSize.describe(bytes) }

        /// `256KB (x-aro-max-body)` or `1MB (the default)`, for a tooltip that
        /// has room to say where the number came from.
        public var description: String {
            declared ? "\(shortLabel) (x-aro-max-body)" : "\(shortLabel) (the default)"
        }
    }

    private let routes: [String: String]
    private let limits: [String: Limit]

    public static let empty = RouteBodyLimits(routes: [:], limits: [:])

    private init(routes: [String: String], limits: [String: Limit]) {
        self.routes = routes
        self.limits = limits
    }

    public func route(forOperation operationId: String) -> String? {
        routes[operationId]
    }

    public func limit(forOperation operationId: String) -> Limit {
        limits[operationId]
            ?? Limit(bytes: RuntimeDefaults.maxMaterializedBody, declared: false)
    }

    /// Read the contract nearest to `file`, walking up to `roots`.
    ///
    /// Walking up rather than assuming a layout: a feature set may live in
    /// `sources/users/users.aro` while the contract sits at the application
    /// root, which is the convention the loader documents.
    public static func load(near file: URL?, roots: [URL]) -> RouteBodyLimits {
        var candidates: [URL] = []

        if let file {
            var directory = file.deletingLastPathComponent()
            // Bounded walk: deep enough for `sources/a/b/c`, short enough not
            // to wander out of the project on a stray URL.
            for _ in 0..<6 {
                candidates.append(directory)
                let parent = directory.deletingLastPathComponent()
                if parent.path == directory.path { break }
                directory = parent
            }
        }
        candidates.append(contentsOf: roots)

        for directory in candidates {
            for name in ["openapi.yaml", "openapi.yml", "openapi.json"] {
                let path = directory.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: path.path) else { continue }
                guard let spec = try? OpenAPILoader.load(from: path) else { continue }
                return from(spec: spec)
            }
        }

        return .empty
    }

    static func from(spec: OpenAPISpec) -> RouteBodyLimits {
        var routes: [String: String] = [:]
        var limits: [String: Limit] = [:]

        for (path, item) in spec.paths {
            for (method, operation) in item.allOperations {
                guard let operationId = operation.operationId else { continue }
                routes[operationId] = "\(method.uppercased()) \(path)"
                if let bytes = operation.maxBodyBytes {
                    limits[operationId] = Limit(bytes: bytes, declared: true)
                }
            }
        }

        return RouteBodyLimits(routes: routes, limits: limits)
    }
}

#endif
