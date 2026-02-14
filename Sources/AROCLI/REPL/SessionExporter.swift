// SessionExporter.swift
// ARO REPL Session Export
//
// Exports REPL sessions as .aro files

import Foundation

/// Exports a REPL session as a valid .aro file
public struct SessionExporter: Sendable {

    public init() {}

    /// Export session with all statements wrapped in a feature set
    public func export(
        session: REPLSession,
        featureSetName: String = "REPL Session",
        businessActivity: String = "Interactive"
    ) -> String {
        var output = ""

        // Comment header
        let dateFormatter = ISO8601DateFormatter()
        output += "(* Generated from ARO REPL session *)\n"
        output += "(* Date: \(dateFormatter.string(from: Date())) *)\n\n"

        // Export defined feature sets first
        for name in session.featureSetNames {
            if let source = session.featureSetSources[name] {
                output += source
                output += "\n\n"
            }
        }

        // Export successful direct statements as a new feature set
        let directStatements = session.history
            .filter { entry in
                entry.type == .statement &&
                entry.result?.isSuccess == true
            }
            .map { $0.input }

        if !directStatements.isEmpty {
            output += "(\(featureSetName): \(businessActivity)) {\n"
            for statement in directStatements {
                // Normalize indentation
                let trimmed = statement.trimmingCharacters(in: .whitespaces)
                output += "    \(trimmed)\n"
            }
            output += "}\n"
        }

        return output
    }

    /// Export as test file with assertions
    public func exportAsTest(
        session: REPLSession,
        testName: String = "REPL Test"
    ) -> String {
        var output = ""

        // Comment header
        let dateFormatter = ISO8601DateFormatter()
        output += "(* Generated test from ARO REPL session *)\n"
        output += "(* Date: \(dateFormatter.string(from: Date())) *)\n\n"

        output += "(\(testName): Test) {\n"

        // Export statements with their expected results as assertions
        for entry in session.history where entry.type == .statement {
            if case .value(let value) = entry.result {
                // Original statement
                let trimmed = entry.input.trimmingCharacters(in: .whitespaces)
                output += "    \(trimmed)\n"

                // Add assertion for the result if we can determine the variable name
                if let varName = extractResultVariable(from: entry.input) {
                    let literal = formatLiteral(value)
                    output += "    <Assert> the <\(varName)> is \(literal).\n"
                    output += "\n"
                }
            } else if case .ok = entry.result {
                // Just include the statement
                let trimmed = entry.input.trimmingCharacters(in: .whitespaces)
                output += "    \(trimmed)\n"
            }
        }

        output += "}\n"

        return output
    }

    /// Extract the result variable name from a statement
    private func extractResultVariable(from statement: String) -> String? {
        // Pattern: <Action> the <variable> ...
        // We need to find the second <...> which is the result

        var inAngle = false
        var angleCount = 0
        var currentVar = ""
        var foundVars: [String] = []

        for char in statement {
            if char == "<" {
                inAngle = true
                angleCount += 1
                currentVar = ""
                continue
            }
            if char == ">" {
                if inAngle && !currentVar.isEmpty {
                    foundVars.append(currentVar)
                }
                inAngle = false
                continue
            }
            if inAngle {
                currentVar.append(char)
            }
        }

        // The second variable is typically the result
        // First is the action verb
        guard foundVars.count >= 2 else { return nil }

        var result = foundVars[1]

        // Strip type annotation if present (e.g., "user: User" -> "user")
        if let colonIndex = result.firstIndex(of: ":") {
            result = String(result[..<colonIndex]).trimmingCharacters(in: .whitespaces)
        }

        return result
    }

    /// Format a value as an ARO literal
    private func formatLiteral(_ value: any Sendable) -> String {
        switch value {
        case let s as String:
            return "\"\(escapeString(s))\""
        case let i as Int:
            return String(i)
        case let d as Double:
            if d == d.rounded() && d < Double(Int.max) && d > Double(Int.min) {
                return String(Int(d))
            }
            return String(d)
        case let b as Bool:
            return b ? "true" : "false"
        case let array as [any Sendable]:
            let items = array.map { formatLiteral($0) }
            return "[\(items.joined(separator: ", "))]"
        case let dict as [String: any Sendable]:
            let pairs = dict.sorted { $0.key < $1.key }.map { key, val in
                "\(key): \(formatLiteral(val))"
            }
            return "{ \(pairs.joined(separator: ", ")) }"
        default:
            return String(describing: value)
        }
    }

    /// Escape special characters in strings
    private func escapeString(_ s: String) -> String {
        var result = ""
        for char in s {
            switch char {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\t": result += "\\t"
            case "\r": result += "\\r"
            default: result.append(char)
            }
        }
        return result
    }
}
