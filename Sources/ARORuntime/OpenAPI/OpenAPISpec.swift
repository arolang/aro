// ============================================================
// OpenAPISpec.swift
// ARO Runtime - OpenAPI Data Structures
// ============================================================

import Foundation

/// OpenAPI 3.0 / 3.1 Specification
public struct OpenAPISpec: Sendable, Codable {
    public let openapi: String
    public let info: OpenAPIInfo
    public let paths: [String: PathItem]
    public let components: Components?
    public let servers: [Server]?
    public let security: [[String: [String]]]?
    /// OpenAPI 3.1: top-level webhooks (same structure as paths)
    public let webhooks: [String: PathItem]?
    /// OpenAPI 3.1: JSON Schema dialect URI
    public let jsonSchemaDialect: String?

    /// Returns true when this is an OpenAPI 3.1.x specification
    public var is31: Bool { openapi.hasPrefix("3.1") }

    public init(
        openapi: String,
        info: OpenAPIInfo,
        paths: [String: PathItem],
        components: Components? = nil,
        servers: [Server]? = nil,
        security: [[String: [String]]]? = nil,
        webhooks: [String: PathItem]? = nil,
        jsonSchemaDialect: String? = nil
    ) {
        self.openapi = openapi
        self.info = info
        self.paths = paths
        self.components = components
        self.servers = servers
        self.security = security
        self.webhooks = webhooks
        self.jsonSchemaDialect = jsonSchemaDialect
    }
}

// MARK: - Info

/// OpenAPI License object
public struct OpenAPILicense: Sendable, Codable {
    public let name: String?
    /// SPDX license identifier (OpenAPI 3.1)
    public let identifier: String?
    public let url: String?
}

public struct OpenAPIInfo: Sendable, Codable {
    public let title: String
    public let version: String
    public let description: String?
    /// Short summary of the API (OpenAPI 3.1)
    public let summary: String?
    /// License information
    public let license: OpenAPILicense?

    public init(
        title: String,
        version: String,
        description: String? = nil,
        summary: String? = nil,
        license: OpenAPILicense? = nil
    ) {
        self.title = title
        self.version = version
        self.description = description
        self.summary = summary
        self.license = license
    }
}

// MARK: - Server Variable

public struct ServerVariable: Sendable, Codable {
    public let `default`: String
    public let `enum`: [String]?
    public let description: String?
}

// MARK: - Server

public struct Server: Sendable, Codable {
    public let url: String
    public let description: String?
    public let variables: [String: ServerVariable]?

    /// Returns the URL with all variable placeholders replaced by their default values
    public var resolvedURL: String {
        guard let variables = variables else { return url }
        var resolved = url
        for (name, variable) in variables {
            resolved = resolved.replacingOccurrences(of: "{\(name)}", with: variable.default)
        }
        return resolved
    }
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
    public let deprecated: Bool?
    public let ref: String?
    /// Serialization style for the parameter value (OpenAPI `style` keyword).
    ///
    /// Common values: `"form"` (default for query/cookie), `"simple"` (default for path/header),
    /// `"spaceDelimited"`, `"pipeDelimited"`, `"deepObject"`.
    public let style: String?
    /// Whether array/object values are serialized using exploded form (OpenAPI `explode` keyword).
    ///
    /// Defaults to `true` when `style == "form"`, `false` otherwise.
    public let explode: Bool?

    private enum CodingKeys: String, CodingKey {
        case name, `in`, required, description, schema, allowEmptyValue, deprecated, style, explode
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

// MARK: - AnyCodableValue

/// A JSON-typed value used for OpenAPI `enum` constraints.
///
/// Supports all JSON scalar types: string, integer, number, boolean, and null.
public enum AnyCodableValue: Sendable, Codable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let b = try? container.decode(Bool.self) { self = .bool(b); return }
        if let i = try? container.decode(Int.self) { self = .int(i); return }
        if let d = try? container.decode(Double.self) { self = .double(d); return }
        if let s = try? container.decode(String.self) { self = .string(s); return }
        throw DecodingError.typeMismatch(
            AnyCodableValue.self,
            .init(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON type for enum value")
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .bool(let b): try container.encode(b)
        case .null: try container.encodeNil()
        }
    }

