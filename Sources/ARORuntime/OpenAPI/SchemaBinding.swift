// ============================================================
// SchemaBinding.swift
// ARO Runtime - OpenAPI Schema to ExecutionContext Binding
// ============================================================

import Foundation

/// Binds OpenAPI schemas to execution context values
public struct SchemaBinding {
    /// Bind request body to context using schema definitions
    public static func parseRequestBody(
        body: Data,
        schema: Schema,
        components: Components?
    ) throws -> Any {
        let json = try JSONSerialization.jsonObject(with: body)
        return try parseValue(json: json, schema: schema, components: components)
    }

    /// Parse a JSON value according to an OpenAPI schema
    public static func parseValue(
        json: Any,
        schema: Schema,
        components: Components?
    ) throws -> Any {
        // Handle $ref
        if let ref = schema.ref {
            guard let resolved = resolveRef(ref, components: components) else {
                throw SchemaBindingError.invalidReference(ref)
            }
            return try parseValue(json: json, schema: resolved, components: components)
        }

        // Handle by type
        guard let schemaType = schema.type else {
            return json
        }

        switch schemaType {
        case "string":
            guard let str = json as? String else {
                throw SchemaBindingError.typeMismatch(expected: "string")
            }
            return str

        case "number", "integer":
            if let intVal = json as? Int {
                return Double(intVal)
            } else if let doubleVal = json as? Double {
                return doubleVal
            }
            throw SchemaBindingError.typeMismatch(expected: "number")

        case "boolean":
            guard let boolVal = json as? Bool else {
                throw SchemaBindingError.typeMismatch(expected: "boolean")
            }
            return boolVal

        case "array":
            guard let arr = json as? [Any] else {
                throw SchemaBindingError.typeMismatch(expected: "array")
            }
            if let itemSchema = schema.items?.value {
                return try arr.map { try parseValue(json: $0, schema: itemSchema, components: components) }
            }
            return arr

        case "object":
            guard let dict = json as? [String: Any] else {
                throw SchemaBindingError.typeMismatch(expected: "object")
            }

            // Validate required properties
            if let required = schema.required {
                for key in required {
                    if dict[key] == nil {
                        throw SchemaBindingError.missingRequired(key)
                    }
                }
            }

            // Parse properties
            guard let properties = schema.properties else {
                return dict
            }

            var result: [String: Any] = [:]
            for (key, value) in dict {
                if let propSchemaRef = properties[key] {
                    result[key] = try parseValue(json: value, schema: propSchemaRef.value, components: components)
                } else {
                    result[key] = value
                }
            }
            return result

        default:
            return json
        }
    }

    /// Resolve a $ref to a schema
    private static func resolveRef(_ ref: String, components: Components?) -> Schema? {
        let parts = ref.split(separator: "/")
        guard parts.count == 4,
              parts[0] == "#",
              parts[1] == "components",
              parts[2] == "schemas" else {
            return nil
        }
        let schemaName = String(parts[3])
        return components?.schemas?[schemaName]?.value
    }
}

// MARK: - Errors

/// Errors that can occur during schema binding
public enum SchemaBindingError: Error, Sendable {
    case typeMismatch(expected: String)
    case missingRequired(String)
    case invalidReference(String)
    case invalidJSON
}

extension SchemaBindingError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .typeMismatch(let expected):
            return "Type mismatch: expected \(expected)"
        case .missingRequired(let name):
            return "Missing required property: \(name)"
        case .invalidReference(let ref):
            return "Invalid schema reference: \(ref)"
        case .invalidJSON:
            return "Invalid JSON data"
        }
    }
}

// MARK: - Schema Validation Error (ARO-0046)

/// Errors for typed event extraction schema validation
///
/// These errors provide detailed context following ARO-0006 "Code Is The Error Message".
public enum SchemaValidationError: Error, Sendable {
    /// Schema not found in components.schemas
    case schemaNotFound(schemaName: String, availableSchemas: [String])

    /// Root type mismatch (expected object, got array, etc.)
    case typeMismatch(schemaName: String, expected: String, actual: String)

    /// Missing required property in object
    case missingRequiredProperty(schemaName: String, property: String, requiredProperties: [String])

    /// Property type doesn't match schema definition
    case invalidPropertyType(schemaName: String, property: String, expected: String, actual: String)

    /// Schema reference cannot be resolved
    case invalidSchemaReference(schemaName: String, ref: String)
}

extension SchemaValidationError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .schemaNotFound(let name, let available):
            let availableList = available.isEmpty ? "none" : available.joined(separator: ", ")
            return """
                Schema '\(name)' is not defined in openapi.yaml components.schemas.
                Available schemas: \(availableList)
                """

        case .typeMismatch(let schema, let expected, let actual):
            return """
                Schema '\(schema)' validation failed:
                  Expected \(expected), got \(actual)
                """

        case .missingRequiredProperty(let schema, let prop, let required):
            return """
                Schema '\(schema)' validation failed:
                  Missing required property '\(prop)'
                  Required properties: \(required.joined(separator: ", "))
                """

        case .invalidPropertyType(let schema, let prop, let expected, let actual):
            return """
                Schema '\(schema)' validation failed:
                  Property '\(prop)' expected \(expected), got \(actual)
                """

        case .invalidSchemaReference(let schema, let ref):
            return """
                Schema '\(schema)' validation failed:
                  Invalid reference '\(ref)'
                """
        }
    }
}

// MARK: - Schema Validation for Typed Extraction

