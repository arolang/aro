// ============================================================
// ResponseFormatter.swift
// ARO Runtime - Context-Aware Response Formatting
// ============================================================

import Foundation

/// Formats responses and values based on output context
public struct ResponseFormatter: Sendable {

    // MARK: - Response Formatting

    /// Format a Response for the given output context
    public static func format(_ response: Response, for context: OutputContext) -> String {
        switch context {
        case .machine:
            return formatForMachine(response)
        case .human:
            return formatForHuman(response)
        case .developer:
            return formatForDeveloper(response)
        }
    }

    /// Format for machine consumption (JSON)
    private static func formatForMachine(_ response: Response) -> String {
        var json: [String: Any] = [
            "status": response.status,
            "reason": response.reason
        ]

        if !response.data.isEmpty {
            var dataDict: [String: Any] = [:]
            for (key, value) in response.data {
                dataDict[key] = unwrapValue(value)
            }
            json["data"] = dataDict
        }

        return toJSONString(json)
    }

    /// Format for human consumption (readable text with dot notation for nested objects)
    private static func formatForHuman(_ response: Response) -> String {
        var lines: [String] = []
        lines.append("[\(response.status)] \(response.reason)")

        if !response.data.isEmpty {
            let flattenedPairs = flattenForHuman(response.data, prefix: "")
            for (key, value) in flattenedPairs.sorted(by: { $0.0 < $1.0 }) {
                lines.append("  \(key): \(value)")
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Flatten nested structures using dot notation for human output
    private static func flattenForHuman(_ data: [String: AnySendable], prefix: String) -> [(String, String)] {
        var result: [(String, String)] = []

        for (key, value) in data {
            let fullKey = prefix.isEmpty ? key : "\(prefix).\(key)"
            let unwrapped = unwrapAnySendable(value)

            if let dict = unwrapped as? [String: any Sendable] {
                // Recursively flatten nested dictionaries
                let nestedPairs = flattenValueForHuman(dict, prefix: fullKey)
                result.append(contentsOf: nestedPairs)
            } else if let array = unwrapped as? [any Sendable] {
                // Arrays as comma-separated values
                let items = array.map { formatSimpleValueForHuman($0) }
                result.append((fullKey, items.sorted().joined(separator: ", ")))
            } else {
                result.append((fullKey, formatSimpleValueForHuman(unwrapped)))
            }
        }

        return result
    }

    /// Flatten any Sendable value with dot notation
    private static func flattenValueForHuman(_ value: any Sendable, prefix: String) -> [(String, String)] {
        var result: [(String, String)] = []

        if let dict = value as? [String: any Sendable] {
            for (key, val) in dict {
                let fullKey = prefix.isEmpty ? key : "\(prefix).\(key)"

                if let nestedDict = val as? [String: any Sendable] {
                    result.append(contentsOf: flattenValueForHuman(nestedDict, prefix: fullKey))
                } else if let array = val as? [any Sendable] {
                    let items = array.map { formatSimpleValueForHuman($0) }
                    result.append((fullKey, items.sorted().joined(separator: ", ")))
                } else {
                    result.append((fullKey, formatSimpleValueForHuman(val)))
                }
            }
        } else {
            result.append((prefix, formatSimpleValueForHuman(value)))
        }

        return result
    }

    /// Format a simple (non-nested) value for human output
    private static func formatSimpleValueForHuman(_ value: any Sendable) -> String {
        if let anySendable = value as? AnySendable {
            return formatSimpleValueForHuman(unwrapAnySendable(anySendable))
        }

        switch value {
        case let str as String:
            return str
        case let int as Int:
            return String(int)
        case let double as Double:
            return String(format: "%.2f", double)
        case let bool as Bool:
            return bool ? "true" : "false"
        case let response as Response:
            return "[\(response.status)] \(response.reason)"
        default:
            return String(describing: value)
        }
    }

    /// Format for developer consumption (diagnostic table)
    private static func formatForDeveloper(_ response: Response) -> String {
        // Collect all key-value pairs with flattened keys
        var pairs: [(String, String)] = []
        pairs.append(("reason", "String(\"\(response.reason)\")"))

        if !response.data.isEmpty {
            let flattened = flattenForDeveloper(response.data, prefix: "")
            pairs.append(contentsOf: flattened.sorted(by: { $0.0 < $1.0 }))
        }

        // Calculate column widths
        let keyWidth = max(pairs.map { $0.0.count }.max() ?? 10, 10)
        let valueWidth = max(pairs.map { $0.1.count }.max() ?? 20, 20)
        let totalWidth = keyWidth + valueWidth + 5  // 5 = "│ " + " │ " + "│"

        // Build the table
        var lines: [String] = []
        let header = "Response<\(response.status)>"
        let headerPadding = totalWidth - 2 - header.count
        let headerLine = "│ \(header)\(String(repeating: " ", count: max(0, headerPadding))) │"

        lines.append("┌\(String(repeating: "─", count: totalWidth - 2))┐")
        lines.append(headerLine)
        lines.append("├\(String(repeating: "─", count: keyWidth + 2))┬\(String(repeating: "─", count: valueWidth + 2))┤")

        for (key, value) in pairs {
            let keyPadded = key.padding(toLength: keyWidth, withPad: " ", startingAt: 0)
            let valuePadded = value.padding(toLength: valueWidth, withPad: " ", startingAt: 0)
            lines.append("│ \(keyPadded) │ \(valuePadded) │")
        }

        lines.append("└\(String(repeating: "─", count: keyWidth + 2))┴\(String(repeating: "─", count: valueWidth + 2))┘")

        return lines.joined(separator: "\n")
    }

    /// Flatten nested structures for developer table output
    private static func flattenForDeveloper(_ data: [String: AnySendable], prefix: String) -> [(String, String)] {
        var result: [(String, String)] = []

        for (key, value) in data {
            let fullKey = prefix.isEmpty ? key : "\(prefix).\(key)"
            let unwrapped = unwrapAnySendable(value)

            if let dict = unwrapped as? [String: any Sendable] {
                let nestedPairs = flattenValueForDeveloper(dict, prefix: fullKey)
                result.append(contentsOf: nestedPairs)
            } else {
                result.append((fullKey, formatValueForDeveloper(unwrapped)))
            }
        }

        return result
    }

    /// Flatten any Sendable value for developer output
    private static func flattenValueForDeveloper(_ value: any Sendable, prefix: String) -> [(String, String)] {
        var result: [(String, String)] = []

        if let dict = value as? [String: any Sendable] {
            for (key, val) in dict {
                let fullKey = prefix.isEmpty ? key : "\(prefix).\(key)"

                if let nestedDict = val as? [String: any Sendable] {
                    result.append(contentsOf: flattenValueForDeveloper(nestedDict, prefix: fullKey))
                } else {
                    result.append((fullKey, formatValueForDeveloper(val)))
                }
            }
        } else {
            result.append((prefix, formatValueForDeveloper(value)))
        }

        return result
    }

    // MARK: - Value Formatting

    public static func formatValue(_ value: any Sendable, for context: OutputContext) -> String {
        switch context {
        case .machine:
            return toJSONString(unwrapValue(value))
        case .human:
            return formatValueForHuman(value)
        case .developer:
            return formatValueForDeveloper(value)
        }
    }

    private static func formatValueForHuman(_ value: any Sendable) -> String {
        if let anySendable = value as? AnySendable {
            return formatValueForHuman(unwrapAnySendable(anySendable))
        }

        switch value {
        case let str as String:
            return str
        case let int as Int:
            return String(int)
        case let double as Double:
            return String(format: "%.2f", double)
        case let bool as Bool:
            return bool ? "true" : "false"
        case let dict as [String: any Sendable]:
            // Use dot notation for nested objects (context-aware console output)
            let flattened = flattenValueForHuman(dict, prefix: "")
            return flattened.sorted(by: { $0.0 < $1.0 })
                .map { "\($0.0): \($0.1)" }
                .joined(separator: "\n")
        case let array as [any Sendable]:
            let items = array.map { formatValueForHuman($0) }
            return "[\(items.joined(separator: ", "))]"
        case let response as Response:
            return "[\(response.status)] \(response.reason)"
        default:
            return String(describing: value)
        }
    }

    private static func formatValueForDeveloper(_ value: any Sendable) -> String {
        if let anySendable = value as? AnySendable {
            return formatValueForDeveloper(unwrapAnySendable(anySendable))
        }

        switch value {
        case let str as String:
            return "String(\"\(str)\")"
        case let int as Int:
            return "Int(\(int))"
        case let double as Double:
            return "Double(\(double))"
        case let bool as Bool:
            return "Bool(\(bool))"
        case let dict as [String: any Sendable]:
            let items = dict.map { "\($0.key): \(formatValueForDeveloper($0.value))" }
            return "Dict { \(items.joined(separator: ", ")) }"
        case let array as [any Sendable]:
            let typeName = array.isEmpty ? "Any" : String(describing: type(of: array.first!))
            return "Array<\(typeName)>[\(array.count)]"
        case let response as Response:
            return "Response<\(response.status)>"
        default:
            return "\(type(of: value))(\(value))"
        }
    }

    // MARK: - Helpers

    private static func unwrapValue(_ value: any Sendable) -> Any {
        if let anySendable = value as? AnySendable {
            return unwrapValue(unwrapAnySendable(anySendable))
        }

        switch value {
        case let str as String:
            return str
        case let int as Int:
            return int
        case let double as Double:
            return double
        case let bool as Bool:
            return bool
        case let dict as [String: any Sendable]:
            var result: [String: Any] = [:]
            for (k, v) in dict {
                result[k] = unwrapValue(v)
            }
            return result
        case let array as [any Sendable]:
            return array.map { unwrapValue($0) }
        default:
            return String(describing: value)
        }
    }

    private static func unwrapAnySendable(_ anySendable: AnySendable) -> any Sendable {
        if let str: String = anySendable.get() { return str }
        if let int: Int = anySendable.get() { return int }
        if let double: Double = anySendable.get() { return double }
        if let bool: Bool = anySendable.get() { return bool }
        return String(describing: anySendable)
    }

    private static func toJSONString(_ value: Any) -> String {
        do {
            let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            return String(data: data, encoding: .utf8) ?? "{}"
        } catch {
            return "{\"error\": \"serialization failed\"}"
        }
    }
}

// MARK: - Response Extension

extension Response {
    public func format(for context: OutputContext) -> String {
        ResponseFormatter.format(self, for: context)
    }

    public func toJSON() -> String {
        format(for: .machine)
    }

    public func toFormattedString() -> String {
        format(for: .human)
    }

    public func toDiagnosticString() -> String {
        format(for: .developer)
    }
}