    /// The underlying value as `Any`, suitable for display or comparison.
    public var anyValue: Any {
        switch self {
        case .string(let s): return s
        case .int(let i): return i
        case .double(let d): return d
        case .bool(let b): return b
        case .null: return NSNull()
        }
    }
}

// MARK: - Discriminator

/// OpenAPI `discriminator` object for polymorphic schemas.
///
/// When a `oneOf` or `anyOf` schema includes a discriminator, the runtime
/// uses the value of `propertyName` in the incoming payload to select the
/// correct sub-schema directly, avoiding the need to try every alternative.
///
/// ```yaml
/// discriminator:
///   propertyName: type
///   mapping:
///     cat: "#/components/schemas/Cat"
///     dog: "#/components/schemas/Dog"
/// ```
public struct Discriminator: Sendable, Codable {
    /// The name of the property in the payload whose value identifies the sub-schema.
    public let propertyName: String
    /// Optional explicit mapping from discriminator values to `$ref` strings.
    /// When absent, the convention `#/components/schemas/{value}` is used.
    public let mapping: [String: String]?
}

// MARK: - AdditionalProperties

/// Represents the OpenAPI `additionalProperties` keyword.
///
/// Can be either a boolean (allow/deny extra properties) or a Schema
/// that extra properties must conform to.
public enum AdditionalProperties: Sendable, Codable {
    case allowed(Bool)
    case schema(SchemaRef)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let boolVal = try? container.decode(Bool.self) {
            self = .allowed(boolVal)
        } else {
            let schemaRef = try container.decode(SchemaRef.self)
            self = .schema(schemaRef)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .allowed(let b): try container.encode(b)
        case .schema(let s): try s.encode(to: encoder)
        }
    }
}

// MARK: - Schema (using class for reference semantics to handle recursion)

public final class Schema: Sendable, Codable {
    /// Unified type array. In OpenAPI 3.0 `type` is a single string; in 3.1 it may be
    /// a string or an array like `["string", "null"]`. Both are normalised to `[String]`.
    public let types: [String]

    /// Convenience: the primary (non-null) type, or nil when no type is specified.
    public var type: String? { types.first(where: { $0 != "null" }) ?? types.first }

    /// True when the schema allows null values:
    /// - OpenAPI 3.0.x: `nullable: true`
    /// - OpenAPI 3.1: `"null"` in the `type` array
    public var isNullable: Bool { types.contains("null") || nullable == true }

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
    public let not: SchemaRef?
    public let enumValues: [AnyCodableValue]?
    public let defaultValue: AnyCodableValue?
    public let additionalProperties: AdditionalProperties?
    public let discriminator: Discriminator?
    /// Constant value constraint (OpenAPI 3.1 / JSON Schema `const`)
    public let const: AnyCodableValue?
    /// exclusiveMinimum as a boolean (OpenAPI 3.0.x)
    public let exclusiveMinimumBool: Bool?
    /// exclusiveMinimum as a numeric value (OpenAPI 3.1)
    public let exclusiveMinimumValue: Double?
    /// exclusiveMaximum as a boolean (OpenAPI 3.0.x)
    public let exclusiveMaximumBool: Bool?
    /// exclusiveMaximum as a numeric value (OpenAPI 3.1)
    public let exclusiveMaximumValue: Double?

    private enum CodingKeys: String, CodingKey {
        case type, format, title, description, properties, required
        case items, nullable, minimum, maximum
        case minLength, maxLength, pattern, minItems, maxItems
        case allOf, oneOf, anyOf, not
        case ref = "$ref"
        case enumValues = "enum"
        case defaultValue = "default"
        case additionalProperties
        case discriminator
        case const
        case exclusiveMinimum
        case exclusiveMaximum
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Decode `type` — may be a String (3.0) or [String] (3.1)
        if let singleType = try? container.decode(String.self, forKey: .type) {
            types = [singleType]
        } else if let typeArray = try? container.decode([String].self, forKey: .type) {
            types = typeArray
        } else {
            types = []
        }

        format = try container.decodeIfPresent(String.self, forKey: .format)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        properties = try container.decodeIfPresent([String: SchemaRef].self, forKey: .properties)
        required = try container.decodeIfPresent([String].self, forKey: .required)
        items = try container.decodeIfPresent(SchemaRef.self, forKey: .items)
        nullable = try container.decodeIfPresent(Bool.self, forKey: .nullable)
        ref = try container.decodeIfPresent(String.self, forKey: .ref)
        minimum = try container.decodeIfPresent(Double.self, forKey: .minimum)
        maximum = try container.decodeIfPresent(Double.self, forKey: .maximum)
        minLength = try container.decodeIfPresent(Int.self, forKey: .minLength)
        maxLength = try container.decodeIfPresent(Int.self, forKey: .maxLength)
        pattern = try container.decodeIfPresent(String.self, forKey: .pattern)
        minItems = try container.decodeIfPresent(Int.self, forKey: .minItems)
        maxItems = try container.decodeIfPresent(Int.self, forKey: .maxItems)
        allOf = try container.decodeIfPresent([SchemaRef].self, forKey: .allOf)
        oneOf = try container.decodeIfPresent([SchemaRef].self, forKey: .oneOf)
        anyOf = try container.decodeIfPresent([SchemaRef].self, forKey: .anyOf)
        not = try container.decodeIfPresent(SchemaRef.self, forKey: .not)
        enumValues = try container.decodeIfPresent([AnyCodableValue].self, forKey: .enumValues)
        defaultValue = try container.decodeIfPresent(AnyCodableValue.self, forKey: .defaultValue)
        additionalProperties = try container.decodeIfPresent(AdditionalProperties.self, forKey: .additionalProperties)
        discriminator = try container.decodeIfPresent(Discriminator.self, forKey: .discriminator)
        const = try container.decodeIfPresent(AnyCodableValue.self, forKey: .const)

