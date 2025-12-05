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

    /// Format for human consumption (readable text)
    private static func formatForHuman(_ response: Response) -> String {
        var lines: [String] = []
        lines.append("[\(response.status)] \(response.reason)")

        if !response.data.isEmpty {
            for (key, value) in response.data.sorted(by: { $0.key < $1.key }) {
                let valueStr = formatValueForHuman(value)
                lines.append("  \(key): \(valueStr)")
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Format for developer consumption (diagnostic)
    private static func formatForDeveloper(_ response: Response) -> String {
        var lines: [String] = []
        lines.append("Response<\(response.status)> {")
        lines.append("  reason: \"\(response.reason)\"")

        if !response.data.isEmpty {
            lines.append("  data: {")
            for (key, value) in response.data.sorted(by: { $0.key < $1.key }) {
                let diagnostic = formatValueForDeveloper(value)
                lines.append("    \(key): \(diagnostic)")
            }
            lines.append("  }")
        }

        lines.append("}")
        return lines.joined(separator: "\n")
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
            let items = dict.map { "\($0.key): \(formatValueForHuman($0.value))" }
            return "{ \(items.joined(separator: ", ")) }"
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
