// ============================================================
// JSONValue.swift
// AROAsk - Sendable JSON tree for tool schemas and arguments
// ============================================================

import Foundation

/// A type-safe, Sendable JSON value. Used for tool schemas and arguments
/// throughout the `aro ask` tool-calling pipeline.
public enum JSONValue: Codable, Sendable, Equatable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    // MARK: - Codable

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? container.decode(Double.self) {
            self = .number(n)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let a = try? container.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? container.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a valid JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .number(let n): try container.encode(n)
        case .bool(let b):   try container.encode(b)
        case .object(let o): try container.encode(o)
        case .array(let a):  try container.encode(a)
        case .null:          try container.encodeNil()
        }
    }

    // MARK: - Subscript

    public subscript(key: String) -> JSONValue? {
        guard case .object(let o) = self else { return nil }
        return o[key]
    }

    // MARK: - Convenience accessors

    public var stringValue: String? {
        guard case .string(let s) = self else { return nil }
        return s
    }
    public var intValue: Int? {
        guard case .number(let n) = self else { return nil }
        return Int(n)
    }
    public var doubleValue: Double? {
        guard case .number(let n) = self else { return nil }
        return n
    }
    public var boolValue: Bool? {
        guard case .bool(let b) = self else { return nil }
        return b
    }
    public var arrayValue: [JSONValue]? {
        guard case .array(let a) = self else { return nil }
        return a
    }
    public var objectValue: [String: JSONValue]? {
        guard case .object(let o) = self else { return nil }
        return o
    }

    // MARK: - Parsing

    public static func decode(from jsonString: String) throws -> JSONValue {
        let data = Data(jsonString.utf8)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
}
