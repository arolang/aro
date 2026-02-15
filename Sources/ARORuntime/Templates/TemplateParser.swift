// ============================================================
// TemplateParser.swift
// ARO Runtime - Template Parser (ARO-0050)
// ============================================================

import Foundation
import AROParser

/// Represents a segment of a parsed template
public enum TemplateSegment: Sendable, Equatable {
    /// Static text that passes through unchanged
    case staticText(String)

    /// Expression shorthand: {{ <variable> }} or {{ <expression> }}
    case expressionShorthand(String)

    /// Full ARO statements: {{ <Statement>. <Statement>. }}
    case statements(String)

    /// For-each loop opening: {{ for each <item> in <collection> { }}
    case forEachOpen(ForEachConfig)

    /// For-each loop closing: {{ } }}
    case forEachClose
}

/// Configuration for a for-each loop in templates
public struct ForEachConfig: Sendable, Equatable {
    /// The item variable name (e.g., "user")
    public let itemVariable: String

    /// Optional index variable name (e.g., "idx")
    public let indexVariable: String?

    /// The collection expression (e.g., "users" or "category: products")
    public let collection: String

    public init(itemVariable: String, indexVariable: String? = nil, collection: String) {
        self.itemVariable = itemVariable
        self.indexVariable = indexVariable
        self.collection = collection
    }
}

/// Parsed template ready for execution
public struct ParsedTemplate: Sendable {
    /// The template file path (for error messages)
    public let path: String

    /// The parsed segments
    public let segments: [TemplateSegment]

    public init(path: String, segments: [TemplateSegment]) {
        self.path = path
        self.segments = segments
    }
}

/// Error during template parsing
public enum TemplateParseError: Error, LocalizedError {
    case unclosedBlock(line: Int)
    case invalidForEachSyntax(line: Int, detail: String)
    case unmatchedForEachClose(line: Int)
    case nestedForEachNotClosed(line: Int)

    public var errorDescription: String? {
        switch self {
        case .unclosedBlock(let line):
            return "Template parse error at line \(line): Unclosed execution block - expected }}"
        case .invalidForEachSyntax(let line, let detail):
            return "Template parse error at line \(line): Invalid for-each syntax - \(detail)"
        case .unmatchedForEachClose(let line):
            return "Template parse error at line \(line): Unexpected }} - no matching for-each block"
        case .nestedForEachNotClosed(let line):
            return "Template parse error at line \(line): Unclosed for-each block"
        }
    }
}

/// Parser for ARO template files
public struct TemplateParser {
    public init() {}

    /// Parse a template string into segments
    /// - Parameters:
    ///   - content: The template content
    ///   - path: The template file path (for error messages)
    /// - Returns: A parsed template
    /// - Throws: TemplateParseError if the template is malformed
    public func parse(_ content: String, path: String = "<inline>") throws -> ParsedTemplate {
        var segments: [TemplateSegment] = []
        var currentIndex = content.startIndex
        var forEachDepth = 0

        while currentIndex < content.endIndex {
            // Look for the next {{
            if let blockStart = content.range(of: "{{", range: currentIndex..<content.endIndex) {
                // Add any static text before the block
                if currentIndex < blockStart.lowerBound {
                    let staticText = String(content[currentIndex..<blockStart.lowerBound])
                    if !staticText.isEmpty {
                        segments.append(.staticText(staticText))
                    }
                }

                // Find the closing }}
                guard let blockEnd = content.range(of: "}}", range: blockStart.upperBound..<content.endIndex) else {
                    let line = lineNumber(at: blockStart.lowerBound, in: content)
                    throw TemplateParseError.unclosedBlock(line: line)
                }

                // Extract the block content
                let blockContent = String(content[blockStart.upperBound..<blockEnd.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)

                // Parse the block content
                let segment = try parseBlockContent(blockContent, line: lineNumber(at: blockStart.lowerBound, in: content))

                // Track for-each depth
                switch segment {
                case .forEachOpen:
                    forEachDepth += 1
                case .forEachClose:
                    forEachDepth -= 1
                    if forEachDepth < 0 {
                        let line = lineNumber(at: blockStart.lowerBound, in: content)
                        throw TemplateParseError.unmatchedForEachClose(line: line)
                    }
                default:
                    break
                }

                segments.append(segment)
                currentIndex = blockEnd.upperBound
            } else {
                // No more blocks, add remaining static text
                let remainingText = String(content[currentIndex...])
                if !remainingText.isEmpty {
                    segments.append(.staticText(remainingText))
                }
                break
            }
        }

        // Check for unclosed for-each blocks
        if forEachDepth > 0 {
            throw TemplateParseError.nestedForEachNotClosed(line: lineNumber(at: content.endIndex, in: content))
        }

        return ParsedTemplate(path: path, segments: segments)
    }

    /// Parse the content inside a {{ }} block
    private func parseBlockContent(_ content: String, line: Int) throws -> TemplateSegment {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)

        // Check for for-each close: }
        if trimmed == "}" {
            return .forEachClose
        }

        // Check for for-each open: for each <item> in <collection> {
        if trimmed.hasPrefix("for each") || trimmed.hasPrefix("for-each") {
            return try parseForEach(trimmed, line: line)
        }

        // Check for match expression (multi-line)
        if trimmed.hasPrefix("match") {
            return .statements(trimmed)
        }

        // Check if it's a simple expression (no period at the end, starts with <)
        // e.g., {{ <user: name> }} or {{ <count> }}
        if trimmed.hasPrefix("<") && !trimmed.contains(".") {
            return .expressionShorthand(trimmed)
        }

        // Check for expression with operators (no statement structure)
        // e.g., {{ <price> * 1.1 }} or {{ <first> ++ " " ++ <last> }}
        if trimmed.hasPrefix("<") && !trimmed.hasSuffix(".") {
            // Check if it looks like an expression (has operators but no action verbs)
            let hasOperator = trimmed.contains(" * ") || trimmed.contains(" + ") ||
                              trimmed.contains(" - ") || trimmed.contains(" / ") ||
                              trimmed.contains(" ++ ") || trimmed.contains(" = ") ||
                              trimmed.contains(" > ") || trimmed.contains(" < ")
            let hasAction = trimmed.contains("<Compute>") || trimmed.contains("<Print>") ||
                            trimmed.contains("<Extract>") || trimmed.contains("<Create>") ||
                            trimmed.contains("<Return>") || trimmed.contains("<Include>")

            if hasOperator && !hasAction {
                return .expressionShorthand(trimmed)
            }

            // Simple variable reference
            if !hasAction {
                return .expressionShorthand(trimmed)
            }
        }

        // Otherwise, treat as ARO statements
        return .statements(trimmed)
    }

