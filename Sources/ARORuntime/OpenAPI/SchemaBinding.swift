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
            // No type constraint — still apply composition keywords if present
            if schema.allOf != nil || schema.anyOf != nil || schema.oneOf != nil || schema.not != nil {
                return try validateComposition(json: json, schema: schema, components: components)
            }
            return json
        }

        let parsedValue: Any
        switch schemaType {
        case "string":
            guard let str = json as? String else {
                throw SchemaBindingError.typeMismatch(expected: "string")
            }
            parsedValue = str

        case "number", "integer":
            if let intVal = json as? Int {
                parsedValue = Double(intVal)
            } else if let doubleVal = json as? Double {
                parsedValue = doubleVal
            } else {
                throw SchemaBindingError.typeMismatch(expected: "number")
            }

        case "boolean":
            guard let boolVal = json as? Bool else {
                throw SchemaBindingError.typeMismatch(expected: "boolean")
            }
            parsedValue = boolVal

        case "array":
            guard let arr = json as? [Any] else {
                throw SchemaBindingError.typeMismatch(expected: "array")
            }
            if let itemSchema = schema.items?.value {
                parsedValue = try arr.map { try parseValue(json: $0, schema: itemSchema, components: components) }
            } else {
                parsedValue = arr
            }

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
                parsedValue = dict
                break
            }

            var result: [String: Any] = [:]
            let knownKeys = Set(properties.keys)
            let extraKeys = dict.keys.filter { !knownKeys.contains($0) }

            // Enforce additionalProperties constraint
            switch schema.additionalProperties {
            case .allowed(false):
                if !extraKeys.isEmpty {
                    throw SchemaBindingError.additionalPropertiesNotAllowed(extraKeys.sorted())
                }
            case .schema(let subRef):
                for key in extraKeys {
                    result[key] = try parseValue(json: dict[key]!, schema: subRef.value, components: components)
                }
            case .allowed(true), nil:
                for key in extraKeys { result[key] = dict[key]! }
            }

            for (key, value) in dict {
                if let propSchemaRef = properties[key] {
                    result[key] = try parseValue(json: value, schema: propSchemaRef.value, components: components)
                }
            }

            // Inject default values for missing optional properties
            for (key, propSchemaRef) in properties {
                if result[key] == nil,
                   let defaultVal = propSchemaRef.value.defaultValue {
                    result[key] = defaultVal.anyValue
                }
            }

            parsedValue = result

        default:
            parsedValue = json
        }

        // Validate enum constraint
        if let enumValues = schema.enumValues, !enumValues.isEmpty {
            try validateEnumConstraint(parsedValue, against: enumValues)
        }

        // Apply composition keywords (allOf / anyOf / oneOf / not)
        if schema.allOf != nil || schema.anyOf != nil || schema.oneOf != nil || schema.not != nil {
            return try validateComposition(json: parsedValue, schema: schema, components: components)
        }

        return parsedValue
    }

    /// Validate schema composition keywords: allOf, anyOf, oneOf, not.
    private static func validateComposition(json: Any, schema: Schema, components: Components?) throws -> Any {
        // allOf: must be valid against ALL sub-schemas; results are merged for objects
        if let allOf = schema.allOf, !allOf.isEmpty {
            if var mergedDict = json as? [String: Any] {
                for subRef in allOf {
                    let subResult = try parseValue(json: json, schema: subRef.value, components: components)
                    if let subDict = subResult as? [String: Any] {
                        mergedDict.merge(subDict) { _, new in new }
                    }
                }
                return mergedDict
            } else {
                var merged = json
                for subRef in allOf {
                    merged = try parseValue(json: merged, schema: subRef.value, components: components)
                }
                return merged
            }
        }

        // anyOf: must match at least one sub-schema
        if let anyOf = schema.anyOf, !anyOf.isEmpty {
            for subRef in anyOf {
                if let result = try? parseValue(json: json, schema: subRef.value, components: components) {
                    return result
                }
            }
            throw SchemaBindingError.compositionFailed("anyOf: value does not match any of the listed schemas")
        }

        // oneOf: must match exactly one sub-schema
        if let oneOf = schema.oneOf, !oneOf.isEmpty {
            var results: [Any] = []
            for subRef in oneOf {
                if let result = try? parseValue(json: json, schema: subRef.value, components: components) {
                    results.append(result)
                }
            }
            if results.count == 1 { return results[0] }
            if results.isEmpty {
                throw SchemaBindingError.compositionFailed("oneOf: value does not match any schema")
            }
            throw SchemaBindingError.compositionFailed("oneOf: value matches \(results.count) schemas, expected exactly 1")
        }

        // not: must NOT be valid against the sub-schema
        if let notRef = schema.not {
            if (try? parseValue(json: json, schema: notRef.value, components: components)) != nil {
                throw SchemaBindingError.compositionFailed("not: value must not match the 'not' schema")
            }
        }

        return json
    }

    /// Check that a parsed value matches one of the allowed enum values.
    private static func validateEnumConstraint(_ parsedValue: Any, against enumValues: [AnyCodableValue]) throws {
        let matchesEnum = enumValues.contains { enumVal in
            switch enumVal {
            case .string(let s): return (parsedValue as? String) == s
            case .int(let i): return (parsedValue as? Int) == i || (parsedValue as? Double) == Double(i)
            case .double(let d): return (parsedValue as? Double) == d
            case .bool(let b): return (parsedValue as? Bool) == b
            case .null: return parsedValue is NSNull
            }
        }
        if !matchesEnum {
            let allowed = enumValues.map { "\($0.anyValue)" }.joined(separator: ", ")
            throw SchemaBindingError.enumViolation(value: "\(parsedValue)", allowed: allowed)
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
public enum SchemaBindingError: Error, Sendable, Equatable {
    case typeMismatch(expected: String)
    case missingRequired(String)
    case invalidReference(String)
    case invalidJSON
    case enumViolation(value: String, allowed: String)
    case additionalPropertiesNotAllowed([String])
    case compositionFailed(String)
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
        case .enumViolation(let value, let allowed):
            return "Value '\(value)' is not allowed. Must be one of: \(allowed)"
        case .additionalPropertiesNotAllowed(let keys):
            return "Additional properties not allowed: '\(keys.joined(separator: "', '"))'"
        case .compositionFailed(let reason):
            return "Schema composition validation failed: \(reason)"
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
            // No type constraint — still apply composition keywords if present
            if schema.allOf != nil || schema.anyOf != nil || schema.oneOf != nil || schema.not != nil {
                let composed = try validateComposition(json: value, schema: schema, components: components)
                return composed as! any Sendable  // safe: validateComposition returns JSON-compatible types
            }
            return value
        }

        let validated: any Sendable
        switch schemaType {
        case "string":
            guard let strVal = value as? String else {
                throw SchemaValidationError.typeMismatch(
                    schemaName: schemaName,
                    expected: "string",
                    actual: describeType(of: value)
                )
            }
            validated = strVal

        case "number", "integer":
            if let intVal = value as? Int {
                validated = schemaType == "integer" ? intVal : Double(intVal)
            } else if let doubleVal = value as? Double {
                validated = doubleVal
            } else {
                throw SchemaValidationError.typeMismatch(
                    schemaName: schemaName,
                    expected: schemaType,
                    actual: describeType(of: value)
                )
            }

        case "boolean":
            guard let boolVal = value as? Bool else {
                throw SchemaValidationError.typeMismatch(
                    schemaName: schemaName,
                    expected: "boolean",
                    actual: describeType(of: value)
                )
            }
            validated = boolVal

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
                validated = try arr.map { item in
                    try validateAgainstSchema(value: item, schemaName: schemaName, schema: itemSchema, components: components)
                }
            } else {
                validated = arr
            }

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
                validated = dict
                break
            }

            var result: [String: any Sendable] = [:]
            let knownKeys = Set(properties.keys)
            let extraKeys = dict.keys.filter { !knownKeys.contains($0) }

            // Enforce additionalProperties constraint
            switch schema.additionalProperties {
            case .allowed(false):
                if !extraKeys.isEmpty {
                    throw SchemaBindingError.additionalPropertiesNotAllowed(extraKeys.sorted())
                }
            case .schema(let subRef):
                for key in extraKeys {
                    result[key] = try validateAgainstSchema(
                        value: dict[key]!,
                        schemaName: schemaName,
                        schema: subRef.value,
                        components: components
                    )
                }
            case .allowed(true), nil:
                for key in extraKeys { result[key] = dict[key]! }
            }

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
                }
            }
            validated = result

        default:
            validated = value
        }

        // Validate enum constraint
        if let enumValues = schema.enumValues, !enumValues.isEmpty {
            try validateEnumConstraint(validated, against: enumValues)
        }

        // Apply composition keywords (allOf / anyOf / oneOf / not)
        if schema.allOf != nil || schema.anyOf != nil || schema.oneOf != nil || schema.not != nil {
            // validateComposition works on Any values; the result is structurally
            // identical (String, Int, Double, Bool, [Any], [String: Any]) — all
            // of which satisfy Sendable at runtime. Force-cast is safe here.
            let composed = try validateComposition(json: validated, schema: schema, components: components)
            return composed as! any Sendable  // safe: validateComposition returns JSON-compatible types
        }

        return validated
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

    /// Bind header parameters to context (case-insensitive key normalisation)
    ///
    /// Header names are lowercased so feature sets can use consistent names
    /// regardless of how the client capitalises them.
    ///
    /// ## ARO Usage
    /// ```aro
    /// Extract the <api-key> from the <headerParameters: x-api-key>.
    /// ```
    public static func bindHeaderParameters(_ headers: [String: String]) -> [String: Any] {
        var result: [String: Any] = [:]
        var normalised: [String: String] = [:]
        for (key, value) in headers {
            normalised[key.lowercased()] = value
        }
        result["headerParameters"] = normalised
        for (key, value) in normalised {
            result["headerParameters.\(key)"] = value
        }
        return result
    }

    /// Bind cookie parameters to context
    ///
    /// Exposes cookies declared as `in: cookie` in the OpenAPI spec as
    /// `cookieParameters` in the execution context.
    ///
    /// ## ARO Usage
    /// ```aro
    /// Extract the <session-id> from the <cookieParameters: session-id>.
    /// ```
    public static func bindCookieParameters(_ cookies: [String: String]) -> [String: Any] {
        var result: [String: Any] = [:]
        result["cookieParameters"] = cookies
        for (key, value) in cookies {
            result["cookieParameters.\(key)"] = value
        }
        return result
    }
}

// MARK: - Cookie Header Parsing

/// Parse a raw `Cookie` HTTP header into a name→value dictionary.
///
/// The Cookie header format is `name1=value1; name2=value2`.
/// Values are percent-decoded. Malformed pairs (no `=`) are silently skipped.
///
/// - Parameter cookieHeader: The raw value of the `Cookie` HTTP header.
/// - Returns: A dictionary mapping cookie names to their (decoded) values.
public func parseCookieHeader(_ cookieHeader: String) -> [String: String] {
    var result: [String: String] = [:]
    let pairs = cookieHeader.split(separator: ";", omittingEmptySubsequences: true)
    for pair in pairs {
        let trimmed = pair.trimmingCharacters(in: .whitespaces)
        guard let eqRange = trimmed.range(of: "=") else { continue }
        let name = String(trimmed[trimmed.startIndex..<eqRange.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        let rawValue = String(trimmed[eqRange.upperBound...])
            .trimmingCharacters(in: .whitespaces)
        let value = rawValue.removingPercentEncoding ?? rawValue
        guard !name.isEmpty else { continue }
        result[name] = value
    }
    return result
}

// MARK: - OpenAPIContextBinder (continued)

extension OpenAPIContextBinder {

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