extension SchemaBinding {
    /// Validate data against a named schema (ARO-0046)
    ///
    /// Used by ExtractAction when a PascalCase qualifier indicates a schema name.
    /// Validates the extracted data against the schema and returns the validated value.
    ///
    /// - Parameters:
    ///   - value: The value to validate
    ///   - schemaName: The schema name for error messages
    ///   - schema: The schema to validate against
    ///   - components: Components for $ref resolution
    /// - Returns: The validated value (possibly coerced)
    /// - Throws: SchemaValidationError if validation fails
    public static func validateAgainstSchema(
        value: any Sendable,
        schemaName: String,
        schema: Schema,
        components: Components?
    ) throws -> any Sendable {
        // Handle $ref
        if let ref = schema.ref {
            guard let resolved = resolveRef(ref, components: components) else {
                throw SchemaValidationError.invalidSchemaReference(schemaName: schemaName, ref: ref)
            }
            return try validateAgainstSchema(value: value, schemaName: schemaName, schema: resolved, components: components)
        }

        // Determine expected type
        guard let schemaType = schema.type else {
            // No type constraint, accept any value
            return value
        }

        switch schemaType {
        case "string":
            guard let strVal = value as? String else {
                throw SchemaValidationError.typeMismatch(
                    schemaName: schemaName,
                    expected: "string",
                    actual: describeType(of: value)
                )
            }
            return strVal

        case "number", "integer":
            if let intVal = value as? Int {
                return schemaType == "integer" ? intVal : Double(intVal)
            } else if let doubleVal = value as? Double {
                return doubleVal
            }
            throw SchemaValidationError.typeMismatch(
                schemaName: schemaName,
                expected: schemaType,
                actual: describeType(of: value)
            )

        case "boolean":
            guard let boolVal = value as? Bool else {
                throw SchemaValidationError.typeMismatch(
                    schemaName: schemaName,
                    expected: "boolean",
                    actual: describeType(of: value)
                )
            }
            return boolVal

        case "array":
            guard let arr = value as? [any Sendable] else {
                throw SchemaValidationError.typeMismatch(
                    schemaName: schemaName,
                    expected: "array",
                    actual: describeType(of: value)
                )
            }
            // Validate array items if schema defines items
            if let itemSchema = schema.items?.value {
                return try arr.map { item in
                    try validateAgainstSchema(value: item, schemaName: schemaName, schema: itemSchema, components: components)
                }
            }
            return arr

        case "object":
            guard let dict = value as? [String: any Sendable] else {
                throw SchemaValidationError.typeMismatch(
                    schemaName: schemaName,
                    expected: "object",
                    actual: describeType(of: value)
                )
            }

            // Validate required properties
            let requiredProps = schema.required ?? []
            for key in requiredProps {
                if dict[key] == nil {
                    throw SchemaValidationError.missingRequiredProperty(
                        schemaName: schemaName,
                        property: key,
                        requiredProperties: requiredProps
                    )
                }
            }

            // Validate and coerce properties
            guard let properties = schema.properties else {
                return dict
            }

            var result: [String: any Sendable] = [:]
            for (key, val) in dict {
                if let propSchemaRef = properties[key] {
                    do {
                        result[key] = try validateAgainstSchema(
                            value: val,
                            schemaName: schemaName,
                            schema: propSchemaRef.value,
                            components: components
                        )
                    } catch let error as SchemaValidationError {
                        // Re-throw with property context if it's a type mismatch at this level
                        if case .typeMismatch(_, let expected, let actual) = error {
                            throw SchemaValidationError.invalidPropertyType(
                                schemaName: schemaName,
                                property: key,
                                expected: expected,
                                actual: actual
                            )
                        }
                        throw error
                    }
                } else {
                    // Allow additional properties
                    result[key] = val
                }
            }
            return result

        default:
            return value
        }
    }

    /// Describe the runtime type of a value for error messages
    private static func describeType(of value: any Sendable) -> String {
        switch value {
        case is String:
            return "string"
        case is Int:
            return "integer"
        case is Double:
            return "number"
        case is Bool:
            return "boolean"
        case is [any Sendable]:
            return "array"
        case is [String: any Sendable]:
            return "object"
        default:
            return String(describing: type(of: value))
        }
    }
}

// MARK: - Context Binding Helpers

/// Extension to help bind OpenAPI data to execution context
public struct OpenAPIContextBinder {
    /// Bind path parameters to context
    public static func bindPathParameters(_ params: [String: String]) -> [String: Any] {
        var result: [String: Any] = [:]
        result["pathParameters"] = params
        for (key, value) in params {
            result["pathParameters.\(key)"] = value
        }
        return result
    }

    /// Bind query parameters to context
    public static func bindQueryParameters(_ params: [String: String]) -> [String: Any] {
        var result: [String: Any] = [:]
        result["queryParameters"] = params
        for (key, value) in params {
            result["queryParameters.\(key)"] = value
        }
        return result
    }

    /// Bind request body to context
    public static func bindRequestBody(
        _ body: Data?,
        schema: Schema?,
        components: Components?
    ) throws -> [String: Any] {
        var result: [String: Any] = [:]

        guard let body = body else {
            return result
        }

        if let schema = schema {
            let parsed = try SchemaBinding.parseRequestBody(body: body, schema: schema, components: components)
            result["request.body"] = parsed

            if let dict = parsed as? [String: Any] {
                for (key, value) in dict {
                    result["request.body.\(key)"] = value
                }
            }
        } else if let json = try? JSONSerialization.jsonObject(with: body) {
            result["request.body"] = json
        }

        return result
    }
}
