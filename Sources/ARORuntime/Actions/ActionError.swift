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
        resolvedValues: [String: String] = [:],
        hint: String? = nil
    ) -> AROError {
        var msg = "Cannot \(verb.lowercased()) the \(result) \(preposition) the \(object)"
        if let cond = condition {
            msg += " \(cond)"
        }
        msg += "."
        // ARO-0006 says the statement *is* the message, and for
        // nearly every failure it is. An unknown qualifier is the
        // exception: the statement reads perfectly well and gives no
        // clue that the name doesn't exist, so that one gets a
        // sentence of its own (GitLab #486).
        if let hint { msg += " \(hint)" }

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

extension AROError {

    /// The one sentence a reconstructed statement cannot supply for itself.
    ///
    /// ARO-0006 says the statement *is* the message, and for nearly every
    /// failure it is. These are the exceptions — failures where the statement
    /// reads perfectly well and gives no clue what went wrong:
    ///
    ///   * a filesystem error: `Delete the <gone> from "./f.txt"` is fine; the
    ///     path being missing rather than undeletable is not in the statement
    ///     (GitLab #493).
    ///   * an unknown Compute qualifier: the name does not exist, and nothing
    ///     in the line says so (GitLab #486).
    ///   * a repository scope that cannot resolve: `Cannot store the item into
    ///     the cart-repository.` reads fine and says nothing about sessions
    ///     (ARO-0094 §7.1).
    ///
    /// Deliberately an allowlist of ARO's *own* curated errors. Appending
    /// whatever the underlying error said is how a compiled binary ends up
    /// printing an `NSCocoaErrorDomain` dump with a file URL in it, which is
    /// the leak GitLab #692 removed.
    ///
    /// Shared so the interpreter and the compiled bridge give the same answer:
    /// they had separate paths, and only the interpreter's carried a hint.
    public static func curatedHint(for error: any Error) -> String? {
        if let fsError = error as? FileSystemError {
            return fsError.description
        }
        if let scopeError = error as? RepositoryScopeError {
            return scopeError.description + "."
        }
        if let actionError = error as? ActionError,
           case .unknownComputation = actionError {
            return actionError.description
        }
        return nil
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

    /// A user-defined action recursed past the call-depth budget (GitLab #473).
    ///
    /// Its own case, not a `statementFailed`, so the statement-shaped wrapping
    /// in `FeatureSetExecutor` lets it through: every frame on the way out is a
    /// call site of the same recursion, and rewrapping at each one would
    /// replace the message that says what actually happened with the last
    /// statement that noticed.
    case callDepthExceeded(String)

    /// A Compute qualifier that resolves to no built-in, no
    /// registered plugin qualifier and no date offset (GitLab #486).
    /// Carries the known names so the message can suggest the
    /// closest one. When the qualifier was one stage of a chain
    /// (`a|b`, GitLab #492), `chain` carries the full chain so the
    /// message can name the stage without losing where it sat.
    case unknownComputation(name: String, known: Set<String>, chain: String?)

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

    /// Missing required field or clause for an action
    /// e.g. "Copy requires a destination path"
    case missingRequiredField(field: String, action: String)

    /// Invalid URL — must start with http:// or https://
    case invalidURL(String)

    /// Feature not available on the current platform
    case unsupportedPlatform(String)

    /// A service (HTTP server, socket server) failed to start
    case serviceStartFailed(service: String, port: Int?)

    /// An argument has an invalid value; validValues lists acceptable ones when known
    case invalidArgument(argument: String, value: String, validValues: [String]?)

    /// A published variable was accessed outside its declaring business activity
    case scopeViolation(variable: String, sourceActivity: String, accessedFrom: String)

    /// A plugin threw an error or returned an unexpected result
    case pluginError(plugin: String, underlying: String)

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
        case .callDepthExceeded(let message):
            return "Runtime Error: \(message)"
        case .unknownComputation(let name, let known, let chain):
            var message = "Unknown Compute qualifier: '\(name)'"
            if let chain {
                message += " (stage of the chain '\(chain)')"
            }
            if let suggestion = ActionError.closestName(to: name, in: known) {
                message += " — did you mean '\(suggestion)'?"
            }
            return message
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
        case .missingRequiredField(let field, let action):
            return "'\(action)' requires \(field)"
        case .invalidURL(let url):
            return "Invalid URL '\(url)': must start with http:// or https://"
        case .unsupportedPlatform(let feature):
            return "\(feature) is not available on this platform"
        case .serviceStartFailed(let service, let port):
            if let port {
                return "Failed to start \(service) on port \(port)"
            }
            return "Failed to start \(service)"
        case .invalidArgument(let argument, let value, let validValues):
            if let valid = validValues, !valid.isEmpty {
                return "Invalid value '\(value)' for \(argument). Valid values: \(valid.joined(separator: ", "))"
            }
            return "Invalid value '\(value)' for \(argument)"
        case .scopeViolation(let variable, let sourceActivity, let accessedFrom):
            return "Variable '\(variable)' is not accessible from '\(accessedFrom)': it was published in '\(sourceActivity)'"
        case .pluginError(let plugin, let underlying):
            return "Plugin '\(plugin)' error: \(underlying)"
        case .runtimeError(let msg):
            return "Runtime error: \(msg)"
        }
    }
}

// MARK: - Suggestions

extension ActionError {
    /// Closest name in `candidates` by edit distance, or nil when
    /// nothing is near enough to be worth suggesting. The threshold
    /// scales with the typo's length so `sum` doesn't get matched to
    /// every three-letter name, while `uppercse` still finds
    /// `uppercase`.
    static func closestName(to name: String, in candidates: Set<String>) -> String? {
        let needle = name.lowercased()
        var best: (name: String, distance: Int)? = nil
        for candidate in candidates {
            let distance = EditDistance.levenshtein(needle, candidate.lowercased())
            if best == nil || distance < best!.distance {
                best = (candidate, distance)
            }
        }
        guard let best else { return nil }
        let budget = max(1, needle.count / 3)
        return best.distance <= budget ? best.name : nil
    }
}

// MARK: - LocalizedError

extension ActionError: LocalizedError {
    public var errorDescription: String? {
        description
    }
}
