// ============================================================
// ReturnAction.swift
// ARO Runtime - Return: the response a feature set answers with
// ============================================================

import Foundation
import AROParser

/// Returns a response from a feature set
///
/// The Return action is a RESPONSE action that sets the output of the
/// current feature set execution. It terminates the execution flow.
///
/// ## Example
/// ```
/// <Return> an <OK: status> for a <valid: authentication>.
/// ```
public struct ReturnAction: SynchronousAction {
    public static let role: ActionRole = .response
    public static let verbs: Set<String> = ["return", "respond"]
    public static let validPrepositions: Set<Preposition> = [.for, .to, .with]

    public init() {}

    public func executeSynchronously(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) throws -> any Sendable {
        try validatePreposition(object.preposition)

        let statusName = result.base
        let reason = object.base

        // Gather any data to include in response
        var data: [String: AnySendable] = [:]

        // The same payload without the lossy flattening. `data` is what HTTP
        // and the CLI render; `structured` is what an in-process caller — a
        // user-defined action's call site above all — binds, so a returned
        // list arrives as a list rather than as its JSON text (GitLab #504).
        var structured: [String: any Sendable] = [:]

        // Check for expression from "with" clause (e.g., with { user: <user>, ... } or with <variable>)
        // Note: When with clause contains variable references, it's parsed as expression
        if let expr = context.resolveAny("_expression_") {
            if let dict = expr as? [String: any Sendable] {
                // Map literal: { key: value, ... } - preserve nested structure
                for (key, value) in dict {
                    flattenValue(value, into: &data, prefix: key, context: context)
                    structured[key] = value
                }
            } else if let array = expr as? [any Sendable] {
                // Array value - serialize to JSON
                let jsonArray = array.map { convertSendableToJSON($0) }
                if let jsonData = try? JSONSerialization.data(withJSONObject: jsonArray),
                   let jsonString = String(data: jsonData, encoding: .utf8) {
                    data["data"] = AnySendable(jsonString)
                } else {
                    // Fallback: array could not be serialized to JSON (non-serializable elements)
                    FileHandle.standardError.write(Data("[ReturnAction] Warning: array serialization failed, returning empty array\n".utf8))
                    data["data"] = AnySendable("[]")
                }
                structured["data"] = array
            } else if let str = expr as? String {
                // Simple variable that contains a JSON string - try to parse it
                if let jsonData = str.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: jsonData),
                   let dict = parsed as? [String: Any] {
                    // Variable contains JSON object - use it directly as response data
                    for (key, value) in dict {
                        addAnyValue(value, into: &data, key: key)
                        structured[key] = SendableConverter.fromJSON(value)
                    }
                } else {
                    // Plain string value
                    data["value"] = AnySendable(str)
                    structured["value"] = str
                }
            } else if let body = expr as? RequestBodyValue {  // live body: streams back out
                // Returning an unread request body writes it straight back to
                // the client, chunk by chunk (GitLab #477). Carried through the
                // response as itself; `Application.convertToHTTPResponse` turns
                // it into a chunked body without ever holding the whole.
                data["value"] = AnySendable(body)
                structured["value"] = body
            } else if let anchored = expr as? AnchoredBody {
                // Same for a body that has been anchored: the response is
                // written from the file rather than from memory.
                data["value"] = AnySendable(anchored)
                structured["value"] = anchored
            } else if let int = expr as? Int {
                data["value"] = AnySendable(int)
                structured["value"] = int
            } else if let double = expr as? Double {
                data["value"] = AnySendable(double)
                structured["value"] = double
            } else if let bool = expr as? Bool {
                data["value"] = AnySendable(bool)
                structured["value"] = bool
            }
        }

        // Check for object literal from "with" clause (for simple literals without var refs)
        if let literal = context.resolveAny("_literal_") {
            if let dict = literal as? [String: any Sendable] {
                for (key, value) in dict {
                    flattenValue(value, into: &data, prefix: key, context: context)
                    structured[key] = value
                }
            }
        }

        // Include object.base value if resolvable (skip internal names already handled above)
        let internalNames: Set<String> = ["_expression_", "_literal_", "status", "response", "application"]
        // ARO-0044: Special handling for metrics magic variable with format qualifier
        // Return an <OK: status> with <metrics: prometheus/plain/short/table>
        if object.base == "metrics",
           let metricsSnapshot = context.resolveAny("metrics") as? MetricsSnapshot {
            let format = object.specifiers.first ?? "plain"
            let formatted = MetricsFormatter.format(metricsSnapshot, as: format, context: context.outputContext)
            data["value"] = AnySendable(formatted)
            structured["value"] = formatted
        } else if !internalNames.contains(object.base), let value = context.resolveAny(object.base) {
            flattenValue(value, into: &data, prefix: object.base, context: context)
            structured[object.base] = value
        }

