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

        // Get source object
        guard let source = context.resolveAny(object.base) else {
            throw ActionError.undefinedVariable(object.base)
        }

        // If no specifiers, return the source directly (it's already any Sendable)
        if object.specifiers.isEmpty {
            return source
        }

        // Extract nested value using specifiers as path
        return try extractValue(from: source, path: object.specifiers)
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
                // Convert common types
                if let str = value as? String {
                    return str
                } else if let num = value as? Int {
                    return num
                } else if let num = value as? Double {
                    return num
                } else if let b = value as? Bool {
                    return b
                }
                return String(describing: value)
            }
        }

        // Try array index access
        if let array = source as? [any Sendable], let index = Int(key), index >= 0, index < array.count {
            return array[index]
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

        // Return original source if key not found but exists
        throw ActionError.propertyNotFound(property: key, on: String(describing: type(of: source)))
    }

    /// Extract a value from a string that might be JSON, form data, or key-value format
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
                    // Try numeric index
                    if let index = Int(specifier), index >= 0, index < values.count {
                        return values[index]
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

/// Fetches data from an HTTP endpoint
public struct FetchAction: ActionImplementation {
    public static let role: ActionRole = .request
    public static let verbs: Set<String> = ["fetch", "call"]
    public static let validPrepositions: Set<Preposition> = [.from, .via]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        // Get HTTP client service
        guard let httpClient = context.service(HTTPClientService.self) else {
            // Fallback to variable resolution
            guard let source = context.resolveAny(object.base) else {
                throw ActionError.undefinedVariable(object.base)
            }
            // source is already `any Sendable` from resolveAny
            return source
        }

        // Get URL from object
        guard let url: String = context.resolve(object.base) else {
            throw ActionError.undefinedVariable(object.base)
        }

        // Perform HTTP request
        return try await httpClient.get(url: url)
    }
}

/// Reads data from a file
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

        // Get file path
        guard let path: String = context.resolve(object.base) else {
            // Use object base as literal path
            return try await fileService.read(path: object.base)
        }

        return try await fileService.read(path: path)
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
}
