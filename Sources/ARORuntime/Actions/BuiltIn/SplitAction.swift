// ============================================================
// SplitAction.swift
// ARO Runtime - Split Action Implementation (ARO-0037)
// ============================================================

import Foundation
import AROParser

/// Splits a string into parts using a regex delimiter
/// Syntax: <Split> the <parts> from <string> by /delimiter/.
public struct SplitAction: SynchronousAction {
    public static let role: ActionRole = .own
    public static let verbs: Set<String> = ["split"]
    public static let validPrepositions: Set<Preposition> = [.from]

    public init() {}

    public func executeSynchronously(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) throws -> any Sendable {
        try validatePreposition(object.preposition)

        // Get string to split from object, applying specifiers for qualified access (e.g. <params: recipient>)
        guard var resolved = context.resolveAny(object.base) else {
            throw ActionError.undefinedVariable(object.base)
        }
        for spec in object.specifiers {
            if let dict = resolved as? [String: any Sendable], let nested = dict[spec] {
                resolved = nested
            } else if let dict = resolved as? [String: Any], let nested = dict[spec] {
                resolved = "\(nested)"
            }
        }
        guard let input = resolved as? String else {
            throw ActionError.undefinedVariable(object.base)
        }

        // Get regex pattern from by clause
        guard let pattern = context.resolveAny("_by_pattern_") as? String else {
            throw ActionError.missingRequiredField("by /pattern/")
        }
        let flags = (context.resolveAny("_by_flags_") as? String) ?? ""

        // Split using regex
        let parts = try splitByRegex(input, pattern: pattern, flags: flags)

        // Bind result to context
        context.bind(result.base, value: parts)

        return parts
    }

    /// Splits a string by regex pattern, returning array of parts between matches
    private func splitByRegex(_ string: String, pattern: String, flags: String) throws -> [String] {
        // Build regex options from flags
        var options: NSRegularExpression.Options = []
        if flags.contains("i") { options.insert(.caseInsensitive) }
        if flags.contains("s") { options.insert(.dotMatchesLineSeparators) }
        if flags.contains("m") { options.insert(.anchorsMatchLines) }

        let regex = try NSRegularExpression(pattern: pattern, options: options)
        let range = NSRange(string.startIndex..., in: string)
        let matches = regex.matches(in: string, range: range)

        // If no matches, return the original string as single element
        if matches.isEmpty {
            return [string]
        }

        var parts: [String] = []
        var lastEnd = string.startIndex

        for match in matches {
            guard let matchRange = Range(match.range, in: string) else { continue }
            let matchStart = matchRange.lowerBound

            // Always include the segment before this match (including empty strings
            // between adjacent delimiters — standard split behavior)
            parts.append(String(string[lastEnd..<matchStart]))

            lastEnd = matchRange.upperBound
        }

        // Always add the final segment after the last match (empty string if trailing delimiter)
        parts.append(String(string[lastEnd...]))

        return parts
    }
}
