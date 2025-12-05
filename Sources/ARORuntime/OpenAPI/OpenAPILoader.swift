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
    /// Extract port from the first server URL
    /// e.g., "http://localhost:8000" → 8000
    public var serverPort: Int? {
        guard let serverURL = servers?.first?.url,
              let url = URL(string: serverURL),
              let port = url.port else {
            return nil
        }
        return port
    }

    /// Extract host from the first server URL
    public var serverHost: String? {
        guard let serverURL = servers?.first?.url,
              let url = URL(string: serverURL) else {
            return nil
        }
        return url.host
    }

    public func validate() throws {
        guard openapi.hasPrefix("3.") else {
            throw OpenAPILoadError.invalidVersion(openapi)
        }

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
        return ids
    }

    public func operation(byId operationId: String) -> (path: String, method: String, operation: Operation)? {
        for (path, pathItem) in paths {
            for (method, operation) in pathItem.allOperations {
                if operation.operationId == operationId {
                    return (path, method, operation)
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
