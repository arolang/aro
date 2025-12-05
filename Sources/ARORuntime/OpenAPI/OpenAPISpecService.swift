// ============================================================
// OpenAPISpecService.swift
// ARO Runtime - OpenAPI Specification Service
// ============================================================

import Foundation

/// Service providing access to the OpenAPI specification
///
/// This service is registered when an application has an OpenAPI contract,
/// allowing actions to query configuration from the contract (e.g., server port).
public final class OpenAPISpecService: Sendable {
    /// The OpenAPI specification
    public let spec: OpenAPISpec

    public init(spec: OpenAPISpec) {
        self.spec = spec
    }

    /// Get the server port from the OpenAPI spec
    /// Returns nil if no server URL is defined or port cannot be extracted
    public var serverPort: Int? {
        spec.serverPort
    }

    /// Get the server host from the OpenAPI spec
    public var serverHost: String? {
        spec.serverHost
    }

    /// Get the API title
    public var title: String? {
        spec.info.title
    }

    /// Get the API version
    public var version: String {
        spec.info.version
    }
}
