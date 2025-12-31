// ============================================================
// EnvironmentObject.swift
// ARO Runtime - Environment Variables System Object
// ============================================================

import Foundation

// MARK: - Environment Object

/// Environment variables system object
///
/// A source-only object for reading environment variables.
///
/// ## ARO Usage
/// ```aro
/// <Get> the <api-key> from the <env: "API_KEY">.
/// <Read> the <all-env> from the <env>.
/// ```
public struct EnvironmentObject: SystemObject, Instantiable {
    public static let identifier = "env"
    public static let description = "Environment variables"

    public var capabilities: SystemObjectCapabilities { .source }

    public init() {}

    public func read(property: String?) async throws -> any Sendable {
        guard let key = property else {
            // Return all environment variables as a dictionary
            return ProcessInfo.processInfo.environment
        }

        guard let value = ProcessInfo.processInfo.environment[key] else {
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
    /// Register environment-related system objects
    func registerEnvironmentObjects() {
        register(EnvironmentObject.self)
    }
}
