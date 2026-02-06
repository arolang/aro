// ============================================================
// SchemaRegistry.swift
// ARO Runtime - OpenAPI Schema Registry for Typed Event Extraction
// ============================================================

import Foundation

/// Protocol for accessing OpenAPI schemas at runtime
///
/// The schema registry enables typed event extraction by providing
/// access to schema definitions from `components.schemas` in the
/// OpenAPI specification.
///
/// Usage in ARO:
/// ```aro
/// <Extract> the <event-data: ExtractLinksEvent> from the <event: data>.
/// ```
///
/// The PascalCase qualifier `ExtractLinksEvent` triggers a schema lookup.
public protocol SchemaRegistry: Sendable {
    /// Look up a schema by name
    /// - Parameter name: The schema name (e.g., "ExtractLinksEvent")
    /// - Returns: The schema if found, nil otherwise
    func schema(named name: String) -> Schema?

    /// Check if a schema exists
    /// - Parameter name: The schema name to check
    /// - Returns: true if the schema is defined
    func hasSchema(named name: String) -> Bool

    /// Get all available schema names
    var schemaNames: [String] { get }

    /// Get the components for reference resolution
    var components: Components? { get }
}

/// Concrete implementation backed by an OpenAPI specification
public struct OpenAPISchemaRegistry: SchemaRegistry {
    private let spec: OpenAPISpec

    public init(spec: OpenAPISpec) {
        self.spec = spec
    }

    public func schema(named name: String) -> Schema? {
        spec.components?.schemas?[name]?.value
    }

    public func hasSchema(named name: String) -> Bool {
        spec.components?.schemas?[name] != nil
    }

    public var schemaNames: [String] {
        guard let schemas = spec.components?.schemas else { return [] }
        return Array(schemas.keys).sorted()
    }

    public var components: Components? {
        spec.components
    }
}
