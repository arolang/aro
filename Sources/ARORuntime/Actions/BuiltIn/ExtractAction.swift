// ============================================================
// ExtractAction.swift
// ARO Runtime - Extract Action Implementation
// ============================================================

import Foundation
import AROParser

#if canImport(Darwin)
import CoreFoundation
#endif

/// Extracts a value from a source object
///
/// The Extract action is a REQUEST action that pulls data from an external
/// or internal source. It supports:
/// - Simple variable extraction: `<Extract> the <user> from the <request>`
/// - Nested property access: `<Extract> the <id> from the <user: profile>`
/// - Array indexing (via specifiers): `<Extract> the <first> from the <items: 0>`
///
/// ## Example
/// ```
/// <Extract> the <user: identifier> from the <incoming-request: parameters>.
/// ```
public struct ExtractAction: ActionImplementation {
    public static let role: ActionRole = .request
    public static let verbs: Set<String> = ["extract", "parse", "get"]
    public static let validPrepositions: Set<Preposition> = [.from, .via]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        // Handle environment variable extraction: <env: VAR_NAME>
        if object.base == "env", let varName = object.specifiers.first {
            guard let value = ProcessInfo.processInfo.environment[varName] else {
                throw ActionError.undefinedVariable("env:\(varName)")
            }
            return value
        }

        // ARO-0047: Handle command-line parameter extraction: <parameter: NAME>
        if object.base == "parameter" {
            if let paramName = object.specifiers.first {
                // Extract specific parameter
                guard let value = ParameterStorage.shared.get(paramName) else {
                    throw ActionError.undefinedVariable("parameter:\(paramName)")
                }
                return value
            } else {
                // Return all parameters as a dictionary
                return ParameterStorage.shared.getAll()
            }
        }

        // Get source object
        guard let source = context.resolveAny(object.base) else {
            throw ActionError.undefinedVariable(object.base)
        }

        // First, apply any object specifiers for nested property access
        var resolvedSource = source
        if !object.specifiers.isEmpty {
            resolvedSource = try extractValue(from: source, path: object.specifiers)
        } else if let stringSource = source as? String {
            // If source is a string containing JSON, parse it
            if let parsed = parseJSONString(stringSource) {
                resolvedSource = parsed
            }
        }

        // ARO-0046: Check for schema qualifier for typed event extraction
        // PascalCase qualifiers (e.g., ExtractLinksEvent) trigger schema validation
        if let schemaName = detectSchemaQualifier(result.specifiers) {
            // Debug: Check if schema registry is available
            guard let registry = context.schemaRegistry else {
                // Schema qualifier detected but no registry available
                // This is a configuration error - the openapi.yaml should define schemas
                throw SchemaValidationError.schemaNotFound(
                    schemaName: schemaName,
                    availableSchemas: ["(schema registry not available - ensure openapi.yaml is present)"]
                )
            }

            if let schema = registry.schema(named: schemaName) {
                // Validate and coerce the resolved source against the schema
                let validated = try SchemaBinding.validateAgainstSchema(
                    value: resolvedSource,
                    schemaName: schemaName,
                    schema: schema,
                    components: registry.components
                )
                return validated
            } else {
                // Schema not found - provide helpful error
                throw SchemaValidationError.schemaNotFound(
                    schemaName: schemaName,
                    availableSchemas: registry.schemaNames
                )
            }
        }

        // ARO-0038: Check result specifiers for list element access
        if let array = resolvedSource as? [any Sendable],
           let specifier = result.specifiers.first {
            let extracted = extractFromList(array, specifier: specifier)
            return extracted
        }

        // Use result specifier to extract from string (form data, JSON, etc.)
        // Example: <Extract> the <message-text: message> from the <body>.
        // Uses "message" as the key to extract from body string
        if let specifier = result.specifiers.first,
           let stringSource = resolvedSource as? String {
            if let value = extractFromString(stringSource, key: specifier) {
                return value
            }
        }

