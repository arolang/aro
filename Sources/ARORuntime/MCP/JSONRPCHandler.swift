// ============================================================
// JSONRPCHandler.swift
// ARO MCP - JSON-RPC 2.0 Message Handling
// ============================================================

import Foundation

// MARK: - JSON-RPC Types

/// JSON-RPC 2.0 Request
public struct JSONRPCRequest: Codable, Sendable {
    public let jsonrpc: String
    public let id: JSONRPCId?
    public let method: String
    public let params: JSONValue?

    public init(id: JSONRPCId?, method: String, params: JSONValue? = nil) {
        self.jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
    }

    public var isNotification: Bool {
        return id == nil
    }
}

/// JSON-RPC 2.0 Response
public struct JSONRPCResponse: Codable, Sendable {
    public let jsonrpc: String
    public let id: JSONRPCId?
    public let result: JSONValue?
    public let error: JSONRPCError?

    public init(id: JSONRPCId?, result: JSONValue) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = result
        self.error = nil
    }

    public init(id: JSONRPCId?, error: JSONRPCError) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = nil
        self.error = error
    }
}

/// JSON-RPC 2.0 Error
public struct JSONRPCError: Codable, Sendable, Error {
    public let code: Int
    public let message: String
    public let data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    // Standard JSON-RPC error codes
    public static let parseError = JSONRPCError(code: -32700, message: "Parse error")
    public static let invalidRequest = JSONRPCError(code: -32600, message: "Invalid Request")
    public static let methodNotFound = JSONRPCError(code: -32601, message: "Method not found")
    public static let invalidParams = JSONRPCError(code: -32602, message: "Invalid params")
    public static let internalError = JSONRPCError(code: -32603, message: "Internal error")

    // MCP-specific error codes
    public static func resourceNotFound(_ uri: String) -> JSONRPCError {
        JSONRPCError(code: -32002, message: "Resource not found", data: .object(["uri": .string(uri)]))
    }
}

/// JSON-RPC ID can be string or number
public enum JSONRPCId: Codable, Sendable, Hashable {
    case string(String)
    case number(Int)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intValue = try? container.decode(Int.self) {
            self = .number(intValue)
        } else if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
        } else {
            throw DecodingError.typeMismatch(
                JSONRPCId.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected string or number")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        }
    }
}

/// Generic JSON value type for flexible data handling
public enum JSONValue: Codable, Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? container.decode(Int.self) {
            self = .number(Double(int))
        } else if let double = try? container.decode(Double.self) {
            self = .number(double)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.typeMismatch(
                JSONValue.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unable to decode JSON value")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            // Encode integers without decimal point
            if value.truncatingRemainder(dividingBy: 1) == 0 {
                try container.encode(Int(value))
            } else {
                try container.encode(value)
            }
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    // Convenience accessors
    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        if case .number(let value) = self { return Int(value) }
        return nil
    }

    public var doubleValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let dict) = self {
            return dict[key]
        }
        return nil
    }

    public subscript(index: Int) -> JSONValue? {
        if case .array(let arr) = self, index >= 0 && index < arr.count {
            return arr[index]
        }
        return nil
    }
}

// MARK: - JSON-RPC Handler

/// Handles parsing and encoding of JSON-RPC 2.0 messages
public struct JSONRPCHandler: Sendable {
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init() {
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    /// Parse a JSON-RPC request from data
    public func parseRequest(_ data: Data) throws -> JSONRPCRequest {
        do {
            return try decoder.decode(JSONRPCRequest.self, from: data)
        } catch {
            throw JSONRPCError.parseError
        }
    }

    /// Parse a JSON-RPC request from string
    public func parseRequest(_ string: String) throws -> JSONRPCRequest {
        guard let data = string.data(using: .utf8) else {
            throw JSONRPCError.parseError
        }
        return try parseRequest(data)
    }

    /// Encode a JSON-RPC response to string
    public func encodeResponse(_ response: JSONRPCResponse) throws -> String {
        let data = try encoder.encode(response)
        guard let string = String(data: data, encoding: .utf8) else {
            throw JSONRPCError.internalError
        }
        return string
    }

    /// Create a success response
    public func successResponse(id: JSONRPCId?, result: JSONValue) -> JSONRPCResponse {
        JSONRPCResponse(id: id, result: result)
    }

    /// Create an error response
    public func errorResponse(id: JSONRPCId?, error: JSONRPCError) -> JSONRPCResponse {
        JSONRPCResponse(id: id, error: error)
    }
}

// MARK: - JSONValue Builders

extension JSONValue {
    /// Create an object from a dictionary literal
    public static func from(_ dict: [String: Any]) -> JSONValue {
        var result: [String: JSONValue] = [:]
        for (key, value) in dict {
            result[key] = JSONValue.from(any: value)
        }
        return .object(result)
    }

    /// Convert any value to JSONValue
    public static func from(any value: Any) -> JSONValue {
        switch value {
        case is NSNull:
            return .null
        case let bool as Bool:
            return .bool(bool)
        case let int as Int:
            return .number(Double(int))
        case let double as Double:
            return .number(double)
        case let string as String:
            return .string(string)
        case let array as [Any]:
            return .array(array.map { JSONValue.from(any: $0) })
        case let dict as [String: Any]:
            var result: [String: JSONValue] = [:]
            for (key, val) in dict {
                result[key] = JSONValue.from(any: val)
            }
            return .object(result)
        case let jsonValue as JSONValue:
            return jsonValue
        default:
            return .string(String(describing: value))
        }
    }
}
