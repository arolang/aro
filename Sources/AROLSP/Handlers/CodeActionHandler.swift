// ============================================================
// CodeActionHandler.swift
// AROLSP - Code Actions Provider
// ============================================================

#if !os(Windows)
import Foundation
import AROParser
import LanguageServerProtocol

/// Handles textDocument/codeAction requests
public struct CodeActionHandler: Sendable {

    /// Known action verbs for spell checking
    private static let knownVerbs: Set<String> = [
        // REQUEST
        "Extract", "Parse", "Retrieve", "Fetch", "Read", "Accept", "List", "Stat", "Exists",
        "Receive", "Prompt", "Select", "Request",
        // OWN
        "Create", "Compute", "Validate", "Compare", "Transform", "Filter", "Match", "Split",
        "Set", "Merge", "Copy", "Move", "Append", "Update", "Sort", "Delete", "Join", "Map",
        "Reduce", "Group", "Execute", "Call", "ParseHtml", "ParseLinkHeader", "Clear", "Render",
        // RESPONSE
        "Return", "Throw", "Broadcast",
        // EXPORT
        "Send", "Log", "Store", "Write", "Emit", "Publish", "Notify", "Stream",
        // SERVER
        "Start", "Stop", "Keepalive", "Wait", "WaitForEvents", "Schedule", "Sleep",
        "Listen", "Connect", "Close", "Make", "Watch", "Configure",
        // TEST
        "Given", "When", "Then", "Assert"
    ]

    public init() {}

    /// Handle a code action request
    public func handle(
        uri: String,
        range: (start: Position, end: Position),
        diagnostics: [[String: Any]],
        content: String,
        compilationResult: CompilationResult?
    ) -> [[String: Any]] {
        var actions: [[String: Any]] = []

        // Process diagnostic-based code actions
        for diagnostic in diagnostics {
            if let message = diagnostic["message"] as? String {
                actions.append(contentsOf: actionsForDiagnostic(message: message, uri: uri, range: range, diagnostic: diagnostic))
            }
        }

        // Add context-based code actions
        if let result = compilationResult {
            actions.append(contentsOf: contextActions(result: result, uri: uri, range: range, content: content))
        }

        return actions
    }

    // MARK: - Diagnostic-Based Actions

    private func actionsForDiagnostic(
        message: String,
        uri: String,
        range: (start: Position, end: Position),
        diagnostic: [String: Any]
    ) -> [[String: Any]] {
        var actions: [[String: Any]] = []

        // Check for unknown action verb
        if message.contains("Unknown action") || message.contains("unknown verb") {
            // Try to extract the unknown verb and suggest similar ones
            if let verb = extractVerbFromMessage(message) {
                let suggestions = findSimilarVerbs(verb)
                for suggestion in suggestions {
                    actions.append(createReplaceAction(
                        title: "Did you mean '\(suggestion)'?",
                        uri: uri,
                        range: range,
                        newText: "<\(suggestion)>",
                        diagnostic: diagnostic
                    ))
                }
            }
        }

        // Check for missing preposition
        if message.contains("expected preposition") || message.contains("Expected preposition") {
            actions.append(createInsertAction(
                title: "Add preposition 'from'",
                uri: uri,
                position: range.end,
                text: "from ",
                diagnostic: diagnostic
            ))
        }

        // Check for missing article
        if message.contains("expected article") || message.contains("Expected article") {
            actions.append(createInsertAction(
                title: "Add article 'the'",
                uri: uri,
                position: range.end,
                text: "the ",
                diagnostic: diagnostic
            ))
        }

        // Check for missing period
        if message.contains("expected '.'") || message.contains("Expected '.'") {
            actions.append(createInsertAction(
                title: "Add missing period",
                uri: uri,
                position: range.end,
                text: ".",
                diagnostic: diagnostic
            ))
        }

        return actions
    }

    // MARK: - Context-Based Actions

    private func contextActions(
        result: CompilationResult,
        uri: String,
        range: (start: Position, end: Position),
        content: String
    ) -> [[String: Any]] {
        var actions: [[String: Any]] = []
        let aroPosition = PositionConverter.fromLSP(range.start, in: content)

        for analyzed in result.analyzedProgram.featureSets {
            let fs = analyzed.featureSet

            // Check if cursor is in this feature set
            if fs.span.contains(aroPosition) {
                // Check if feature set is missing a Return statement
                let hasReturn = fs.statements.contains { statement in
                    if let aro = statement as? AROStatement {
                        return aro.action.verb.uppercased() == "RETURN"
                    }
                    return false
                }

                if !hasReturn {
                    // Find the end of the feature set body to insert Return
                    let insertPosition = Position(
                        line: fs.span.end.line - 1,
                        character: 4
                    )
                    actions.append(createInsertAction(
                        title: "Add Return statement",
                        uri: uri,
                        position: insertPosition,
                        text: "    Return an <OK: status> for the <result>.\n",
                        diagnostic: nil
                    ))
                }
            }
        }

        return actions
    }

    // MARK: - Helpers

    private func extractVerbFromMessage(_ message: String) -> String? {
        // Try to extract a verb from error messages like "Unknown action 'Extrct'"
        let patterns = [
            "'([A-Za-z]+)'",
            "\"([A-Za-z]+)\""
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
               let range = Range(match.range(at: 1), in: message) {
                return String(message[range])
            }
        }

        return nil
    }

    private func findSimilarVerbs(_ input: String) -> [String] {
        let lowercaseInput = input.lowercased()
        var matches: [(String, Int)] = []

        for verb in Self.knownVerbs {
            let distance = EditDistance.levenshtein(lowercaseInput, verb.lowercased())
            if distance <= 3 {
                matches.append((verb, distance))
            }
        }

        // Sort by distance and return top 3
        return matches.sorted { $0.1 < $1.1 }.prefix(3).map { $0.0 }
    }

    private func createReplaceAction(
        title: String,
        uri: String,
        range: (start: Position, end: Position),
        newText: String,
        diagnostic: [String: Any]?
    ) -> [String: Any] {
        var action: [String: Any] = [
            "title": title,
            "kind": "quickfix",
            "edit": [
                "changes": [
                    uri: [
                        [
                            "range": [
                                "start": ["line": range.start.line, "character": range.start.character],
                                "end": ["line": range.end.line, "character": range.end.character]
                            ],
                            "newText": newText
                        ]
                    ]
                ]
            ]
        ]

        if let diag = diagnostic {
            action["diagnostics"] = [diag]
        }

        return action
    }

    private func createInsertAction(
        title: String,
        uri: String,
        position: Position,
        text: String,
        diagnostic: [String: Any]?
    ) -> [String: Any] {
        var action: [String: Any] = [
            "title": title,
            "kind": "quickfix",
            "edit": [
                "changes": [
                    uri: [
                        [
                            "range": [
                                "start": ["line": position.line, "character": position.character],
                                "end": ["line": position.line, "character": position.character]
                            ],
                            "newText": text
                        ]
                    ]
                ]
            ]
        ]

        if let diag = diagnostic {
            action["diagnostics"] = [diag]
        }

        return action
    }
}

#endif
