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

        // Handle nullable: if the schema allows null and the value is NSNull, short-circuit
        if schema.isNullable && json is NSNull {
            return NSNull()
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

        // Validate const constraint (OpenAPI 3.1 / JSON Schema)
        if let constValue = schema.const {
            try validateConstConstraint(parsedValue, against: constValue)
        }

        // Apply composition keywords (allOf / anyOf / oneOf / not)
        if schema.allOf != nil || schema.anyOf != nil || schema.oneOf != nil || schema.not != nil {
            return try validateComposition(json: parsedValue, schema: schema, components: components)
        }

        return parsedValue
    }

    /// Convert Any to `any Sendable` — safe for JSON-compatible types (String, Int, Double, Bool,
    /// Array, Dictionary) which are all Sendable. `as?` is unavailable because `Sendable` is a
    /// marker protocol, and a direct `as!` triggers an "always succeeds" warning. Routing through
    /// a generic suppresses the warning while keeping the runtime cast that the original code did.
    @inline(__always)
    private static func assumeSendable(_ value: Any) -> any Sendable {
        func cast<T>(_ value: Any, to _: T.Type) -> T { value as! T }
        return cast(value, to: (any Sendable).self)
    }

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
            // Fast path: use discriminator to select sub-schema directly
            if let discriminator = schema.discriminator,
               let dict = json as? [String: Any],
               let discriminatorValue = dict[discriminator.propertyName] as? String {
                let targetRef: String
                if let mapping = discriminator.mapping, let mapped = mapping[discriminatorValue] {
                    targetRef = mapped
                } else {
                    targetRef = "#/components/schemas/\(discriminatorValue)"
                }
                guard let resolved = resolveRef(targetRef, components: components) else {
                    throw SchemaBindingError.invalidReference(targetRef)
                }
                return try parseValue(json: json, schema: resolved, components: components)
            }
            // Normal path: try each sub-schema in order
            for subRef in anyOf {
                if let result = try? parseValue(json: json, schema: subRef.value, components: components) {
                    return result
                }
            }
            throw SchemaBindingError.compositionFailed("anyOf: value does not match any of the listed schemas")
        }

        // oneOf: must match exactly one sub-schema
        if let oneOf = schema.oneOf, !oneOf.isEmpty {
            // Fast path: use discriminator to select sub-schema directly
            if let discriminator = schema.discriminator,
               let dict = json as? [String: Any],
               let discriminatorValue = dict[discriminator.propertyName] as? String {
                let targetRef: String
                if let mapping = discriminator.mapping, let mapped = mapping[discriminatorValue] {
                    targetRef = mapped
                } else {
                    targetRef = "#/components/schemas/\(discriminatorValue)"
                }
                guard let resolved = resolveRef(targetRef, components: components) else {
                    throw SchemaBindingError.invalidReference(targetRef)
                }
                return try parseValue(json: json, schema: resolved, components: components)
            }
            // Normal path: try all sub-schemas and expect exactly one match
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

    /// Check that a parsed value matches the `const` constraint.
    private static func validateConstConstraint(_ parsedValue: Any, against constValue: AnyCodableValue) throws {
        let matches: Bool
        switch constValue {
        case .string(let s): matches = (parsedValue as? String) == s
        case .int(let i): matches = (parsedValue as? Int) == i || (parsedValue as? Double) == Double(i)
        case .double(let d): matches = (parsedValue as? Double) == d
        case .bool(let b): matches = (parsedValue as? Bool) == b
        case .null: matches = parsedValue is NSNull
        }
        if !matches {
            throw SchemaBindingError.enumViolation(
                value: "\(parsedValue)",
                allowed: "\(constValue.anyValue)"
            )
        }
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

        // Handle nullable: if the schema allows null and the value is NSNull, short-circuit
        if schema.isNullable && value is NSNull {
            return NSNull()
        }

        // Determine expected type
        guard let schemaType = schema.type else {
            // No type constraint — still apply composition keywords if present
            if schema.allOf != nil || schema.anyOf != nil || schema.oneOf != nil || schema.not != nil {
                let composed = try validateComposition(json: value, schema: schema, components: components)
                return assumeSendable(composed)
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

        // Validate const constraint (OpenAPI 3.1 / JSON Schema)
        if let constValue = schema.const {
            try validateConstConstraint(validated, against: constValue)
        }

        // Apply composition keywords (allOf / anyOf / oneOf / not)
        if schema.allOf != nil || schema.anyOf != nil || schema.oneOf != nil || schema.not != nil {
            // validateComposition works on Any values; the result is structurally
            // identical (String, Int, Double, Bool, [Any], [String: Any]) — all
            // of which satisfy Sendable at runtime. Force-cast is safe here.
            let composed = try validateComposition(json: validated, schema: schema, components: components)
            return assumeSendable(composed)
        }

        return validated
    }

    /// Validate a response body against the schema defined in Operation.responses for the given status code.
    ///
    /// Looks up the matching response schema by status code string (e.g. "200"), then falls back to "default".
    /// Returns nil when the body is valid or there is no schema to validate against.
    /// Returns an error description string when the body does not match the schema.
    ///
    /// - Parameters:
    ///   - body: The response body value to validate (any JSON-compatible type)
    ///   - statusCode: The HTTP status code of the response
    ///   - operation: The OpenAPI Operation containing `responses`
    ///   - components: Components for `$ref` resolution
    /// - Returns: An error description string, or nil if valid / no schema defined
    public static func validateResponseBody(
        _ body: Any,
        forStatusCode statusCode: Int,
        operation: Operation,
        components: Components?
    ) -> String? {
        // Find matching response definition by status code, then fall back to "default"
        let response = operation.responses["\(statusCode)"] ?? operation.responses["default"]
        guard let response = response,
              let content = response.content,
              let mediaType = content["application/json"] ?? content.values.first,
              let schema = mediaType.schema?.value else {
            return nil  // No schema to validate against
        }

        do {
            _ = try validateAgainstSchema(
                value: assumeSendable(body),
                schemaName: "response",
                schema: schema,
                components: components
            )
            return nil  // Valid
        } catch {
            return error.localizedDescription
        }
    }

    /// Deserialize a query (or path) parameter from its raw string value(s) according
    /// to the OpenAPI `style` and `explode` serialization rules.
    ///
    /// - Parameters:
    ///   - rawValues: All occurrences of this parameter's key in the query string, in order.
    ///   - parameter: The OpenAPI `Parameter` declaration (provides `style`, `explode`, and `schema`).
    ///   - components: Components for `$ref` resolution when inspecting the schema type.
    /// - Returns: A `String` for scalar parameters, or `[String]` for array parameters.
    ///   Object parameters (e.g. `deepObject`) are not yet supported and return the first raw value.
    public static func deserializeParameter(
        rawValues: [String],
        parameter: Parameter,
        components: Components?
    ) -> Any {
        // Resolve schema type to decide whether this parameter is an array/object
        let resolvedSchema: Schema?
        if let schemaRef = parameter.schema {
            if let ref = schemaRef.value.ref, let resolved = resolveRef(ref, components: components) {
                resolvedSchema = resolved
            } else {
                resolvedSchema = schemaRef.value
            }
        } else {
            resolvedSchema = nil
        }

        let schemaType = resolvedSchema?.type ?? ""
        guard schemaType == "array" || schemaType == "object" else {
            // Scalar parameter — return first value as a string
            return rawValues.first ?? ""
        }

        // Object parameters (deepObject, etc.) are not yet supported
        if schemaType == "object" {
            return rawValues.first ?? ""
        }

        // Array parameter — apply style/explode deserialization
        let style = parameter.style ?? "form"
        // Default for explode: true when style == "form", false otherwise
        let explodeDefault = (style == "form")
        let explode = parameter.explode ?? explodeDefault

        switch style {
        case "form":
            if explode {
                // Each key occurrence is one element: rawValues already holds all elements
                return rawValues
            } else {
                // Single value, comma-delimited: "1,2,3" → ["1","2","3"]
                return (rawValues.first ?? "").split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            }
        case "spaceDelimited":
            if explode {
                return rawValues
            } else {
                // Split by space or percent-encoded space (%20)
                let raw = rawValues.first ?? ""
                return raw
                    .replacingOccurrences(of: "%20", with: " ")
                    .split(separator: " ", omittingEmptySubsequences: false)
                    .map(String.init)
            }
        case "pipeDelimited":
            if explode {
                return rawValues
            } else {
                return (rawValues.first ?? "").split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            }
        default:
            // Unknown style — fall back to exploded form behaviour
            return explode ? rawValues : [(rawValues.first ?? "")]
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

// MARK: - Query String Parsing

/// Parse a raw URL query string into a multi-value dictionary.
///
/// Handles repeated keys (`?ids=1&ids=2` → `["ids": ["1", "2"]]`) and
/// percent-decodes both keys and values. Pairs without `=` are treated as
/// a key with an empty-string value.
///
/// - Parameter query: The raw query string, **without** the leading `?`.
/// - Returns: A dictionary mapping each key to all its values in order.
public func parseQueryString(_ query: String) -> [String: [String]] {
    var result: [String: [String]] = [:]
    guard !query.isEmpty else { return result }
    for pair in query.split(separator: "&", omittingEmptySubsequences: false) {
        let pairStr = String(pair)
        let eqIdx = pairStr.firstIndex(of: "=")
        let rawKey: String
        let rawValue: String
        if let idx = eqIdx {
            rawKey = String(pairStr[pairStr.startIndex..<idx])
            rawValue = String(pairStr[pairStr.index(after: idx)...])
        } else {
            rawKey = pairStr
            rawValue = ""
        }
        let key = decodeQueryComponent(rawKey)
        let value = decodeQueryComponent(rawValue)
        guard !key.isEmpty else { continue }
        result[key, default: []].append(value)
    }
    return result
}

/// Decode a single query string component (key or value).
///
/// Per the `application/x-www-form-urlencoded` spec, `+` represents a space.
/// This must be replaced **before** percent-decoding so that a literal `+`
/// encoded as `%2B` is not incorrectly turned into a space.
public func decodeQueryComponent(_ raw: String) -> String {
    let plusDecoded = raw.replacingOccurrences(of: "+", with: " ")
    return plusDecoded.removingPercentEncoding ?? plusDecoded
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

// MARK: - Form Body Parsing

extension SchemaBinding {

    /// Parse an `application/x-www-form-urlencoded` body into a dictionary.
    ///
    /// Handles repeated keys by collecting values into an array:
    /// `a=1&a=2` → `["a": ["1", "2"]]`.
    /// `+` characters in values are decoded as spaces.
    public static func parseFormURLEncoded(_ body: Data) -> [String: Any] {
        guard let str = String(data: body, encoding: .utf8) else { return [:] }
        var result: [String: Any] = [:]
        for pair in str.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                let key = decodeQueryComponent(parts[0])
                let value = decodeQueryComponent(parts[1])
                if let existing = result[key] as? [String] {
                    result[key] = existing + [value]
                } else if let existing = result[key] as? String {
                    result[key] = [existing, value]
                } else {
                    result[key] = value
                }
            } else if parts.count == 1 {
                let key = parts[0].removingPercentEncoding ?? parts[0]
                if !key.isEmpty {
                    result[key] = ""
                }
            }
        }
        return result
    }

    /// Parse a `multipart/form-data` body into a dictionary.
    ///
    /// Text parts (no `Content-Type` or `text/*`) are stored as `String`.
    /// Binary parts are stored as `Data`.
    public static func parseMultipartFormData(_ body: Data, boundary: String) -> [String: Any] {
        var result: [String: Any] = [:]
        guard let boundaryData = "--\(boundary)".data(using: .utf8) else { return result }

        // Split body by boundary marker
        var parts: [Data] = []
        var searchRange = body.startIndex..<body.endIndex
        while let range = body.range(of: boundaryData, in: searchRange) {
            parts.append(body[searchRange.lowerBound..<range.lowerBound])
            searchRange = range.upperBound..<body.endIndex
        }
        // Append remainder after last boundary
        if searchRange.lowerBound < body.endIndex {
            parts.append(body[searchRange])
        }

        guard let closingMarker = "--".data(using: .utf8),
              let crlfData = "\r\n\r\n".data(using: .utf8),
              let crlfTwo = "\r\n".data(using: .utf8) else { return result }

        for part in parts.dropFirst() {  // skip preamble before first boundary
            // Skip the closing boundary suffix "--"
            if part.starts(with: closingMarker) { continue }
            // Strip leading \r\n after boundary line
            var partBody = part
            if partBody.starts(with: crlfTwo) {
                partBody = partBody.dropFirst(2)
            }
            // Split headers from content at \r\n\r\n
            guard let separatorRange = partBody.range(of: crlfData) else { continue }
            let headerData = partBody[partBody.startIndex..<separatorRange.lowerBound]
            let contentSlice = partBody[separatorRange.upperBound...]
            // Remove trailing \r\n from content
            let content: Data
            let sliceData = Data(contentSlice)
            if sliceData.count >= 2 && sliceData.suffix(2) == crlfTwo {
                content = sliceData.dropLast(2)
            } else {
                content = sliceData
            }

            guard let headerStr = String(data: headerData, encoding: .utf8) else { continue }
            let headers = parsePartHeaders(headerStr)
            guard let disposition = headers["content-disposition"],
                  let name = extractDispositionParam("name", from: disposition) else { continue }

            let contentType = headers["content-type"] ?? "text/plain"
            if contentType.hasPrefix("text/") || !headers.keys.contains("content-type") {
                result[name] = String(data: content, encoding: .utf8) ?? ""
            } else {
                result[name] = content
            }
        }
        return result
    }

    // MARK: - Multipart Helpers

    private static func parsePartHeaders(_ headerStr: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in headerStr.components(separatedBy: "\r\n") {
            guard let colonIdx = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colonIdx]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
            result[key] = value
        }
        return result
    }

    private static func extractDispositionParam(_ param: String, from disposition: String) -> String? {
        let pattern = "\(param)=\"([^\"]*)\""
        guard let range = disposition.range(of: pattern, options: .regularExpression) else { return nil }
        let match = String(disposition[range])
        // match looks like: name="value" — extract the quoted part
        guard let openQ = match.firstIndex(of: "\""),
              let closeQ = match.lastIndex(of: "\""),
              openQ != closeQ else { return nil }
        return String(match[match.index(after: openQ)..<closeQ])
    }

    /// Extract the `boundary` parameter from a `multipart/form-data` Content-Type value.
    public static func extractBoundary(from contentType: String) -> String? {
        for part in contentType.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if part.lowercased().hasPrefix("boundary=") {
                return String(part.dropFirst("boundary=".count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return nil
    }
}

// MARK: - OpenAPIContextBinder (continued)

extension OpenAPIContextBinder {

    /// Bind request body to context, dispatching on `contentType`.
    ///
    /// - `application/x-www-form-urlencoded`: parsed via `SchemaBinding.parseFormURLEncoded`
    /// - `multipart/form-data`: parsed via `SchemaBinding.parseMultipartFormData`
    /// - All other types (default JSON): parsed via `SchemaBinding.parseRequestBody` or
    ///   `JSONSerialization` fallback.
    ///
    /// The parsed value is exposed as `request.body` and, when it is a dictionary,
    /// each key is also exposed as `request.body.<key>`.
    public static func bindRequestBody(
        _ body: Data?,
        schema: Schema?,
        components: Components?,
        contentType: String? = nil
    ) throws -> [String: Any] {
        guard let body = body, !body.isEmpty else { return [:] }

        let baseContentType = contentType?
            .split(separator: ";").first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces)
            .lowercased()

        let parsed: Any
        switch baseContentType {
        case "application/x-www-form-urlencoded":
            parsed = SchemaBinding.parseFormURLEncoded(body)
        case "multipart/form-data":
            if let ct = contentType, let boundary = SchemaBinding.extractBoundary(from: ct) {
                parsed = SchemaBinding.parseMultipartFormData(body, boundary: boundary)
            } else {
                // No boundary — fall back to form-urlencoded parsing
                parsed = SchemaBinding.parseFormURLEncoded(body)
            }
        default:
            // JSON (or unknown content type)
            if let schema = schema {
                parsed = try SchemaBinding.parseRequestBody(body: body, schema: schema, components: components)
            } else if let json = try? JSONSerialization.jsonObject(with: body) {
                parsed = json
            } else {
                return [:]
            }
        }

        var result: [String: Any] = [:]
        result["request.body"] = parsed
        if let dict = parsed as? [String: Any] {
            for (key, value) in dict {
                result["request.body.\(key)"] = value
            }
        }
        return result
    }
}
