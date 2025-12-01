// ============================================================
// OpenAPISpec.swift
// ARO Runtime - OpenAPI Data Structures
// ============================================================

import Foundation

/// OpenAPI 3.0 Specification
public struct OpenAPISpec: Sendable, Codable {
    public let openapi: String
    public let info: OpenAPIInfo
    public let paths: [String: PathItem]
    public let components: Components?
    public let servers: [Server]?
}

// MARK: - Info

public struct OpenAPIInfo: Sendable, Codable {
    public let title: String
    public let version: String
    public let description: String?
}

// MARK: - Server

public struct Server: Sendable, Codable {
    public let url: String
    public let description: String?
}

// MARK: - Path Item

public struct PathItem: Sendable, Codable {
    public let get: Operation?
    public let post: Operation?
    public let put: Operation?
    public let patch: Operation?
    public let delete: Operation?
    public let head: Operation?
    public let options: Operation?
    public let trace: Operation?
    public let parameters: [Parameter]?

    public var allOperations: [(method: String, operation: Operation)] {
        var ops: [(String, Operation)] = []
        if let op = get { ops.append(("GET", op)) }
        if let op = post { ops.append(("POST", op)) }
        if let op = put { ops.append(("PUT", op)) }
        if let op = patch { ops.append(("PATCH", op)) }
        if let op = delete { ops.append(("DELETE", op)) }
        if let op = head { ops.append(("HEAD", op)) }
        if let op = options { ops.append(("OPTIONS", op)) }
        if let op = trace { ops.append(("TRACE", op)) }
        return ops
    }
}

// MARK: - Operation

public struct Operation: Sendable, Codable {
    public let operationId: String?
    public let summary: String?
    public let description: String?
    public let tags: [String]?
    public let parameters: [Parameter]?
    public let requestBody: RequestBody?
    public let responses: [String: OpenAPIResponse]
    public let deprecated: Bool?
    public let security: [[String: [String]]]?
}

// MARK: - Parameter

public struct Parameter: Sendable, Codable {
    public let name: String
    public let `in`: String
    public let required: Bool?
    public let description: String?
    public let schema: SchemaRef?
    public let allowEmptyValue: Bool?
    public let ref: String?

    private enum CodingKeys: String, CodingKey {
        case name, `in`, required, description, schema, allowEmptyValue
        case ref = "$ref"
    }
}

// MARK: - Request Body

public struct RequestBody: Sendable, Codable {
    public let description: String?
    public let required: Bool?
    public let content: [String: MediaType]
    public let ref: String?

    private enum CodingKeys: String, CodingKey {
        case description, required, content
        case ref = "$ref"
    }
}

// MARK: - Response

public struct OpenAPIResponse: Sendable, Codable {
    public let description: String
    public let headers: [String: Header]?
    public let content: [String: MediaType]?
    public let ref: String?

    private enum CodingKeys: String, CodingKey {
        case description, headers, content
        case ref = "$ref"
    }
}

// MARK: - Media Type

public struct MediaType: Sendable, Codable {
    public let schema: SchemaRef?
}

// MARK: - Header

public struct Header: Sendable, Codable {
    public let description: String?
    public let required: Bool?
    public let schema: SchemaRef?
}

// MARK: - Schema (using class for reference semantics to handle recursion)

public final class Schema: Sendable, Codable {
    public let type: String?
    public let format: String?
    public let title: String?
    public let description: String?
    public let properties: [String: SchemaRef]?
    public let required: [String]?
    public let items: SchemaRef?
    public let nullable: Bool?
    public let ref: String?
    public let minimum: Double?
    public let maximum: Double?
    public let minLength: Int?
    public let maxLength: Int?
    public let pattern: String?
    public let minItems: Int?
    public let maxItems: Int?
    public let allOf: [SchemaRef]?
    public let oneOf: [SchemaRef]?
    public let anyOf: [SchemaRef]?

    private enum CodingKeys: String, CodingKey {
        case type, format, title, description, properties, required
        case items, nullable, minimum, maximum
        case minLength, maxLength, pattern, minItems, maxItems
        case allOf, oneOf, anyOf
        case ref = "$ref"
    }

    public init(
        type: String? = nil,
        format: String? = nil,
        title: String? = nil,
        description: String? = nil,
        properties: [String: SchemaRef]? = nil,
        required: [String]? = nil,
        items: SchemaRef? = nil,
        nullable: Bool? = nil,
        ref: String? = nil,
        minimum: Double? = nil,
        maximum: Double? = nil,
        minLength: Int? = nil,
        maxLength: Int? = nil,
        pattern: String? = nil,
        minItems: Int? = nil,
        maxItems: Int? = nil,
        allOf: [SchemaRef]? = nil,
        oneOf: [SchemaRef]? = nil,
        anyOf: [SchemaRef]? = nil
    ) {
        self.type = type
        self.format = format
        self.title = title
        self.description = description
        self.properties = properties
        self.required = required
        self.items = items
        self.nullable = nullable
        self.ref = ref
        self.minimum = minimum
        self.maximum = maximum
        self.minLength = minLength
        self.maxLength = maxLength
        self.pattern = pattern
        self.minItems = minItems
        self.maxItems = maxItems
        self.allOf = allOf
        self.oneOf = oneOf
        self.anyOf = anyOf
    }
}

/// Reference wrapper for Schema to allow recursive structures
public final class SchemaRef: Sendable, Codable {
    public let value: Schema

    public init(_ value: Schema) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        self.value = try Schema(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        try value.encode(to: encoder)
    }
}

// MARK: - Components

public struct Components: Sendable, Codable {
    public let schemas: [String: SchemaRef]?
    public let responses: [String: OpenAPIResponse]?
    public let parameters: [String: Parameter]?
    public let requestBodies: [String: RequestBody]?
    public let headers: [String: Header]?
    public let securitySchemes: [String: SecurityScheme]?
}

// MARK: - Security Scheme

public struct SecurityScheme: Sendable, Codable {
    public let type: String
    public let description: String?
    public let name: String?
    public let `in`: String?
    public let scheme: String?
    public let bearerFormat: String?
}

// MARK: - HTTP Method

public enum OpenAPIMethod: String, Sendable, CaseIterable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
    case head = "HEAD"
    case options = "OPTIONS"
    case trace = "TRACE"
}
