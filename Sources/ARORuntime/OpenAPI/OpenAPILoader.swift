// ============================================================
// OpenAPILoader.swift
// ARO Runtime - OpenAPI YAML/JSON Loader
// ============================================================

import Foundation
import Yams

/// Loads and parses OpenAPI specifications from YAML or JSON files
public struct OpenAPILoader {
    public static let contractFilename = "openapi.yaml"
    public static let alternativeFilenames = ["openapi.yml", "openapi.json"]

    public static func load(from url: URL) throws -> OpenAPISpec {
        let data = try Data(contentsOf: url)
        return try parse(data: data, filename: url.lastPathComponent)
    }

    public static func load(fromDirectory directory: URL) throws -> OpenAPISpec? {
        guard let contractURL = findContract(in: directory) else {
            return nil
        }
        return try load(from: contractURL)
    }

    public static func exists(in directory: URL) -> Bool {
        return findContract(in: directory) != nil
    }

    public static func findContract(in directory: URL) -> URL? {
        let fileManager = FileManager.default

        let primaryURL = directory.appendingPathComponent(contractFilename)
        if fileManager.fileExists(atPath: primaryURL.path) {
            return primaryURL
        }

        for filename in alternativeFilenames {
            let url = directory.appendingPathComponent(filename)
            if fileManager.fileExists(atPath: url.path) {
                return url
            }
        }

        return nil
    }

    public static func parse(data: Data, filename: String) throws -> OpenAPISpec {
        if filename.hasSuffix(".json") {
            return try parseJSON(data: data)
        } else {
            return try parseYAML(data: data)
        }
    }

    private static func parseYAML(data: Data) throws -> OpenAPISpec {
        guard let yamlString = String(data: data, encoding: .utf8) else {
            throw OpenAPILoadError.invalidEncoding
        }

        guard let yamlObject = try Yams.load(yaml: yamlString) else {
            throw OpenAPILoadError.emptyDocument
        }

        let jsonData = try JSONSerialization.data(withJSONObject: yamlObject)
        return try parseJSON(data: jsonData)
    }

    private static func parseJSON(data: Data) throws -> OpenAPISpec {
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(OpenAPISpec.self, from: data)
        } catch let error as DecodingError {
            throw OpenAPILoadError.parseError(describeDecodingError(error))
        }
    }

    private static func describeDecodingError(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, let context):
            return "Missing key '\(key.stringValue)' at \(context.codingPath.map { $0.stringValue }.joined(separator: "."))"
        case .valueNotFound(let type, let context):
            return "Missing value of type \(type) at \(context.codingPath.map { $0.stringValue }.joined(separator: "."))"
        case .typeMismatch(let type, let context):
            return "Type mismatch for \(type) at \(context.codingPath.map { $0.stringValue }.joined(separator: "."))"
        case .dataCorrupted(let context):
            return "Data corrupted at \(context.codingPath.map { $0.stringValue }.joined(separator: ".")): \(context.debugDescription)"
        @unknown default:
            return error.localizedDescription
        }
    }
}

// MARK: - Errors

public enum OpenAPILoadError: Error, Sendable {
    case fileNotFound(String)
    case invalidEncoding
    case emptyDocument
    case parseError(String)
    case invalidVersion(String)
}

extension OpenAPILoadError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .fileNotFound(let path):
            return "OpenAPI contract not found at: \(path)"
        case .invalidEncoding:
            return "OpenAPI file has invalid encoding (expected UTF-8)"
        case .emptyDocument:
            return "OpenAPI document is empty"
        case .parseError(let message):
            return "Failed to parse OpenAPI specification: \(message)"
        case .invalidVersion(let version):
            return "Unsupported OpenAPI version: \(version)"
        }
    }
}

// MARK: - OpenAPI Spec Extensions

extension OpenAPISpec {
    /// Environment variable used to select which root server ARO binds when a
    /// spec declares multiple `servers` (ARO-0195). Accepts a zero-based index
    /// (e.g. `1`) or a server `description` string. When unset or unmatched the
    /// first server is used, preserving single-server behaviour.
    public static let serverSelectionEnvVar = "ARO_OPENAPI_SERVER"

    /// The server-selection value taken from the environment, if any.
    public static var serverSelectionFromEnvironment: String? {
        let value = ProcessInfo.processInfo.environment[serverSelectionEnvVar]
        return (value?.isEmpty == false) ? value : nil
    }

