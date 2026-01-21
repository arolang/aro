// ============================================================
// CodeActionHandler.swift
// AROLSP - Code Action Provider
// ============================================================

#if !os(Windows)
import Foundation
import AROParser
import LanguageServerProtocol

/// Handles textDocument/codeAction requests
public struct CodeActionHandler: Sendable {

    // Known action verbs for typo correction
    private static let knownActions = [
        "Extract", "Parse", "Retrieve", "Fetch", "Accept",
        "Create", "Compute", "Validate", "Compare", "Transform", "Set", "Merge",
        "Return", "Throw",
        "Send", "Log", "Store", "Write", "Emit", "Publish",
        "Start", "Stop", "Keepalive", "Watch",
        "Given", "When", "Then", "Assert"
    ]

    public init() {}

    /// Handle a code action request
    public func handle(
        uri: String,
        range: LSPRange,
        diagnostics: [AROParser.Diagnostic]
    ) -> [[String: Any]]? {
        var actions: [[String: Any]] = []

        for diagnostic in diagnostics {
            // Check for typo suggestions
            if diagnostic.message.contains("Unknown action") ||
               diagnostic.message.contains("unknown action") {
                if let typoActions = suggestTypoCorrections(diagnostic: diagnostic, uri: uri) {
                    actions.append(contentsOf: typoActions)
                }
            }

            // Check for missing preposition
            if diagnostic.message.contains("expected preposition") ||
               diagnostic.message.contains("Expected preposition") {
                if let fixAction = suggestPrepositionFix(diagnostic: diagnostic, uri: uri) {
                    actions.append(fixAction)
                }
            }

            // Check for missing article
            if diagnostic.message.contains("expected article") ||
               diagnostic.message.contains("Expected article") {
                if let fixAction = suggestArticleFix(diagnostic: diagnostic, uri: uri) {
                    actions.append(fixAction)
                }
            }

            // Check for missing period
            if diagnostic.message.contains("expected '.'") ||
               diagnostic.message.contains("Expected '.'") {
                if let fixAction = suggestPeriodFix(diagnostic: diagnostic, uri: uri) {
                    actions.append(fixAction)
                }
            }
        }

        return actions.isEmpty ? nil : actions
    }

    // MARK: - Typo Corrections

    private func suggestTypoCorrections(diagnostic: AROParser.Diagnostic, uri: String) -> [[String: Any]]? {
        // Extract the misspelled action from the message
        let message = diagnostic.message
        guard let actionName = extractMisspelledAction(from: message) else { return nil }

        // Find similar actions using Levenshtein distance
        let suggestions = Self.knownActions.filter { action in
            levenshteinDistance(actionName.lowercased(), action.lowercased()) <= 2
        }

        if suggestions.isEmpty { return nil }

        guard let location = diagnostic.location else { return nil }
        let lspPosition = PositionConverter.toLSP(location)

        return suggestions.map { suggestion in
            return [
                "title": "Replace with '\(suggestion)'",
                "kind": "quickfix",
                "diagnostics": [
                    [
                        "range": [
                            "start": ["line": lspPosition.line, "character": lspPosition.character],
                            "end": ["line": lspPosition.line, "character": lspPosition.character + actionName.count + 2]
                        ],
                        "message": diagnostic.message,
                        "severity": 1
                    ]
                ],
                "edit": [
                    "changes": [
                        uri: [
                            [
                                "range": [
                                    "start": ["line": lspPosition.line, "character": lspPosition.character],
                                    "end": ["line": lspPosition.line, "character": lspPosition.character + actionName.count + 2]
                                ],
                                "newText": "<\(suggestion)>"
                            ]
                        ]
                    ]
                ]
            ]
        }
    }

    private func extractMisspelledAction(from message: String) -> String? {
        // Try to extract action name from messages like "Unknown action 'Extrct'"
        if let range = message.range(of: "'([^']+)'", options: .regularExpression) {
            let match = message[range]
            return String(match.dropFirst().dropLast())
        }
        return nil
    }

    // MARK: - Preposition Fix

    private func suggestPrepositionFix(diagnostic: AROParser.Diagnostic, uri: String) -> [String: Any]? {
        guard let location = diagnostic.location else { return nil }
        let lspPosition = PositionConverter.toLSP(location)

        // Suggest the most common preposition based on context
        let suggestedPreposition = "from"  // Default suggestion

        return [
            "title": "Add preposition '\(suggestedPreposition)'",
            "kind": "quickfix",
            "edit": [
                "changes": [
                    uri: [
                        [
                            "range": [
                                "start": ["line": lspPosition.line, "character": lspPosition.character],
                                "end": ["line": lspPosition.line, "character": lspPosition.character]
                            ],
                            "newText": "\(suggestedPreposition) "
                        ]
                    ]
                ]
            ]
        ]
    }

    // MARK: - Article Fix

    private func suggestArticleFix(diagnostic: AROParser.Diagnostic, uri: String) -> [String: Any]? {
        guard let location = diagnostic.location else { return nil }
        let lspPosition = PositionConverter.toLSP(location)

        return [
            "title": "Add article 'the'",
            "kind": "quickfix",
            "edit": [
                "changes": [
                    uri: [
                        [
                            "range": [
                                "start": ["line": lspPosition.line, "character": lspPosition.character],
                                "end": ["line": lspPosition.line, "character": lspPosition.character]
                            ],
                            "newText": "the "
                        ]
                    ]
                ]
            ]
        ]
    }

    // MARK: - Period Fix

    private func suggestPeriodFix(diagnostic: AROParser.Diagnostic, uri: String) -> [String: Any]? {
        guard let location = diagnostic.location else { return nil }
        let lspPosition = PositionConverter.toLSP(location)

        return [
            "title": "Add missing period",
            "kind": "quickfix",
            "edit": [
                "changes": [
                    uri: [
                        [
                            "range": [
                                "start": ["line": lspPosition.line, "character": lspPosition.character],
                                "end": ["line": lspPosition.line, "character": lspPosition.character]
                            ],
                            "newText": "."
                        ]
                    ]
                ]
            ]
        ]
    }

    // MARK: - Levenshtein Distance

    private func levenshteinDistance(_ s1: String, _ s2: String) -> Int {
        let s1Array = Array(s1)
        let s2Array = Array(s2)
        let m = s1Array.count
        let n = s2Array.count

        if m == 0 { return n }
        if n == 0 { return m }

        var matrix = [[Int]](repeating: [Int](repeating: 0, count: n + 1), count: m + 1)

        for i in 0...m { matrix[i][0] = i }
        for j in 0...n { matrix[0][j] = j }

        for i in 1...m {
            for j in 1...n {
                let cost = s1Array[i - 1] == s2Array[j - 1] ? 0 : 1
                matrix[i][j] = min(
                    matrix[i - 1][j] + 1,      // deletion
                    matrix[i][j - 1] + 1,      // insertion
                    matrix[i - 1][j - 1] + cost // substitution
                )
            }
        }

        return matrix[m][n]
    }
}

#endif
