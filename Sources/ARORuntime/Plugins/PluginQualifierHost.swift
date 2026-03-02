//
// PluginQualifierHost.swift
// ARO Runtime - Plugin Qualifier Execution Protocol
//
// Protocol that plugin hosts must implement to support qualifier execution.
//

import Foundation

/// Protocol for plugin hosts that support qualifier execution
///
/// Plugin hosts (NativePluginHost, PythonPluginHost) implement this protocol
/// to execute qualifiers provided by their plugins.
public protocol PluginQualifierHost: Sendable {
    /// The name of this plugin host (for error messages)
    var pluginName: String { get }

    /// Execute a qualifier transformation
    ///
    /// - Parameters:
    ///   - qualifier: The qualifier name (e.g., "pick-random")
    ///   - input: The input value to transform
    /// - Returns: The transformed value
    /// - Throws: QualifierError or other errors on failure
    func executeQualifier(_ qualifier: String, input: any Sendable) throws -> any Sendable
}

/// Input format sent to plugins for qualifier execution
public struct QualifierInput: Codable, Sendable {
    /// The value to transform
    public let value: AnyCodable

    /// The detected type of the value
    public let type: String

    public init(value: any Sendable) {
        self.value = AnyCodable(value)
        self.type = QualifierInputType.detect(from: value).rawValue
    }
}

/// Output format returned from plugins after qualifier execution
public struct QualifierOutput: Codable, Sendable {
    /// The transformed result (on success)
    public let result: AnyCodable?

    /// Error message (on failure)
    public let error: String?

    public var isSuccess: Bool {
        error == nil && result != nil
    }
}

/// Helper for encoding/decoding any Sendable value as JSON
public struct AnyCodable: Codable, Sendable {
    public let value: any Sendable

    public init(_ value: any Sendable) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            // Use empty string as nil representation since we need Sendable
            self.value = ""
        } else if let bool = try? container.decode(Bool.self) {
            self.value = bool
        } else if let int = try? container.decode(Int.self) {
            self.value = int
        } else if let double = try? container.decode(Double.self) {
            self.value = double
        } else if let string = try? container.decode(String.self) {
            self.value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            self.value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            self.value = dict.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Cannot decode value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch value {
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [any Sendable]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: any Sendable]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            // Try to encode as string representation
            try container.encode(String(describing: value))
        }
    }
}
