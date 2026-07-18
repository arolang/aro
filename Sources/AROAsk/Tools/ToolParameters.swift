// ============================================================
// ToolParameters.swift
// AROAsk - single source of truth for tool parameter schemas
// ============================================================
//
// Each built-in tool declares its parameters exactly once as a
// `ToolParameterSchema`. Both the JSON schema sent to the language
// model (`jsonSchema`) and the runtime argument decoding
// (`ToolArguments`) are derived from that one declaration, so a
// parameter change can never leave schema and decoder out of sync
// (#357).

import Foundation

/// A single tool parameter: name, JSON type, human description, and
/// whether the model must supply it.
public struct ToolParameter: Sendable, Equatable {

    /// JSON-schema type of a parameter.
    public indirect enum ParameterType: Sendable, Equatable {
        case string
        case integer
        case number
        case boolean
        /// Homogeneous array, e.g. `.array(of: .string)`.
        case array(of: ParameterType)
        /// Nested object with named properties.
        case object([ToolParameter])
        /// String restricted to a fixed set of values.
        case enumeration([String])

        /// The bare JSON-schema fragment for this type (no description).
        var schemaFields: [String: JSONValue] {
            switch self {
            case .string:
                return ["type": .string("string")]
            case .integer:
                return ["type": .string("integer")]
            case .number:
                return ["type": .string("number")]
            case .boolean:
                return ["type": .string("boolean")]
            case .array(let element):
                return [
                    "type": .string("array"),
                    "items": .object(element.schemaFields),
                ]
            case .object(let properties):
                var props: [String: JSONValue] = [:]
                for p in properties { props[p.name] = p.propertySchema }
                var fields: [String: JSONValue] = [
                    "type": .string("object"),
                    "properties": .object(props),
                ]
                // Nested objects only carry `required` when a nested
                // field actually is required — matches the schema shape
                // the LLM received before #357.
                let required = properties.filter(\.isRequired).map { JSONValue.string($0.name) }
                if !required.isEmpty {
                    fields["required"] = .array(required)
                }
                return fields
            case .enumeration(let values):
                return [
                    "type": .string("string"),
                    "enum": .array(values.map { .string($0) }),
                ]
            }
        }
    }

    public let name: String
    public let type: ParameterType
    public let description: String?
    public let isRequired: Bool

    public init(name: String, type: ParameterType, description: String? = nil, isRequired: Bool) {
        self.name = name
        self.type = type
        self.description = description
        self.isRequired = isRequired
    }

    /// A parameter the model must supply.
    public static func required(_ name: String, _ type: ParameterType, _ description: String? = nil) -> ToolParameter {
        ToolParameter(name: name, type: type, description: description, isRequired: true)
    }

    /// A parameter the model may omit.
    public static func optional(_ name: String, _ type: ParameterType, _ description: String? = nil) -> ToolParameter {
        ToolParameter(name: name, type: type, description: description, isRequired: false)
    }

    /// JSON-schema fragment for this parameter inside `properties`.
    var propertySchema: JSONValue {
        var fields = type.schemaFields
        if let description {
            fields["description"] = .string(description)
        }
        return .object(fields)
    }
}

/// Ordered parameter declaration for one tool. Derives the
/// `function.parameters` JSON schema and drives runtime decoding.
public struct ToolParameterSchema: Sendable, Equatable {
    public let parameters: [ToolParameter]

    public init(_ parameters: [ToolParameter]) {
        self.parameters = parameters
    }

    /// Schema for a tool that takes no arguments.
    public static let empty = ToolParameterSchema([])

    /// The JSON schema sent to the language model. Shape matches the
    /// previously hand-written trees: `required` is present (possibly
    /// empty) whenever the tool has properties, and omitted for
    /// zero-parameter tools.
    public var jsonSchema: JSONValue {
        var props: [String: JSONValue] = [:]
        for p in parameters { props[p.name] = p.propertySchema }
        var fields: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object(props),
        ]
        if !parameters.isEmpty {
            fields["required"] = .array(
                parameters.filter(\.isRequired).map { .string($0.name) }
            )
        }
        return .object(fields)
    }
}

/// Decoded tool-call arguments, validated against the same
/// `ToolParameterSchema` the LLM-facing schema was generated from.
/// Required parameters are checked once at construction; accessors
/// throw a uniform `AskToolError.invalidArguments` on type mismatch.
public struct ToolArguments: Sendable {
    private let values: [String: JSONValue]

    /// Validates that every schema-required parameter is present
    /// (and non-null). Throws `AskToolError.invalidArguments` naming
    /// the first missing parameter.
    public init(raw: JSONValue, schema: ToolParameterSchema) throws {
        let object = raw.objectValue ?? [:]
        for parameter in schema.parameters where parameter.isRequired {
            guard let value = object[parameter.name], value != .null else {
                throw AskToolError.invalidArguments("missing required parameter '\(parameter.name)'")
            }
        }
        self.values = object
    }

    /// Raw access for advanced cases (nested structures).
    public subscript(name: String) -> JSONValue? {
        values[name]
    }

    // MARK: - Optional accessors

    public func string(_ name: String) -> String? {
        values[name]?.stringValue
    }

    public func int(_ name: String) -> Int? {
        values[name]?.intValue
    }

    public func bool(_ name: String) -> Bool? {
        values[name]?.boolValue
    }

    public func array(_ name: String) -> [JSONValue]? {
        values[name]?.arrayValue
    }

    public func stringArray(_ name: String) -> [String]? {
        values[name]?.arrayValue?.compactMap(\.stringValue)
    }

    // MARK: - Required accessors

    public func requireString(_ name: String) throws -> String {
        guard let value = string(name) else {
            throw AskToolError.invalidArguments("'\(name)' (string) is required")
        }
        return value
    }

    public func requireArray(_ name: String) throws -> [JSONValue] {
        guard let value = array(name) else {
            throw AskToolError.invalidArguments("'\(name)' (array) is required")
        }
        return value
    }
}