    /// Selects the root-level server to bind (ARO-0195).
    ///
    /// - Parameter selection: `nil`/empty → the first server (default).
    ///   An integer string selects by zero-based index; any other string
    ///   matches a server `description`. Unmatched selections fall back to
    ///   the first server.
    public func selectedServer(selection: String? = nil) -> Server? {
        guard let servers = servers, !servers.isEmpty else { return nil }
        guard let selection = selection, !selection.isEmpty else { return servers.first }
        if let index = Int(selection) {
            if index >= 0 && index < servers.count { return servers[index] }
            return servers.first
        }
        if let match = servers.first(where: { $0.description == selection }) {
            return match
        }
        return servers.first
    }

    /// The root-level server ARO binds, honouring the environment selection.
    public var effectiveRootServer: Server? {
        selectedServer(selection: OpenAPISpec.serverSelectionFromEnvironment)
    }

    /// Effective servers for a path+operation, applying OpenAPI precedence:
    /// operation-level > path-level > root-level (ARO-0195). Returns `nil`
    /// only when no servers are declared at any level.
    public func effectiveServers(path: String, operation: Operation) -> [Server]? {
        if let opServers = operation.servers, !opServers.isEmpty { return opServers }
        if let pathServers = paths[path]?.servers, !pathServers.isEmpty { return pathServers }
        return servers
    }

    /// Effective servers for an operation looked up by its `operationId`.
    public func effectiveServers(forOperationId operationId: String) -> [Server]? {
        guard let (path, _, operation) = operation(byId: operationId) else { return servers }
        return effectiveServers(path: path, operation: operation)
    }

    /// Extract port from the selected server URL (variables resolved)
    /// e.g., "http://localhost:8000" → 8000
    public var serverPort: Int? {
        guard let serverURL = effectiveRootServer?.resolvedURL,
              let url = URL(string: serverURL),
              let port = url.port else {
            return nil
        }
        return port
    }

    /// Extract host from the selected server URL (variables resolved)
    public var serverHost: String? {
        guard let serverURL = effectiveRootServer?.resolvedURL,
              let url = URL(string: serverURL) else {
            return nil
        }
        return url.host
    }

    public func validate() throws {
        guard openapi.hasPrefix("3.") else {
            throw OpenAPILoadError.invalidVersion(openapi)
        }

        // `paths` operations must carry an operationId (it is the feature-set
        // name). Top-level `webhooks` (OpenAPI 3.1) may omit it: the webhook
        // map key becomes the handler name (ARO-0187), so they are exempt.
        for (path, pathItem) in paths {
            for (method, operation) in pathItem.allOperations {
                if operation.operationId == nil || operation.operationId?.isEmpty == true {
                    throw OpenAPIValidationError.missingOperationId(path: path, method: method)
                }
            }
        }
    }

    public var allOperationIds: [String] {
        var ids: [String] = []
        for (_, pathItem) in paths {
            for (_, operation) in pathItem.allOperations {
                if let opId = operation.operationId {
                    ids.append(opId)
                }
            }
        }
        // Webhooks: the operationId when present, otherwise the webhook name
        // (the feature-set handler name — see the webhook naming convention).
        for (name, item) in webhooks ?? [:] {
            for (_, operation) in item.allOperations {
                ids.append(operation.operationId ?? name)
            }
        }
        return ids
    }

    public func operation(byId operationId: String) -> (path: String, method: String, operation: Operation)? {
        // Search paths first (matched by operationId)...
        for (path, pathItem) in paths {
            for (method, operation) in pathItem.allOperations {
                if operation.operationId == operationId {
                    return (path, method, operation)
                }
            }
        }
        // ...then webhooks (matched by operationId or webhook name).
        for (name, item) in webhooks ?? [:] {
            let key = name.hasPrefix("/") ? name : "/\(name)"
            for (method, operation) in item.allOperations {
                if (operation.operationId ?? name) == operationId {
                    return (key, method, operation)
                }
            }
        }
        return nil
    }
}

public enum OpenAPIValidationError: Error, Sendable {
    case missingOperationId(path: String, method: String)
    case duplicateOperationId(String)
    case invalidReference(String)
}

extension OpenAPIValidationError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .missingOperationId(let path, let method):
            return "Missing operationId for \(method) \(path)"
        case .duplicateOperationId(let id):
            return "Duplicate operationId: \(id)"
        case .invalidReference(let ref):
            return "Invalid $ref: \(ref)"
        }
    }
}