        // ARO-0041: Check result specifiers for date type property extraction
        // Syntax: <Extract> the <vacation-days: days> from <vacation>.
        if let specifier = result.specifiers.first {
            if let date = resolvedSource as? ARODate {
                if let value = date.property(specifier) {
                    if let intVal = value as? Int { return intVal }
                    if let strVal = value as? String { return strVal }
                    if let tzVal = value as? TimeZone { return tzVal.identifier }
                    return String(describing: value)
                }
            }
            if let range = resolvedSource as? ARODateRange {
                if let value = range.property(specifier) {
                    if let intVal = value as? Int { return intVal }
                    if let dateVal = value as? ARODate { return dateVal }
                    return String(describing: value)
                }
            }
            if let recurrence = resolvedSource as? ARORecurrence {
                if let value = recurrence.property(specifier) {
                    if let strVal = value as? String { return strVal }
                    if let dateVal = value as? ARODate { return dateVal }
                    if let arrVal = value as? [ARODate] { return arrVal }
                    return String(describing: value)
                }
            }
            if let distance = resolvedSource as? DateDistance {
                if let value = distance.property(specifier) {
                    if let intVal = value as? Int { return intVal }
                    if let dblVal = value as? Double { return dblVal }
                    return String(describing: value)
                }
            }
        }

