// ============================================================
// TypedValue.swift
// ARO Runtime - Typed Value Wrapper
// ============================================================

import Foundation
import AROParser

/// A value paired with its type information
///
/// TypedValue wraps runtime values with their DataType, enabling:
/// - Type preservation from parse time through runtime
/// - Centralized type checking instead of scattered `is`/`as?` checks
/// - Better error messages with expected vs actual type info
public struct TypedValue: Sendable, CustomStringConvertible {
    // MARK: - Properties

    /// The underlying value
    public let value: any Sendable

    /// The type of the value
    public let type: DataType

    // MARK: - Initialization

    /// Create a typed value
    /// - Parameters:
    ///   - value: The underlying value
    ///   - type: The type (defaults to .unknown for gradual typing)
    public init(_ value: any Sendable, type: DataType = .unknown) {
        self.value = value
        self.type = type
    }

    // MARK: - Convenience Constructors

    /// Create a typed string value
    public static func string(_ s: String) -> TypedValue {
        TypedValue(s, type: .string)
    }

    /// Create a typed integer value
    public static func integer(_ i: Int) -> TypedValue {
        TypedValue(i, type: .integer)
    }

    /// Create a typed float value
    public static func float(_ d: Double) -> TypedValue {
        TypedValue(d, type: .float)
    }

    /// Create a typed boolean value
    public static func boolean(_ b: Bool) -> TypedValue {
        TypedValue(b, type: .boolean)
    }

    /// Create a typed list value
    /// - Parameters:
    ///   - arr: The array value
    ///   - elementType: The element type (defaults to .unknown)
    public static func list(_ arr: [any Sendable], elementType: DataType = .unknown) -> TypedValue {
        TypedValue(arr, type: .list(elementType))
    }

    /// Create a typed map value
    /// - Parameters:
    ///   - dict: The dictionary value
    ///   - keyType: The key type (defaults to .string)
    ///   - valueType: The value type (defaults to .unknown)
    public static func map(
        _ dict: [String: any Sendable],
        keyType: DataType = .string,
        valueType: DataType = .unknown
    ) -> TypedValue {
        TypedValue(dict, type: .map(key: keyType, value: valueType))
    }

    /// Create a typed value with a schema type
    /// - Parameters:
    ///   - value: The value (typically a dictionary matching the schema)
    ///   - schemaName: The OpenAPI schema name
    public static func schema(_ value: any Sendable, schemaName: String) -> TypedValue {
        TypedValue(value, type: .schema(schemaName))
    }

    // MARK: - Type-Safe Extraction

    /// Extract as String if the value is a string
    public func asString() -> String? {
        value as? String
    }

    /// Extract as Int if the value is an integer
    public func asInt() -> Int? {
        value as? Int
    }

    /// Extract as Double if the value is a float/double
    /// Also handles Int -> Double conversion
    public func asDouble() -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        return nil
    }

    /// Extract as Bool if the value is a boolean
    public func asBool() -> Bool? {
        value as? Bool
    }

    /// Extract as array if the value is a list
    public func asList() -> [any Sendable]? {
        value as? [any Sendable]
    }

    /// Extract as dictionary if the value is a map
    public func asDict() -> [String: any Sendable]? {
        value as? [String: any Sendable]
    }

    // MARK: - Type Checking

    /// Check if this value is of the expected type
    public func isType(_ expected: DataType) -> Bool {
        type.isAssignableTo(expected)
    }

    /// Check if this value is a primitive type
    public var isPrimitive: Bool {
        type.isPrimitive
    }

    /// Check if this value is a collection type
    public var isCollection: Bool {
        type.isCollection
    }

    /// Check if this value has unknown type
    public var isUnknown: Bool {
        type == .unknown
    }

    // MARK: - CustomStringConvertible

    public var description: String {
        "\(value) : \(type)"
    }
}

// MARK: - Type Inference

extension TypedValue {
    /// Create a TypedValue by inferring the type from the value
    /// - Parameter value: The value to wrap
    /// - Returns: A TypedValue with inferred type
    public static func infer(_ value: any Sendable) -> TypedValue {
        TypedValue(value, type: inferType(value))
    }

    /// Infer the DataType from a runtime value
    /// - Parameter value: The value to inspect
    /// - Returns: The inferred DataType
    public static func inferType(_ value: any Sendable) -> DataType {
        switch value {
        case is String:
            return .string
        case is Int:
            return .integer
        case is Double:
            return .float
        case is Bool:
            return .boolean
        case let arr as [any Sendable]:
            // Infer element type from first element
            if let first = arr.first {
                return .list(inferType(first))
            }
            return .list(.unknown)
        case is [String: any Sendable]:
            return .map(key: .string, value: .unknown)
        case let typed as TypedValue:
            // Already typed, preserve it
            return typed.type
        default:
            return .unknown
        }
    }
}

// MARK: - Equatable (for testing)

extension TypedValue: Equatable {
    public static func == (lhs: TypedValue, rhs: TypedValue) -> Bool {
        // Types must match
        guard lhs.type == rhs.type else { return false }

        // Compare values based on type
        switch lhs.type {
        case .string:
            return lhs.asString() == rhs.asString()
        case .integer:
            return lhs.asInt() == rhs.asInt()
        case .float:
            return lhs.asDouble() == rhs.asDouble()
        case .boolean:
            return lhs.asBool() == rhs.asBool()
        default:
            // For complex types, use string representation
            return String(describing: lhs.value) == String(describing: rhs.value)
        }
    }
}
