// ============================================================
// CallAction.swift
// ARO Runtime - External Service Call Action
// ============================================================

import Foundation
import AROParser

// MARK: - Call Action

/// Calls a method on an external service
///
/// The Call action invokes methods on registered services (databases, HTTP clients,
/// media processors, custom plugins, etc.).
///
/// ## Syntax
/// ```aro
/// <Call> the <result> from the <service: method> with { arg1: value1, arg2: value2 }.
/// ```
///
/// ## Examples
/// ```aro
/// (* HTTP GET request *)
/// <Call> the <response> from the <http: get> with {
///     url: "https://api.example.com/users"
/// }.
///
/// (* Database query *)
/// <Call> the <users> from the <postgres: query> with {
///     sql: "SELECT * FROM users WHERE active = true"
/// }.
///
/// (* Custom service *)
/// <Call> the <result> from the <ffmpeg: transcode> with {
///     input: "/path/to/video.mov",
///     output: "/path/to/video.mp4",
///     format: "mp4"
/// }.
/// ```
public struct CallAction: ActionImplementation {
    public static let role: ActionRole = .request
    public static let verbs: Set<String> = ["call", "invoke"]
    public static let validPrepositions: Set<Preposition> = [.from, .to, .with, .via]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        // Parse service and method from object
        // Format: <service: method> or <service-name: method-name>
        let serviceName: String
        let methodName: String

        if !object.specifiers.isEmpty {
            // Service name is the base, method is the first specifier
            serviceName = object.base
            methodName = object.specifiers[0]
        } else {
            // Try to split base on common separators
            let parts = object.base.split(separator: "-", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                serviceName = parts[0]
                methodName = parts[1]
            } else {
                throw ActionError.invalidInput(
                    "Call action requires service and method: <service: method>",
                    received: object.base
                )
            }
        }

        // Build arguments from result specifiers and literal value
        var args: [String: any Sendable] = [:]

        // Check for inline object in result specifiers
        for (index, specifier) in result.specifiers.enumerated() {
            if index > 0 { // Skip the result name
                // Parse as key-value if contains =
                if specifier.contains("=") {
                    let parts = specifier.split(separator: "=", maxSplits: 1)
                    if parts.count == 2 {
                        args[String(parts[0])] = String(parts[1])
                    }
                }
            }
        }

        // Check for literal or expression object (from "with { ... }" clause)
        // Object literals are bound as _expression_ (parsed by expression evaluator)
        // Simple literals are bound as _literal_ (legacy)
        if let exprArgs = context.resolveAny("_expression_") as? [String: any Sendable] {
            args.merge(exprArgs) { _, new in new }
        } else if let literalArgs = context.resolveAny("_literal_") as? [String: any Sendable] {
            args.merge(literalArgs) { _, new in new }
        }

        // Check for resolved object reference if preposition is "with"
        if object.preposition == .with {
            if let objArgs = context.resolveAny(object.base) as? [String: any Sendable] {
                args.merge(objArgs) { _, new in new }
            }

            // Also check specifiers as variable names
            for specifier in object.specifiers.dropFirst() {
                if let value = context.resolveAny(specifier) {
                    args[specifier] = value
                }
            }
        }

        // Call the service
        let callResult = try await ExternalServiceRegistry.shared.call(
            serviceName,
            method: methodName,
            args: args
        )

        // Don't bind result here - let the ActionBridge handle binding
        // This prevents "Cannot rebind immutable variable" errors
        return callResult
    }
}

// MARK: - Action Error Extension

extension ActionError {
    static func invalidInput(_ message: String, received: String) -> ActionError {
        return .runtimeError("Invalid input: \(message). Received: \(received)")
    }
}
