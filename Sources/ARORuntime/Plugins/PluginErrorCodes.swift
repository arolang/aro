// ============================================================
// PluginErrorCodes.swift
// ARO Runtime - Standard Plugin Error Codes (ARO-0073)
// ============================================================

import Foundation

// MARK: - Standard Plugin Error Codes

/// Standard numeric error codes for plugin responses (ARO-0073).
///
/// Plugins return these codes in their JSON response under an `"error_code"` key.
/// The runtime maps them to descriptive error messages for the developer.
///
/// ## Usage in a C plugin
/// ```c
/// char* aro_plugin_execute(const char* action, const char* input_json) {
///     // ...
///     return "{\"error_code\": 2, \"error\": \"Record not found\"}";
/// }
/// ```
public enum PluginErrorCode: Int, Sendable, CaseIterable {
    /// Operation completed successfully (no error).
    case success = 0

    /// The input provided to the plugin was invalid or malformed.
    case invalidInput = 1

    /// The requested resource could not be found.
    case notFound = 2

    /// The caller does not have permission to perform the requested operation.
    case permissionDenied = 3

    /// The operation did not complete within the allowed time window.
    case timeout = 4

    /// A required network or service connection could not be established.
    case connectionFailed = 5

    /// The plugin failed while executing the requested operation.
    case executionFailed = 6

    /// The plugin or a resource it manages is in an invalid state.
    case invalidState = 7

    /// A required resource (memory, file handles, connections, etc.) is exhausted.
    case resourceExhausted = 8

    /// The requested action or feature is not supported by this plugin.
    case unsupported = 9

    /// The caller has exceeded an allowed request rate.
    case rateLimited = 10

    /// Human-readable description of the error code.
    public var description: String {
        switch self {
        case .success:          return "Success"
        case .invalidInput:     return "Invalid input"
        case .notFound:         return "Not found"
        case .permissionDenied: return "Permission denied"
        case .timeout:          return "Timeout"
        case .connectionFailed: return "Connection failed"
        case .executionFailed:  return "Execution failed"
        case .invalidState:     return "Invalid state"
        case .resourceExhausted: return "Resource exhausted"
        case .unsupported:      return "Unsupported"
        case .rateLimited:      return "Rate limited"
        }
    }
}

// MARK: - Plugin Error Category

/// Domain-specific category for a plugin error.
///
/// Categories group related error codes by the area of concern, which lets
/// callers apply broad retry/fallback strategies without matching individual codes.
public enum PluginErrorCategory: String, Sendable {
    /// Input validation failure (maps to `invalidInput`).
    case validation

    /// I/O or file-system error (maps to `connectionFailed`, `resourceExhausted`, etc.).
    case io

    /// Authentication or authorisation failure (maps to `permissionDenied`).
    case authentication

    /// Request-rate limit exceeded (maps to `rateLimited`).
    case rateLimiting
}

// MARK: - Plugin Error Response

/// A structured error response decoded from plugin JSON output.
///
/// Plugins may include an `"error_code"` integer, a human-readable `"error"` string,
/// an optional `"category"` tag, and arbitrary `"details"` for diagnostics.
///
/// ## Plugin JSON format
/// ```json
/// {
///   "error_code": 2,
///   "error": "User with id 42 was not found",
///   "category": "validation",
///   "details": { "id": 42, "entity": "User" }
/// }
/// ```
public struct PluginErrorResponse: Sendable {
    /// The standard error code reported by the plugin.
    public let code: PluginErrorCode

    /// Human-readable error message from the plugin.
    public let message: String

    /// Optional domain category for broad error classification.
    public let category: PluginErrorCategory?

    /// Optional additional diagnostic details provided by the plugin.
    public let details: [String: any Sendable]?

    /// Initialise directly (e.g. in tests).
    public init(
        code: PluginErrorCode,
        message: String,
        category: PluginErrorCategory? = nil,
        details: [String: any Sendable]? = nil
    ) {
        self.code = code
        self.message = message
        self.category = category
        self.details = details
    }

    /// Parse a `PluginErrorResponse` from the JSON string returned by a plugin.
    ///
    /// Returns `nil` when the JSON does not contain an `"error_code"` key, which
    /// indicates a successful (non-error) response.
    public static func parse(from json: String) -> PluginErrorResponse? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawCode = obj["error_code"] as? Int,
              let code = PluginErrorCode(rawValue: rawCode) else {
            return nil
        }

        let message = obj["error"] as? String ?? code.description
        let category = (obj["category"] as? String).flatMap { PluginErrorCategory(rawValue: $0) }
        let details: [String: any Sendable]? = (obj["details"] as? [String: Any]).map { raw in
            var result: [String: any Sendable] = [:]
            for (key, value) in raw {
                switch value {
                case let s as String:   result[key] = s
                case let i as Int:      result[key] = i
                case let d as Double:   result[key] = d
                case let b as Bool:     result[key] = b
                default:                result[key] = "\(value)"
                }
            }
            return result
        }

        return PluginErrorResponse(code: code, message: message, category: category, details: details)
    }

    /// `true` when the code is `.success` (error_code == 0).
    public var isSuccess: Bool { code == .success }
}