        // Include object specifiers as data references (skip internal names)
        for specifier in object.specifiers where !internalNames.contains(specifier) {
            if let value = context.resolveAny(specifier) {
                flattenValue(value, into: &data, prefix: specifier, context: context)
                structured[specifier] = value
            }
        }

        // If data is empty, try to add a reasonable default value from context
        // This matches compiled binary behavior which includes return values
        if data.isEmpty {
            // Try to find any non-internal variable that might be a return value
            // Common patterns: last created/modified value, greeting, message, result, etc.
            let candidateKeys = ["greeting", "message", "result", "data", "output", "value"]
            for key in candidateKeys {
                if let value = context.resolveAny(key) {
                    // Convert to string since AnySendable requires Equatable
                    if let str = value as? String {
                        data["value"] = AnySendable(str)
                    } else {
                        data["value"] = AnySendable(String(describing: value))
                    }
                    // The structured copy keeps the value itself — the
                    // `String(describing:)` above is a rendering for transport.
                    structured["value"] = value
                    break
                }
            }
        }

        let response = Response(
            status: statusName,
            reason: reason,
            data: data,
            structuredData: structured
        )

        context.setResponse(response)
        return response
    }

    /// Flatten a value into the data dictionary using dot notation for nested objects
    private func flattenValue(
        _ value: any Sendable,
        into data: inout [String: AnySendable],
        prefix: String,
        context: ExecutionContext
    ) {
        switch value {
        case let str as String:
            data[prefix] = AnySendable(str)
        case let int as Int:
            data[prefix] = AnySendable(int)
        case let double as Double:
            data[prefix] = AnySendable(double)
        case let bool as Bool:
            data[prefix] = AnySendable(bool)
        case let dict as [String: any Sendable]:
            // Recursively flatten nested dictionaries with dot notation
            for (key, nestedValue) in dict {
                let nestedPrefix = "\(prefix).\(key)"
                flattenValue(nestedValue, into: &data, prefix: nestedPrefix, context: context)
            }
        case let array as [any Sendable]:
            // Arrays are serialized as JSON strings
            let jsonArray = array.map { convertSendableToJSON($0) }
            if let jsonData = try? JSONSerialization.data(withJSONObject: jsonArray),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                data[prefix] = AnySendable(jsonString)
            } else {
                // Fallback: array could not be serialized to JSON (non-serializable elements)
                FileHandle.standardError.write(Data("[ReturnAction] Warning: array serialization failed for '\(prefix)', returning empty array\n".utf8))
                data[prefix] = AnySendable("[]")
            }
        default:
            data[prefix] = AnySendable(String(describing: value))
        }
    }

    /// Format an array item as a string
    private func formatArrayItem(_ value: any Sendable, context: ExecutionContext) -> String {
        switch value {
        case let str as String:
            if let resolved = context.resolveAny(str) {
                return formatArrayItem(resolved, context: context)
            }
            return str
        case let int as Int:
            return String(int)
        case let double as Double:
            return String(double)
        case let bool as Bool:
            return bool ? "true" : "false"
        default:
            return String(describing: value)
        }
    }

    /// Convert a Sendable value to a JSON-compatible type
    private func convertSendableToJSON(_ value: any Sendable) -> Any {
        SendableConverter.toJSON(value)
    }

    /// Add a value from JSON parsing (Any type) into the data dictionary
    /// Nested structures are serialized as JSON strings since AnySendable requires Equatable
    private func addAnyValue(_ value: Any, into data: inout [String: AnySendable], key: String) {
        switch value {
        case let str as String:
            data[key] = AnySendable(str)
        case let int as Int:
            data[key] = AnySendable(int)
        case let double as Double:
            data[key] = AnySendable(double)
        case let bool as Bool:
            data[key] = AnySendable(bool)
        case let dict as [String: Any]:
            // Nested dict - serialize as JSON string (will be parsed back for HTTP response)
            if let jsonData = try? JSONSerialization.data(withJSONObject: dict),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                data[key] = AnySendable(jsonString)
            } else {
                // Fallback: dict contains non-serializable values, use string description
                FileHandle.standardError.write(Data("[ReturnAction] Warning: dict serialization failed for '\(key)', using String(describing:)\n".utf8))
                data[key] = AnySendable(String(describing: dict))
            }
        case let array as [Any]:
            // Array - serialize as JSON string
            if let jsonData = try? JSONSerialization.data(withJSONObject: array),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                data[key] = AnySendable(jsonString)
            } else {
                // Fallback: array contains non-serializable values, use string description
                FileHandle.standardError.write(Data("[ReturnAction] Warning: array serialization failed for '\(key)', using String(describing:)\n".utf8))
                data[key] = AnySendable(String(describing: array))
            }
        default:
            data[key] = AnySendable(String(describing: value))
        }
    }
}
