// ============================================================
// ActionError.swift
// ARO Runtime - Action Error Types
// ============================================================

import Foundation
import AROParser

// MARK: - ARO Error (ARO-0008)

/// ARO's core error type following "The Code Is The Error Message" philosophy.
/// The error message is generated directly from the statement that failed.
public struct AROError: Error, Sendable {
    /// The generated error message (e.g., "Cannot retrieve the user from the user-repository where id = 530.")
    public let message: String

    /// The feature set where the error occurred
    public let featureSet: String

    /// The business activity this feature set belongs to
    public let businessActivity: String

    /// The original statement text that failed
    public let statement: String

    /// Resolved variable values at the time of the error
    public let resolvedValues: [String: String]

    public init(
        message: String,
        featureSet: String,
        businessActivity: String,
        statement: String,
        resolvedValues: [String: String] = [:]
    ) {
        self.message = message
        self.featureSet = featureSet
        self.businessActivity = businessActivity
        self.statement = statement
        self.resolvedValues = resolvedValues
    }

    /// Generate an error message from an action statement
    /// - Parameters:
    ///   - verb: The action verb (e.g., "Retrieve")
    ///   - result: The result variable name
    ///   - preposition: The preposition used
    ///   - object: The object description
    ///   - condition: Optional condition clause
    ///   - featureSet: The feature set name
    /// - Returns: An AROError with the generated message
    public static func fromStatement(
        verb: String,
        result: String,
        preposition: String,
        object: String,
        condition: String? = nil,
        featureSet: String,
        businessActivity: String,
        resolvedValues: [String: String] = [:]
    ) -> AROError {
        var msg = "Cannot \(verb.lowercased()) the \(result) \(preposition) the \(object)"
        if let cond = condition {
            msg += " \(cond)"
        }
        msg += "."

        // Substitute resolved values
        var finalMsg = msg
        for (key, value) in resolvedValues {
            finalMsg = finalMsg.replacingOccurrences(of: "<\(key)>", with: "\(value)")
        }

        return AROError(
            message: finalMsg,
            featureSet: featureSet,
            businessActivity: businessActivity,
            statement: "<\(verb)> the <\(result)> \(preposition) the <\(object)>\(condition.map { " \($0)" } ?? "").",
            resolvedValues: resolvedValues
        )
    }
}

extension AROError: CustomStringConvertible {
    public var description: String {
        var desc = """
        Runtime Error: \(message)
          Feature: \(featureSet)
          Business Activity: \(businessActivity)
          Statement: \(statement)
        """

        // Add trace with resolved values if available
        if !resolvedValues.isEmpty {
            desc += "\n          Trace:"
            for (key, value) in resolvedValues.sorted(by: { $0.key < $1.key }) {
                desc += "\n            \(key) = \(value)"
            }
        }

        return desc
    }
}

extension AROError: LocalizedError {
    public var errorDescription: String? {
        description
    }
}

// MARK: - Action Error

/// Errors that can occur during action execution
public enum ActionError: Error, Sendable {
    /// Statement execution failed - generates error from statement (ARO-0008)
    case statementFailed(AROError)

    /// Variable not found in context
    case undefinedVariable(String)

    /// Property not found on object
    case propertyNotFound(property: String, on: String)

    /// Invalid preposition for action
    case invalidPreposition(action: String, received: Preposition, expected: Set<Preposition>)

    /// Required service not registered
    case missingService(String)

    /// Repository not found
    case undefinedRepository(String)

    /// Type mismatch during execution
    case typeMismatch(expected: String, actual: String, variable: String? = nil)

    /// Explicit throw from user code
    case thrown(type: String, reason: String, context: String)

    /// Action not found for verb
    case unknownAction(String)

    /// Validation failure
    case validationFailed(String)

    /// Comparison failure
    case comparisonFailed(String)

    /// I/O error
    case ioError(String)

    /// Network error
    case networkError(String)

    /// Timeout error
    case timeout(String)

    /// Feature set not found
    case featureSetNotFound(String)

    /// Entry point not found
    case entryPointNotFound(String)

    /// Execution was cancelled
    case cancelled

    /// Generic runtime error
    case runtimeError(String)
}

// MARK: - CustomStringConvertible

extension ActionError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .statementFailed(let aroError):
            return aroError.description
        case .undefinedVariable(let name):
            return "Undefined variable: '\(name)'"
        case .propertyNotFound(let prop, let type):
            return "Property '\(prop)' not found on type '\(type)'"
        case .invalidPreposition(let action, let received, let expected):
            let expectedStr = expected.map { $0.rawValue }.sorted().joined(separator: ", ")
            return "Invalid preposition '\(received.rawValue)' for action '\(action)'. Expected: [\(expectedStr)]"
        case .missingService(let name):
            return "Service not registered: '\(name)'"
        case .undefinedRepository(let name):
            return "Repository not found: '\(name)'"
        case .typeMismatch(let expected, let actual, let variable):
            if let varName = variable {
                return "Type mismatch for '\(varName)': expected '\(expected)', got '\(actual)'"
            }
            return "Type mismatch: expected '\(expected)', got '\(actual)'"
        case .thrown(let type, let reason, let context):
            return "\(type) in \(context): \(reason)"
        case .unknownAction(let verb):
            return "Unknown action verb: '\(verb)'"
        case .validationFailed(let reason):
            return "Validation failed: \(reason)"
        case .comparisonFailed(let reason):
            return "Comparison failed: \(reason)"
        case .ioError(let msg):
            return "I/O error: \(msg)"
        case .networkError(let msg):
            return "Network error: \(msg)"
        case .timeout(let msg):
            return "Timeout: \(msg)"
        case .featureSetNotFound(let name):
            return "Feature set not found: '\(name)'"
        case .entryPointNotFound(let name):
            return "Entry point not found: '\(name)'"
        case .cancelled:
            return "Execution was cancelled"
        case .runtimeError(let msg):
            return "Runtime error: \(msg)"
        }
    }
}

// MARK: - LocalizedError

extension ActionError: LocalizedError {
    public var errorDescription: String? {
        description
    }
}
