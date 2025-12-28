// ============================================================
// SplitAction.swift
// ARO Runtime - Split Action Implementation (ARO-0037)
// ============================================================

import Foundation
import AROParser

/// Splits a string into parts using a regex delimiter
/// Syntax: <Split> the <parts> from <string> by /delimiter/.
public struct SplitAction: ActionImplementation {
    public static let role: ActionRole = .own
    public static let verbs: Set<String> = ["split"]
    public static let validPrepositions: Set<Preposition> = [.from]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        // Get string to split from object
        guard let input = context.resolveAny(object.base) as? String else {
            throw ActionError.undefinedVariable(object.base)
        }

        // Get regex pattern from by clause
        guard let pattern = context.resolveAny("_by_pattern_") as? String else {
            throw ActionError.missingRequiredField("by /pattern/")
        }
        let flags = (context.resolveAny("_by_flags_") as? String) ?? ""

        // Split using regex
        let parts = try splitByRegex(input, pattern: pattern, flags: flags)

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

            // Add the part before this match
            if lastEnd < matchStart {
                parts.append(String(string[lastEnd..<matchStart]))
            }

            lastEnd = matchRange.upperBound
        }

        // Add the final part after the last match
        if lastEnd < string.endIndex {
            parts.append(String(string[lastEnd...]))
        } else if lastEnd == string.endIndex && !matches.isEmpty {
            // Handle trailing delimiter - add empty string
            parts.append("")
        }

        return parts
    }
}
