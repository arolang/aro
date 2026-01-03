// ============================================================
// Contract.swift
// ARO Runtime - Contract Magic System Object
// ============================================================

import Foundation
import AROParser

/// Magic system object representing the OpenAPI contract
///
/// The Contract object provides access to OpenAPI specification metadata
/// at runtime. It is automatically available in any ARO application that
/// has an openapi.yaml file.
///
/// ## Properties
/// - `http-server`: Server configuration from OpenAPI spec
///
/// ## Example
/// ```aro
/// <Start> the <http-server> with <contract>.
/// <Log> <contract.http-server.port> to the <console>.
/// ```
public struct Contract: Sendable {
    /// HTTP server configuration from the OpenAPI contract
    public let httpServer: HTTPServerConfig?

    public init(httpServer: HTTPServerConfig? = nil) {
        self.httpServer = httpServer
    }

    /// Property access for ARO code
    public func property(_ name: String) -> (any Sendable)? {
        switch name {
        case "http-server", "httpServer":
            return httpServer
        default:
            return nil
        }
    }
}

/// HTTP server configuration extracted from OpenAPI specification
public struct HTTPServerConfig: Sendable {
    /// Server port (from OpenAPI servers[0].url or default 8080)
    public let port: Int

    /// Server hostname (from OpenAPI servers[0].url or default "0.0.0.0")
    public let hostname: String

    /// Array of route paths from OpenAPI spec
    public let routes: [String]

    /// Number of routes defined in the OpenAPI spec
    public let routeCount: Int

    public init(
        port: Int = 8080,
        hostname: String = "0.0.0.0",
        routes: [String] = [],
        routeCount: Int = 0
    ) {
        self.port = port
        self.hostname = hostname
        self.routes = routes
        self.routeCount = routeCount
    }

    /// Property access for ARO code
    public func property(_ name: String) -> (any Sendable)? {
        switch name {
        case "port":
            return port
        case "hostname", "host":
            return hostname
        case "routes":
            return routes
        case "routeCount", "route-count":
            return routeCount
        default:
            return nil
        }
    }
}
