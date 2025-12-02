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
