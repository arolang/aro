// ============================================================
// ActionError.swift
// ARO Runtime - Action Error Types
// ============================================================

import Foundation
import AROParser

/// Errors that can occur during action execution
public enum ActionError: Error, Sendable {
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
    case typeMismatch(expected: String, actual: String)

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
        case .typeMismatch(let expected, let actual):
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
