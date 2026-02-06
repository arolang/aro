// ============================================================
// ParameterObject.swift
// ARO Runtime - Command-Line Parameters System Object
// ARO-0047: Command-Line Parameters
// ============================================================

import Foundation

// MARK: - Parameter Object

/// Command-line parameters system object
///
/// A source-only object for reading command-line parameters.
///
/// ## ARO Usage
/// ```aro
/// <Extract> the <url> from the <parameter: url>.
/// <Extract> the <all-params> from the <parameter>.
/// ```
///
/// ## CLI Usage
/// ```bash
/// aro run . --url http://example.com --count 5 --verbose
/// ./myapp --url http://example.com --count 5 --verbose
/// ```
public struct ParameterObject: SystemObject, Instantiable {
    public static let identifier = "parameter"
    public static let description = "Command-line parameters"

    public var capabilities: SystemObjectCapabilities { .source }

    public init() {}

    public func read(property: String?) async throws -> any Sendable {
        guard let key = property else {
            // Return all parameters as a dictionary
            return ParameterStorage.shared.getAll()
        }

        guard let value = ParameterStorage.shared.get(key) else {
            throw SystemObjectError.propertyNotFound(key, in: Self.identifier)
        }

        return value
    }

    public func write(_ value: any Sendable) async throws {
        throw SystemObjectError.notWritable(Self.identifier)
    }
}

// MARK: - Registration

public extension SystemObjectRegistry {
    /// Register parameter-related system objects
    func registerParameterObjects() {
        register(ParameterObject.self)
    }
}