    /// Parse a for-each block opening
    private func parseForEach(_ content: String, line: Int) throws -> TemplateSegment {
        // Expected format: for each <item> [at <index>] in <collection> {
        // or: for each <item> [at <index>] in <collection> where <condition> {

        var remaining = content
            .replacingOccurrences(of: "for each", with: "")
            .replacingOccurrences(of: "for-each", with: "")
            .trimmingCharacters(in: .whitespaces)

        // Must end with {
        guard remaining.hasSuffix("{") else {
            throw TemplateParseError.invalidForEachSyntax(line: line, detail: "expected '{' at end")
        }
        remaining = String(remaining.dropLast()).trimmingCharacters(in: .whitespaces)

        // Parse item variable: <item>
        guard let itemStart = remaining.firstIndex(of: "<"),
              let itemEnd = remaining.firstIndex(of: ">"),
              itemStart < itemEnd else {
            throw TemplateParseError.invalidForEachSyntax(line: line, detail: "expected <item> variable")
        }

        let itemVariable = String(remaining[remaining.index(after: itemStart)..<itemEnd])
        remaining = String(remaining[remaining.index(after: itemEnd)...]).trimmingCharacters(in: .whitespaces)

        // Check for optional "at <index>"
        var indexVariable: String? = nil
        if remaining.hasPrefix("at") {
            remaining = String(remaining.dropFirst(2)).trimmingCharacters(in: .whitespaces)

            guard let indexStart = remaining.firstIndex(of: "<"),
                  let indexEnd = remaining.firstIndex(of: ">"),
                  indexStart < indexEnd else {
                throw TemplateParseError.invalidForEachSyntax(line: line, detail: "expected <index> variable after 'at'")
            }

            indexVariable = String(remaining[remaining.index(after: indexStart)..<indexEnd])
            remaining = String(remaining[remaining.index(after: indexEnd)...]).trimmingCharacters(in: .whitespaces)
        }

        // Expect "in"
        guard remaining.hasPrefix("in") else {
            throw TemplateParseError.invalidForEachSyntax(line: line, detail: "expected 'in' keyword")
        }
        remaining = String(remaining.dropFirst(2)).trimmingCharacters(in: .whitespaces)

        // Parse collection: <collection> or <collection: property>
        guard let collStart = remaining.firstIndex(of: "<"),
              let collEnd = remaining.lastIndex(of: ">"),
              collStart < collEnd else {
            throw TemplateParseError.invalidForEachSyntax(line: line, detail: "expected <collection> expression")
        }

        let collection = String(remaining[remaining.index(after: collStart)..<collEnd])

        return .forEachOpen(ForEachConfig(
            itemVariable: itemVariable,
            indexVariable: indexVariable,
            collection: collection
        ))
    }

    /// Calculate line number for a position in the content
    private func lineNumber(at position: String.Index, in content: String) -> Int {
        let prefix = content[..<position]
        return prefix.filter { $0 == "\n" }.count + 1
    }
}
