// MultilineDetector.swift
// ARO REPL Multiline Input Detection
//
// Detects whether input is incomplete and needs more lines

import Foundation

/// Result of checking input completeness
public enum InputCompletionStatus: Sendable {
    case complete
    case needsMore(reason: IncompleteReason)
    case error(message: String)
}

public enum IncompleteReason: Sendable, CustomStringConvertible {
    case unclosedBrace(count: Int)
    case unclosedAngle(count: Int)
    case unclosedParen(count: Int)
    case unclosedBracket(count: Int)
    case unclosedString
    case featureSetIncomplete

    public var description: String {
        switch self {
        case .unclosedBrace(let count):
            return "unclosed brace (\(count) open)"
        case .unclosedAngle(let count):
            return "unclosed angle bracket (\(count) open)"
        case .unclosedParen(let count):
            return "unclosed parenthesis (\(count) open)"
        case .unclosedBracket(let count):
            return "unclosed bracket (\(count) open)"
        case .unclosedString:
            return "unclosed string"
        case .featureSetIncomplete:
            return "feature set incomplete"
        }
    }
}

/// Detects whether input is incomplete and needs more lines
public struct MultilineDetector: Sendable {

    /// Check if input is complete
    public static func check(_ input: String) -> InputCompletionStatus {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

        // Empty input is complete (nothing to do)
        if trimmed.isEmpty {
            return .complete
        }

        // Check for meta-commands (always complete on one line)
        if trimmed.hasPrefix(":") {
            return .complete
        }

        var braces = 0
        var angles = 0
        var parens = 0
        var brackets = 0
        var inString = false
        var inComment = false
        var escaped = false
        var i = trimmed.startIndex

        while i < trimmed.endIndex {
            let char = trimmed[i]
            let nextIndex = trimmed.index(after: i)
            let nextChar: Character? = nextIndex < trimmed.endIndex ? trimmed[nextIndex] : nil

            // Handle escape sequences
            if escaped {
                escaped = false
                i = nextIndex
                continue
            }

            if char == "\\" && inString {
                escaped = true
                i = nextIndex
                continue
            }

            // Handle comments (* ... *)
            if !inString && char == "(" && nextChar == "*" {
                inComment = true
                i = trimmed.index(after: nextIndex)
                continue
            }

            if inComment && char == "*" && nextChar == ")" {
                inComment = false
                i = trimmed.index(after: nextIndex)
                continue
            }

            if inComment {
                i = nextIndex
                continue
            }

            // Handle strings
            if char == "\"" {
                inString.toggle()
                i = nextIndex
                continue
            }

            if inString {
                i = nextIndex
                continue
            }

            // Count brackets
            switch char {
            case "{": braces += 1
            case "}": braces -= 1
            case "<": angles += 1
            case ">": angles -= 1
            case "(": parens += 1
            case ")": parens -= 1
            case "[": brackets += 1
            case "]": brackets -= 1
            default: break
            }

            i = nextIndex
        }

        // Check for unclosed constructs
        if inString {
            return .needsMore(reason: .unclosedString)
        }

        if braces > 0 {
            return .needsMore(reason: .unclosedBrace(count: braces))
        }

        if braces < 0 {
            return .error(message: "Unexpected closing brace")
        }

        if parens > 0 {
            return .needsMore(reason: .unclosedParen(count: parens))
        }

        if parens < 0 {
            return .error(message: "Unexpected closing parenthesis")
        }

        if brackets > 0 {
            return .needsMore(reason: .unclosedBracket(count: brackets))
        }

        if brackets < 0 {
            return .error(message: "Unexpected closing bracket")
        }

        // Note: We don't check angles strictly because < and > are also comparison operators
        // The parser will handle angle bracket mismatches

        return .complete
    }

    /// Check if input starts a feature set definition
    public static func isFeatureSetStart(_ input: String) -> Bool {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

        // Pattern: (Name: Activity) {
        // or (Name: Activity) when condition {
        guard trimmed.hasPrefix("(") else { return false }

        // Must contain colon and end with {
        guard trimmed.contains(":") else { return false }
        guard trimmed.hasSuffix("{") else { return false }

        // Must have closing paren before the brace
        guard let parenClose = trimmed.lastIndex(of: ")") else { return false }
        guard let braceOpen = trimmed.lastIndex(of: "{") else { return false }

        return parenClose < braceOpen
    }

    /// Extract feature set name and activity from header
    public static func parseFeatureSetHeader(_ input: String) -> (name: String, activity: String)? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmed.hasPrefix("(") else { return nil }

        // Find the closing paren
        guard let parenClose = trimmed.firstIndex(of: ")") else { return nil }

        // Extract content between parens
        let startIndex = trimmed.index(after: trimmed.startIndex)
        let content = String(trimmed[startIndex..<parenClose])

        // Split by colon
        let parts = content.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return nil }

        let name = parts[0].trimmingCharacters(in: .whitespaces)
        let activity = parts[1].trimmingCharacters(in: .whitespaces)

        return (name, activity)
    }
}