        return resolvedSource
    }

    // MARK: - ARO-0046: Schema Qualifier Detection

    /// Detects if a specifier is a schema name vs property/element specifier
    ///
    /// Schema names are PascalCase (e.g., ExtractLinksEvent, UserData).
    /// Property specifiers are lowercase or kebab-case (e.g., html, user-id).
    /// Element specifiers are reserved words (first, last) or numeric.
    ///
    /// - Parameter specifiers: The result specifiers to check
    /// - Returns: The schema name if detected, nil otherwise
    private func detectSchemaQualifier(_ specifiers: [String]) -> String? {
        guard let first = specifiers.first else { return nil }

        // Reserved element specifiers - never schema names
        let reserved = ["first", "last", "length", "count", "days", "year", "month",
                        "day", "hour", "minute", "second", "weekday", "timezone",
                        "start", "end", "pattern", "next", "all", "years", "months",
                        "hours", "minutes", "seconds", "as string"]
        if reserved.contains(first.lowercased()) { return nil }

        // Numeric index - never a schema name
        if Int(first) != nil { return nil }

        // Range pattern (3-5) - never a schema name
        if first.contains("-") && first.split(separator: "-").allSatisfy({ Int($0) != nil }) {
            return nil
        }

        // Pick pattern (3,5,7) - never a schema name
        if first.contains(",") { return nil }

        // PascalCase check: starts with uppercase letter
        guard let firstChar = first.first, firstChar.isUppercase else {
            return nil
        }

        // Additional check: must contain only letters and numbers (no hyphens/underscores)
        // This distinguishes PascalCase schema names from OTHER-FORMAT names
        if first.allSatisfy({ $0.isLetter || $0.isNumber }) {
            return first
        }

        return nil
    }

    // MARK: - ARO-0038: List Element Access

    /// Extracts element(s) from a list using specifier patterns
    /// Supports: first, last, numeric index, ranges (3-5), picks (3,5,7)
    private func extractFromList(_ array: [any Sendable], specifier: String) -> any Sendable {
        let spec = specifier.lowercased()

        // Keyword access: first, last
        switch spec {
        case "last":
            return array.last ?? ""
        case "first":
            return array.first ?? ""
        default:
            break
        }

        // Range access: "3-5" = elements from index 3 to 5
        if spec.contains("-"), !spec.hasPrefix("-") {
            if let range = parseRange(spec) {
                return extractRange(from: array, range: range)
            }
        }

        // Pick access: "3,5,7" = elements at specific indices
        if spec.contains(",") {
            let indices = spec.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            if !indices.isEmpty {
                return indices.compactMap { idx -> (any Sendable)? in
                    guard idx >= 0, idx < array.count else { return nil }
                    return array[array.count - 1 - idx]
                }
            }
        }

        // Single numeric index (0 = last element, reverse indexing per ARO-0032)
        if let index = Int(spec), index >= 0, index < array.count {
            return array[array.count - 1 - index]
        }

        // Unknown specifier - return full array
        return array
    }

    /// Parses a range specifier like "3-5"
    private func parseRange(_ spec: String) -> (start: Int, end: Int)? {
        let parts = spec.split(separator: "-")
        guard parts.count == 2,
              let start = Int(parts[0].trimmingCharacters(in: .whitespaces)),
              let end = Int(parts[1].trimmingCharacters(in: .whitespaces)),
              start >= 0, end >= 0 else { return nil }
        return (start, end)
    }

    /// Extracts a range of elements from an array (reverse indexed)
    private func extractRange(from array: [any Sendable], range: (start: Int, end: Int)) -> [any Sendable] {
        let (start, end) = range
        let minIdx = min(start, end)
        let maxIdx = max(start, end)
        var result: [any Sendable] = []

        for i in minIdx...maxIdx {
            let forwardIdx = array.count - 1 - i
            if forwardIdx >= 0, forwardIdx < array.count {
                result.append(array[forwardIdx])
            }
        }

        return result
    }

    private func extractValue(from source: any Sendable, path: [String]) throws -> any Sendable {
        var current: any Sendable = source

        for key in path {
            current = try extractProperty(from: current, key: key)
        }

        return current
    }

    private func extractProperty(from source: any Sendable, key: String) throws -> any Sendable {
        // Try dictionary access (any Sendable values)
        if let dict = source as? [String: any Sendable], let value = dict[key] {
            return value
        }

        // Try string dictionary access
        if let dict = source as? [String: String], let value = dict[key] {
            return value
        }

        // Try generic dictionary access (handles type-erased dictionaries)
        if let dict = source as? Dictionary<String, Any> {
            if let value = dict[key] {
                // Convert common types, preserving nested structures
                if let str = value as? String {
                    return str
                } else if let num = value as? Int {
                    return num
                } else if let num = value as? Double {
                    return num
                } else if let b = value as? Bool {
                    return b
                } else if let nestedDict = value as? [String: any Sendable] {
                    // Preserve nested dictionaries for further extraction
                    return nestedDict
                } else if let nestedDict = value as? Dictionary<String, Any> {
                    // Convert Dictionary<String, Any> to [String: any Sendable]
                    var result: [String: any Sendable] = [:]
                    for (k, v) in nestedDict {
                        result[k] = convertToSendable(v)
                    }
                    return result
                } else if let arr = value as? [Any] {
                    // Convert arrays
                    return arr.map { convertToSendable($0) }
                }
                return String(describing: value)
            }
        }

        // Try array index access (0 = most recent element)
        if let array = source as? [any Sendable], let index = Int(key), index >= 0, index < array.count {
            return array[array.count - 1 - index]
        }

        // If source is a String, try to parse it as various formats
        if let stringSource = source as? String {
            if let value = extractFromString(stringSource, key: key) {
                return value
            }
        }

        // If source is a LogResult, try to extract from its message
        if let logResult = source as? LogResult {
            // First check if we want a property of LogResult itself
            switch key {
            case "message":
                return logResult.message
            case "target":
                return logResult.target
            default:
                // Try to extract from the message content
                if let value = extractFromString(logResult.message, key: key) {
                    return value
                }
            }
        }

        // If source is Data, try to parse it as various formats
        if let dataSource = source as? Data {
            if let stringSource = String(data: dataSource, encoding: .utf8),
               let value = extractFromString(stringSource, key: key) {
                return value
            }
        }

        #if !os(Windows)
        // Handle SocketPacket properties
        if let packet = source as? SocketPacket {
            switch key {
            case "buffer", "data":
                return packet.buffer
            case "connection", "connectionId":
                return packet.connection
            default:
                // Try to parse the packet data as string and extract from it
                if let stringData = String(data: packet.data, encoding: .utf8),
                   let value = extractFromString(stringData, key: key) {
                    return value
                }
            }
        }

        // Handle SocketConnection properties
        if let conn = source as? SocketConnection {
            switch key {
            case "id":
                return conn.id
            case "remoteAddress":
                return conn.remoteAddress
            default:
                break
            }
        }

        // Handle SocketDisconnectInfo properties
        if let info = source as? SocketDisconnectInfo {
            switch key {
            case "connectionId":
                return info.connectionId
            case "reason":
                return info.reason
            default:
                break
            }
        }
        #endif

        // Handle ARODate properties (ARO-0041)
        if let date = source as? ARODate {
            if let value = date.property(key) {
                // Convert to appropriate Sendable type
                if let intVal = value as? Int { return intVal }
                if let strVal = value as? String { return strVal }
                if let dateVal = value as? ARODate { return dateVal }
                if let tzVal = value as? TimeZone { return tzVal.identifier }
                return String(describing: value)
            }
        }

        // Handle ARODateRange properties (ARO-0041)
        if let range = source as? ARODateRange {
            if let value = range.property(key) {
                if let intVal = value as? Int { return intVal }
                if let dateVal = value as? ARODate { return dateVal }
                return String(describing: value)
            }
        }

        // Handle ARORecurrence properties (ARO-0041)
        if let recurrence = source as? ARORecurrence {
            if let value = recurrence.property(key) {
                if let strVal = value as? String { return strVal }
                if let dateVal = value as? ARODate { return dateVal }
                if let arrVal = value as? [ARODate] { return arrVal }
                return String(describing: value)
            }
        }

        // Handle DateDistance properties (ARO-0041)
        if let distance = source as? DateDistance {
            if let value = distance.property(key) {
                if let intVal = value as? Int { return intVal }
                if let dblVal = value as? Double { return dblVal }
                return String(describing: value)
            }
        }

        // Return original source if key not found but exists
        throw ActionError.propertyNotFound(property: key, on: String(describing: type(of: source)))
    }

    /// Extract a value from a string that might be JSON, form data, or key-value format
    /// Parse a JSON string into a dictionary or array (for Parse action with no key)
    private func parseJSONString(_ source: String) -> (any Sendable)? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("["),
              let data = trimmed.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return nil
        }

        // Handle JSON object
        if let dict = parsed as? [String: Any] {
            return convertJSONDict(dict)
        }

        // Handle JSON array
        if let array = parsed as? [Any] {
            return array.map { convertJSONValue($0) }
        }

        return nil
    }

    /// Convert a JSON dictionary to a Sendable dictionary
    private func convertJSONDict(_ dict: [String: Any]) -> [String: any Sendable] {
        var result: [String: any Sendable] = [:]
        for (key, value) in dict {
            result[key] = convertJSONValue(value)
        }
        return result
    }

    /// Convert any value to Sendable (for type-erased dictionaries)
    private func convertToSendable(_ value: Any) -> any Sendable {
        if let str = value as? String { return str }
        if let num = value as? Int { return num }
        if let num = value as? Double { return num }
        if let b = value as? Bool { return b }
        if let dict = value as? [String: any Sendable] { return dict }
        if let dict = value as? Dictionary<String, Any> {
            var result: [String: any Sendable] = [:]
            for (k, v) in dict {
                result[k] = convertToSendable(v)
            }
            return result
        }
        if let arr = value as? [any Sendable] { return arr }
        if let arr = value as? [Any] {
            return arr.map { convertToSendable($0) }
        }
        return String(describing: value)
    }

    private func extractFromString(_ source: String, key: String) -> (any Sendable)? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)

        // Try JSON parsing first (most common for HTTP APIs)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            if let jsonValue = extractFromJSON(trimmed, key: key) {
                return jsonValue
            }
        }

        // Try form-urlencoded format: key=value&key2=value2
        if trimmed.contains("=") && !trimmed.contains(":") {
            if let formValue = extractFromFormData(trimmed, key: key) {
                return formValue
            }
        }

        // Try key-value format: "key: value" or "key:value" (socket/text protocols)
        if trimmed.contains(":") {
            if let kvValue = extractFromKeyValue(trimmed, key: key) {
                return kvValue
            }
        }

        // Try simple "key value" format (space-separated)
        if let simpleValue = extractFromSimpleFormat(trimmed, key: key) {
            return simpleValue
        }

        return nil
    }

    /// Extract value from JSON string
    private func extractFromJSON(_ jsonString: String, key: String) -> (any Sendable)? {
        guard let data = jsonString.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return nil
        }

        // Handle JSON object
        if let dict = parsed as? [String: Any], let value = dict[key] {
            return convertJSONValue(value)
        }

        // Handle JSON array with numeric key
        if let array = parsed as? [Any], let index = Int(key), index >= 0, index < array.count {
            return convertJSONValue(array[index])
        }

        return nil
    }

    /// Convert JSON value to Sendable
    private func convertJSONValue(_ value: Any) -> any Sendable {
        switch value {
        case let str as String:
            return str
        case let num as NSNumber:
            let objCType = String(cString: num.objCType)
            #if canImport(Darwin)
            // On Darwin, check if it's actually a boolean type (CFBoolean)
            if CFGetTypeID(num) == CFBooleanGetTypeID() {
                return num.boolValue
            }
            #else
            // On Linux, NSNumber from JSON booleans have objCType "c" (char)
            if objCType == "c" || objCType == "B" {
                let intVal = num.intValue
                if intVal == 0 || intVal == 1 {
                    return num.boolValue
                }
            }
            #endif
            // Check if it's a double
            if objCType == "d" || objCType == "f" {
                return num.doubleValue
            }
            return num.intValue
        case let dict as [String: Any]:
            var result: [String: any Sendable] = [:]
            for (k, v) in dict {
                result[k] = convertJSONValue(v)
            }
            return result
        case let array as [Any]:
            return array.map { convertJSONValue($0) }
        case let bool as Bool:
            return bool
        default:
            return String(describing: value)
        }
    }

    /// Extract value from form-urlencoded data: key=value&key2=value2
    private func extractFromFormData(_ formData: String, key: String) -> (any Sendable)? {
        let pairs = formData.split(separator: "&")
        for pair in pairs {
            let parts = pair.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                let pairKey = String(parts[0]).trimmingCharacters(in: .whitespaces)
                    .removingPercentEncoding ?? String(parts[0])
                if pairKey == key {
                    let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
                        .removingPercentEncoding ?? String(parts[1])
                    return value
                }
            }
        }
        return nil
    }

    /// Extract value from key-value format: "key: value" or multiline "key: value\nkey2: value2"
    private func extractFromKeyValue(_ kvString: String, key: String) -> (any Sendable)? {
        // Handle multiline key-value
        let lines = kvString.split(whereSeparator: { $0.isNewline })

        for line in lines {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                let lineKey = String(parts[0]).trimmingCharacters(in: .whitespaces)
                if lineKey.lowercased() == key.lowercased() {
                    return String(parts[1]).trimmingCharacters(in: .whitespaces)
                }
            }
        }

        // Try single-line format: "key: value"
        if lines.count == 1 {
            let parts = kvString.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                let lineKey = String(parts[0]).trimmingCharacters(in: .whitespaces)
                if lineKey.lowercased() == key.lowercased() {
                    return String(parts[1]).trimmingCharacters(in: .whitespaces)
                }
            }
        }

        return nil
    }

    /// Extract value from simple "command value" format (e.g., "say hello")
    private func extractFromSimpleFormat(_ text: String, key: String) -> (any Sendable)? {
        let parts = text.split(separator: " ", maxSplits: 1)
        if parts.count == 2 {
            let command = String(parts[0]).lowercased()
            if command == key.lowercased() {
                return String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }
}

/// Retrieves data from a repository
///
/// When the source name ends with `-repository`, the data is retrieved from
/// the RepositoryStorage service, which persists across HTTP requests
/// within the same business activity.
///
/// ## Examples
/// ```
/// <Retrieve> the <messages> from the <message-repository>.
/// <Retrieve> the <message> from the <message-repository: last>.
/// <Retrieve> the <message> from the <message-repository: first>.
/// ```
public struct RetrieveAction: ActionImplementation {
    public static let role: ActionRole = .request
    public static let verbs: Set<String> = ["retrieve", "fetch", "load", "find"]
    public static let validPrepositions: Set<Preposition> = [.from]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        // Get repository name
        let repoName = object.base

        // Check if this is a repository (ends with -repository)
        if InMemoryRepositoryStorage.isRepositoryName(repoName) {
            // Check for where clause (bound by FeatureSetExecutor)
            let whereField: String? = context.resolve("_where_field_")
            let whereValue = context.resolveAny("_where_value_")

            // Retrieve from repository storage service
            var values: [any Sendable]
            if let storage = context.service(RepositoryStorageService.self) {
                if let field = whereField, let matchValue = whereValue {
                    // Filtered retrieval with where clause
                    values = await storage.retrieve(
                        from: repoName,
                        businessActivity: context.businessActivity,
                        where: field,
                        equals: matchValue
                    )
                } else {
                    // Retrieve all
                    values = await storage.retrieve(
                        from: repoName,
                        businessActivity: context.businessActivity
                    )
                }
            } else {
                // Fallback to shared instance if service not registered
                if let field = whereField, let matchValue = whereValue {
                    values = await InMemoryRepositoryStorage.shared.retrieve(
                        from: repoName,
                        businessActivity: context.businessActivity,
                        where: field,
                        equals: matchValue
                    )
                } else {
                    values = await InMemoryRepositoryStorage.shared.retrieve(
                        from: repoName,
                        businessActivity: context.businessActivity
                    )
                }
            }

            // Check for specifiers like "first" or "last"
            if let specifier = object.specifiers.first?.lowercased() {
                switch specifier {
                case "last":
                    // Return last element or empty string if empty
                    return values.last ?? ""
                case "first":
                    // Return first element or empty string if empty
                    return values.first ?? ""
                default:
                    // Try numeric index (0 = most recent element)
                    if let index = Int(specifier), index >= 0, index < values.count {
                        return values[values.count - 1 - index]
                    }
                    // Unknown specifier - return all values
                    return values
                }
            }

            // If where clause was used and we got exactly one result, return it directly
            // (not as an array) since we're looking for a specific entity
            if whereField != nil && values.count == 1 {
                return values[0]
            }

            // No specifier - return the list of values (empty list if repository is empty)
            return values
        }

        // Try to resolve as a regular variable
        if let source = context.resolveAny(repoName) {
            return source
        }

        throw ActionError.undefinedRepository(repoName)
    }
}

