// ============================================================
// FormattingHandler.swift
// AROLSP - Code Formatting Provider
// ============================================================

#if !os(Windows)
import Foundation
import AROParser
import LanguageServerProtocol

/// Formatting options from the client
public struct FormattingOptions: Sendable {
    public let tabSize: Int
    public let insertSpaces: Bool

    public init(tabSize: Int, insertSpaces: Bool) {
        self.tabSize = tabSize
        self.insertSpaces = insertSpaces
    }
}

/// Handles textDocument/formatting requests
public struct FormattingHandler: Sendable {

    public init() {}

    /// Handle a formatting request
    public func handle(
        content: String,
        options: FormattingOptions
    ) -> [[String: Any]]? {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.isEmpty || (lines.count == 1 && lines[0].isEmpty) {
            return nil
        }

        let indent = options.insertSpaces ? String(repeating: " ", count: options.tabSize) : "\t"
        var formattedLines: [String] = []
        var currentIndentLevel = 0
        var inFeatureSet = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                formattedLines.append("")
                continue
            }

            // Check for feature set start
            if trimmed.hasPrefix("(") && trimmed.contains("{") {
                formattedLines.append(formatFeatureSetHeader(trimmed))
                currentIndentLevel = 1
                inFeatureSet = true
                continue
            }

            // Check for feature set end
            if trimmed == "}" {
                currentIndentLevel = 0
                formattedLines.append("}")
                inFeatureSet = false
                continue
            }

            // Check for comment
            if trimmed.hasPrefix("(*") {
                formattedLines.append(String(repeating: indent, count: currentIndentLevel) + trimmed)
                continue
            }

            // Format statement
            if inFeatureSet && trimmed.hasPrefix("<") {
                let formatted = formatStatement(trimmed)
                formattedLines.append(String(repeating: indent, count: currentIndentLevel) + formatted)
                continue
            }

            // Match statement
            if trimmed.hasPrefix("match") {
                formattedLines.append(String(repeating: indent, count: currentIndentLevel) + trimmed)
                if trimmed.contains("{") && !trimmed.contains("}") {
                    currentIndentLevel += 1
                }
                continue
            }

            // When clause
            if trimmed.hasPrefix("when") {
                formattedLines.append(String(repeating: indent, count: currentIndentLevel) + trimmed)
                if trimmed.contains("{") && !trimmed.contains("}") {
                    currentIndentLevel += 1
                }
                continue
            }

            // For each loop
            if trimmed.hasPrefix("for each") {
                formattedLines.append(String(repeating: indent, count: currentIndentLevel) + trimmed)
                if trimmed.contains("{") && !trimmed.contains("}") {
                    currentIndentLevel += 1
                }
                continue
            }

            // Closing brace for nested blocks
            if trimmed.hasPrefix("}") && currentIndentLevel > 1 {
                currentIndentLevel -= 1
                formattedLines.append(String(repeating: indent, count: currentIndentLevel) + trimmed)
                continue
            }

            // Default: preserve with current indentation
            formattedLines.append(String(repeating: indent, count: currentIndentLevel) + trimmed)
        }

        let formattedContent = formattedLines.joined(separator: "\n")

        // If nothing changed, return nil
        if formattedContent == content {
            return nil
        }

        // Return a single edit that replaces the entire document
        return [[
            "range": [
                "start": ["line": 0, "character": 0],
                "end": ["line": lines.count, "character": 0]
            ],
            "newText": formattedContent
        ]]
    }

    // MARK: - Formatting Helpers

    private func formatFeatureSetHeader(_ header: String) -> String {
        // Format: (Name: Activity) {
        var result = header

        // Ensure space after colon
        if let colonRange = result.range(of: ":") {
            let afterColon = result.index(after: colonRange.lowerBound)
            if afterColon < result.endIndex && result[afterColon] != " " {
                result.insert(" ", at: afterColon)
            }
        }

        // Ensure space before {
        if let braceRange = result.range(of: "{") {
            let beforeBrace = result.index(before: braceRange.lowerBound)
            if beforeBrace >= result.startIndex && result[beforeBrace] != " " {
                result.insert(" ", at: braceRange.lowerBound)
            }
        }

        return result
    }

    private func formatStatement(_ statement: String) -> String {
        var result = statement

        // Ensure spaces around articles
        result = result.replacingOccurrences(of: ">the<", with: "> the <")
        result = result.replacingOccurrences(of: ">a<", with: "> a <")
        result = result.replacingOccurrences(of: ">an<", with: "> an <")

        // Ensure spaces around prepositions
        let prepositions = ["from", "to", "with", "for", "against", "into", "via"]
        for prep in prepositions {
            result = result.replacingOccurrences(of: ">\(prep)<", with: "> \(prep) <")
            result = result.replacingOccurrences(of: ">\(prep) ", with: "> \(prep) ")
            result = result.replacingOccurrences(of: " \(prep)<", with: " \(prep) <")
        }

        // Ensure period at end
        let trimmed = result.trimmingCharacters(in: .whitespaces)
        if !trimmed.hasSuffix(".") && trimmed.contains(">") {
            result = trimmed + "."
        }

        return result
    }
}

#endif