        // exclusiveMinimum: Bool (3.0.x) or Double (3.1)
        if let boolVal = try? container.decode(Bool.self, forKey: .exclusiveMinimum) {
            exclusiveMinimumBool = boolVal
            exclusiveMinimumValue = nil
        } else if let numVal = try? container.decode(Double.self, forKey: .exclusiveMinimum) {
            exclusiveMinimumBool = nil
            exclusiveMinimumValue = numVal
        } else {
            exclusiveMinimumBool = nil
            exclusiveMinimumValue = nil
        }

        // exclusiveMaximum: Bool (3.0.x) or Double (3.1)
        if let boolVal = try? container.decode(Bool.self, forKey: .exclusiveMaximum) {
            exclusiveMaximumBool = boolVal
            exclusiveMaximumValue = nil
        } else if let numVal = try? container.decode(Double.self, forKey: .exclusiveMaximum) {
            exclusiveMaximumBool = nil
            exclusiveMaximumValue = numVal
        } else {
            exclusiveMaximumBool = nil
            exclusiveMaximumValue = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        // Encode types: single string when only one non-null type, array otherwise
        if types.count == 1 {
            try container.encode(types[0], forKey: .type)
        } else if !types.isEmpty {
            try container.encode(types, forKey: .type)
        }

        try container.encodeIfPresent(format, forKey: .format)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(properties, forKey: .properties)
        try container.encodeIfPresent(required, forKey: .required)
        try container.encodeIfPresent(items, forKey: .items)
        try container.encodeIfPresent(nullable, forKey: .nullable)
        try container.encodeIfPresent(ref, forKey: .ref)
        try container.encodeIfPresent(minimum, forKey: .minimum)
        try container.encodeIfPresent(maximum, forKey: .maximum)
        try container.encodeIfPresent(minLength, forKey: .minLength)
        try container.encodeIfPresent(maxLength, forKey: .maxLength)
        try container.encodeIfPresent(pattern, forKey: .pattern)
        try container.encodeIfPresent(minItems, forKey: .minItems)
        try container.encodeIfPresent(maxItems, forKey: .maxItems)
        try container.encodeIfPresent(allOf, forKey: .allOf)
        try container.encodeIfPresent(oneOf, forKey: .oneOf)
        try container.encodeIfPresent(anyOf, forKey: .anyOf)
        try container.encodeIfPresent(not, forKey: .not)
        try container.encodeIfPresent(enumValues, forKey: .enumValues)
        try container.encodeIfPresent(defaultValue, forKey: .defaultValue)
        try container.encodeIfPresent(additionalProperties, forKey: .additionalProperties)
        try container.encodeIfPresent(discriminator, forKey: .discriminator)
        try container.encodeIfPresent(const, forKey: .const)
        if let b = exclusiveMinimumBool { try container.encode(b, forKey: .exclusiveMinimum) }
        else if let v = exclusiveMinimumValue { try container.encode(v, forKey: .exclusiveMinimum) }
        if let b = exclusiveMaximumBool { try container.encode(b, forKey: .exclusiveMaximum) }
        else if let v = exclusiveMaximumValue { try container.encode(v, forKey: .exclusiveMaximum) }
    }

    public init(
        type: String? = nil,
        types: [String]? = nil,
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
        anyOf: [SchemaRef]? = nil,
        not: SchemaRef? = nil,
        enumValues: [AnyCodableValue]? = nil,
        defaultValue: AnyCodableValue? = nil,
        additionalProperties: AdditionalProperties? = nil,
        discriminator: Discriminator? = nil,
        const: AnyCodableValue? = nil,
        exclusiveMinimumBool: Bool? = nil,
        exclusiveMinimumValue: Double? = nil,
        exclusiveMaximumBool: Bool? = nil,
        exclusiveMaximumValue: Double? = nil
    ) {
        // Resolve types: explicit types array wins, else derive from type string
        if let t = types {
            self.types = t
        } else if let t = type {
            self.types = [t]
        } else {
            self.types = []
        }
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
        self.not = not
        self.enumValues = enumValues
        self.defaultValue = defaultValue
        self.additionalProperties = additionalProperties
        self.discriminator = discriminator
        self.const = const
        self.exclusiveMinimumBool = exclusiveMinimumBool
        self.exclusiveMinimumValue = exclusiveMinimumValue
        self.exclusiveMaximumBool = exclusiveMaximumBool
        self.exclusiveMaximumValue = exclusiveMaximumValue
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