/// Receives data from an external source (e.g., HTTP request, socket)
public struct ReceiveAction: ActionImplementation {
    public static let role: ActionRole = .request
    public static let verbs: Set<String> = ["receive"]
    public static let validPrepositions: Set<Preposition> = [.from, .via]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        // Receive is typically handled by the event system
        // Here we just resolve the source
        guard let source = context.resolveAny(object.base) else {
            throw ActionError.undefinedVariable(object.base)
        }

        // source is already `any Sendable` from resolveAny
        return source
    }
}

/// Reads data from a file with automatic format detection (ARO-0040)
/// The file extension determines the parsing format:
/// - .json: Parse as JSON -> Map or Array
/// - .yaml/.yml: Parse as YAML -> Map or Array
/// - .xml: Parse as XML -> Map
/// - .toml: Parse as TOML -> Map or Array
/// - .csv: Parse as CSV -> Array of Maps
/// - .tsv: Parse as TSV -> Array of Maps
/// - .txt: Parse as key=value -> Map
/// - .md/.html/.sql/.obj/unknown: Return raw string
///
/// Use `as String` specifier to bypass parsing and get raw content:
/// `<Read> the <raw: as String> from "./data.json".`
public struct ReadAction: ActionImplementation {
    public static let role: ActionRole = .request
    public static let verbs: Set<String> = ["read"]
    public static let validPrepositions: Set<Preposition> = [.from]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        // Get file service
        guard let fileService = context.service(FileSystemService.self) else {
            throw ActionError.missingService("FileSystemService")
        }

        // Get file path - handle <file: path-variable> pattern
        let path: String
        if object.base == "file", let specifier = object.specifiers.first {
            // Pattern: <file: path-variable> - resolve the specifier as the path
            if let resolvedPath: String = context.resolve(specifier) {
                path = resolvedPath
            } else {
                // Use specifier as literal path
                path = specifier
            }
        } else if let resolvedPath: String = context.resolve(object.base) {
            // Pattern: <path-variable> - resolve base as path
            path = resolvedPath
        } else {
            // Use object base as literal path
            path = object.base
        }

        // Read file content
        let content = try await fileService.read(path: path)

        // Check for "as String" specifier to bypass format detection (ARO-0040)
        let asString = result.specifiers.contains { specifier in
            specifier.lowercased() == "string" || specifier.lowercased() == "as string"
        }

        if asString {
            // Return raw content without parsing
            return content
        }

        // Get format options from "with" clause (ARO-0040)
        // Options can include: delimiter, header, quote
        var formatOptions: [String: any Sendable] = [:]
        if let configDict = context.resolveAny("_literal_") as? [String: any Sendable] {
            if let delimiter = configDict["delimiter"] as? String {
                formatOptions["delimiter"] = delimiter
            }
            if let header = configDict["header"] as? Bool {
                formatOptions["header"] = header
            }
            if let quote = configDict["quote"] as? String {
                formatOptions["quote"] = quote
            }
        }

        // Detect format from file extension and deserialize (ARO-0040)
        let format = FileFormat.detect(from: path)
        return FormatDeserializer.deserialize(content, format: format, options: formatOptions)
    }
}

// MARK: - Placeholder Services

/// HTTP client service protocol
public protocol HTTPClientService: Sendable {
    func get(url: String) async throws -> any Sendable
    func post(url: String, body: any Sendable) async throws -> any Sendable
}

/// File system service protocol
public protocol FileSystemService: Sendable {
    func read(path: String) async throws -> String
    func write(path: String, content: String) async throws
    func exists(path: String) -> Bool

    // ARO-0036: Extended file operations
    func stat(path: String) async throws -> FileInfo
    func list(directory: String, pattern: String?, recursive: Bool) async throws -> [FileInfo]
    func existsWithType(path: String) -> (exists: Bool, isDirectory: Bool)
    func createDirectory(path: String) async throws
    func touch(path: String) async throws
    func copy(source: String, destination: String) async throws
    func move(source: String, destination: String) async throws
    func append(path: String, content: String) async throws
}
