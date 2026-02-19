// ============================================================
// CompletionHandler.swift
// AROLSP - Completion Provider
// ============================================================

#if !os(Windows)
import Foundation
import AROParser
import LanguageServerProtocol

/// Handles textDocument/completion requests
public struct CompletionHandler: Sendable {

    public init() {}

    /// Handle a completion request
    public func handle(
        position: Position,
        content: String,
        compilationResult: CompilationResult?,
        triggerCharacter: String?
    ) -> [String: Any] {
        var items: [[String: Any]] = []

        switch triggerCharacter {
        case "<":
            // Suggest actions and variables
            items.append(contentsOf: actionCompletions())
            if let result = compilationResult {
                items.append(contentsOf: variableCompletions(from: result))
            }

        case ":":
            // Suggest qualifiers/types
            items.append(contentsOf: qualifierCompletions())

        case ".":
            // Suggest member properties (context-dependent)
            items.append(contentsOf: memberCompletions())

        default:
            // General completions - actions, keywords, and snippets
            items.append(contentsOf: actionCompletions())
            items.append(contentsOf: keywordCompletions())
            items.append(contentsOf: snippetCompletions())
            if let result = compilationResult {
                items.append(contentsOf: variableCompletions(from: result))
            }
        }

        return [
            "isIncomplete": false,
            "items": items
        ]
    }

    // MARK: - Action Completions

    private func actionCompletions() -> [[String: Any]] {
        let actions: [(verb: String, role: String, detail: String)] = [
            // REQUEST actions
            ("Extract", "REQUEST", "Extract data from external source"),
            ("Parse", "REQUEST", "Parse structured data"),
            ("Retrieve", "REQUEST", "Retrieve from data store"),
            ("Fetch", "REQUEST", "Fetch from remote source"),
            ("Accept", "REQUEST", "Accept input"),
            ("Read", "REQUEST", "Read file contents"),
            ("List", "REQUEST", "List directory contents"),
            ("Stat", "REQUEST", "Get file metadata"),
            ("Exists", "REQUEST", "Check if file exists"),

            // OWN actions
            ("Create", "OWN", "Create new data"),
            ("Compute", "OWN", "Compute derived value"),
            ("Validate", "OWN", "Validate data"),
            ("Compare", "OWN", "Compare values"),
            ("Transform", "OWN", "Transform data structure"),
            ("Set", "OWN", "Set a value"),
            ("Merge", "OWN", "Merge data"),
            ("Filter", "OWN", "Filter collection"),
            ("Match", "OWN", "Match pattern"),
            ("Split", "OWN", "Split string"),
            ("Copy", "OWN", "Copy file"),
            ("Move", "OWN", "Move file"),
            ("Append", "OWN", "Append to collection"),

            // RESPONSE actions
            ("Return", "RESPONSE", "Return result"),
            ("Throw", "RESPONSE", "Throw error"),

            // EXPORT actions
            ("Send", "EXPORT", "Send to external system"),
            ("Log", "EXPORT", "Log message"),
            ("Store", "EXPORT", "Store to data store"),
            ("Write", "EXPORT", "Write to output"),
            ("Emit", "EXPORT", "Emit event"),
            ("Publish", "EXPORT", "Publish symbol globally"),
            ("CreateDirectory", "EXPORT", "Create directory"),

            // LIFECYCLE actions
            ("Start", "LIFECYCLE", "Start a service"),
            ("Stop", "LIFECYCLE", "Stop a service"),
            ("Keepalive", "LIFECYCLE", "Keep application running"),
            ("Watch", "LIFECYCLE", "Watch for changes"),
            ("Configure", "LIFECYCLE", "Configure service"),
            ("Request", "LIFECYCLE", "Make HTTP request"),

            // TEST actions
            ("Given", "TEST", "Test setup"),
            ("When", "TEST", "Test action"),
            ("Then", "TEST", "Test assertion"),
            ("Assert", "TEST", "Assert condition"),
        ]

        return actions.map { action in
            [
                "label": action.verb,
                "kind": 3,  // Function
                "detail": "[\(action.role)] \(action.detail)",
                "insertText": "\(action.verb)>",
                "insertTextFormat": 1  // PlainText
            ]
        }
    }

    // MARK: - Variable Completions

    private func variableCompletions(from result: CompilationResult) -> [[String: Any]] {
        var items: [[String: Any]] = []

        for analyzed in result.analyzedProgram.featureSets {
            for (name, symbol) in analyzed.symbolTable.symbols {
                let typeStr = symbol.dataType?.description ?? "Unknown"
                items.append([
                    "label": name,
                    "kind": 6,  // Variable
                    "detail": typeStr,
                    "documentation": "Source: \(symbol.source)",
                    "insertText": "\(name)>",
                    "insertTextFormat": 1
                ])
            }
        }

        return items
    }

    // MARK: - Qualifier Completions

    private func qualifierCompletions() -> [[String: Any]] {
        let qualifiers = [
            ("status", "Return status code"),
            ("body", "Request/response body"),
            ("id", "Identifier"),
            ("data", "Data payload"),
            ("message", "Message content"),
            ("error", "Error information"),
            ("result", "Operation result"),
            ("config", "Configuration"),
            // List element specifiers (ARO-0038)
            ("first", "First element of list"),
            ("last", "Last element of list"),
            ("0", "Last element (reverse index)"),
            ("1", "Second-to-last element"),
            ("2", "Third-to-last element"),
        ]

        return qualifiers.map { qualifier in
            [
                "label": qualifier.0,
                "kind": 10,  // Property
                "detail": qualifier.1,
                "insertText": " \(qualifier.0)>",
                "insertTextFormat": 1
            ]
        }
    }

    // MARK: - Member Completions

    private func memberCompletions() -> [[String: Any]] {
        // Default members for unknown types
        return typeAwareMemberCompletions(for: nil)
    }

    /// Type-aware member completions based on the variable's data type
    private func typeAwareMemberCompletions(for dataType: DataType?) -> [[String: Any]] {
        var members: [(String, String)] = []

        guard let type = dataType else {
            // Generic members for unknown types
            members = [
                ("length", "Array/string length"),
                ("count", "Element count"),
                ("first", "First element"),
                ("last", "Last element"),
                ("keys", "Map keys"),
                ("values", "Map values"),
                ("isEmpty", "True if empty"),
            ]
            return members.map { member in
                [
                    "label": member.0,
                    "kind": 10,  // Property
                    "detail": member.1,
                    "insertText": member.0,
                    "insertTextFormat": 1
                ]
            }
        }

        switch type {
        case .list:
            members = [
                ("length", "Number of elements in list"),
                ("count", "Number of elements in list"),
                ("first", "First element of list"),
                ("last", "Last element of list"),
                ("isEmpty", "True if list is empty"),
            ]
        case .map:
            members = [
                ("keys", "All keys in the map"),
                ("values", "All values in the map"),
                ("count", "Number of key-value pairs"),
                ("isEmpty", "True if map is empty"),
            ]
        case .string:
            members = [
                ("length", "Number of characters"),
                ("isEmpty", "True if string is empty"),
                ("uppercase", "Uppercase version"),
                ("lowercase", "Lowercase version"),
                ("trimmed", "Whitespace trimmed version"),
            ]
        case .integer, .float:
            members = [
                ("abs", "Absolute value"),
                ("string", "String representation"),
            ]
        case .boolean:
            members = [
                ("not", "Negated value"),
                ("string", "String representation"),
            ]
        case .schema, .unknown:
            // Generic members for unknown/schema types
            members = [
                ("length", "Array/string length"),
                ("count", "Element count"),
                ("first", "First element"),
                ("last", "Last element"),
                ("keys", "Map keys"),
                ("values", "Map values"),
                ("isEmpty", "True if empty"),
            ]
        }

        return members.map { member in
            [
                "label": member.0,
                "kind": 10,  // Property
                "detail": member.1,
                "insertText": member.0,
                "insertTextFormat": 1
            ]
        }
    }

    /// Get type-aware completions for a specific position
    public func handleWithTypeContext(
        position: Position,
        content: String,
        compilationResult: CompilationResult?,
        triggerCharacter: String?
    ) -> [String: Any] {
        var items: [[String: Any]] = []

        // For "." trigger, try to find the type of the variable before the dot
        if triggerCharacter == "." {
            if let dataType = findTypeAtPosition(position: position, content: content, compilationResult: compilationResult) {
                items.append(contentsOf: typeAwareMemberCompletions(for: dataType))
            } else {
                items.append(contentsOf: memberCompletions())
            }
        } else {
            // Delegate to regular handle for other cases
            return handle(position: position, content: content, compilationResult: compilationResult, triggerCharacter: triggerCharacter)
        }

        return [
            "isIncomplete": false,
            "items": items
        ]
    }

    /// Find the data type of the variable at the given position
    private func findTypeAtPosition(
        position: Position,
        content: String,
        compilationResult: CompilationResult?
    ) -> DataType? {
        guard let result = compilationResult else { return nil }

        // Get the line content up to the cursor
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        guard position.line < lines.count else { return nil }

        let line = String(lines[position.line])
        let prefixEnd = line.index(line.startIndex, offsetBy: min(position.character, line.count))
        let prefix = String(line[..<prefixEnd])

        // Look for variable name before the dot
        // Pattern: <variable-name>.
        let pattern = "<([a-zA-Z][a-zA-Z0-9-]*)>\\s*\\.$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: prefix, range: NSRange(prefix.startIndex..., in: prefix)),
              let varRange = Range(match.range(at: 1), in: prefix) else {
            return nil
        }

        let variableName = String(prefix[varRange])

        // Look up the variable in symbol tables
        for analyzed in result.analyzedProgram.featureSets {
            if let symbol = analyzed.symbolTable.lookup(variableName) {
                return symbol.dataType
            }
        }

        return nil
    }

    // MARK: - Keyword Completions

    private func keywordCompletions() -> [[String: Any]] {
        let keywords = [
            ("match", "Pattern matching"),
            ("when", "Condition branch"),
            ("for each", "Iteration"),
            ("if", "Conditional"),
            ("else", "Alternative branch"),
            ("repeat", "Loop"),
            ("the", "Article"),
            ("from", "Source preposition"),
            ("to", "Target preposition"),
            ("with", "Parameter preposition"),
            ("for", "Purpose preposition"),
        ]

        return keywords.map { keyword in
            [
                "label": keyword.0,
                "kind": 14,  // Keyword
                "detail": keyword.1,
                "insertText": keyword.0,
                "insertTextFormat": 1
            ]
        }
    }

    // MARK: - Snippet Completions

    private func snippetCompletions() -> [[String: Any]] {
        return [
            [
                "label": "feature set",
                "kind": 15,  // Snippet
                "detail": "Create a new feature set",
                "insertText": "(${1:feature-name}: ${2:Business Activity}) {\n\t$0\n}",
                "insertTextFormat": 2  // Snippet
            ],
            [
                "label": "aro statement",
                "kind": 15,
                "detail": "Create an ARO statement",
                "insertText": "<${1:Action}> the <${2:result}> ${3|from,to,with,for|} the <${4:object}>.",
                "insertTextFormat": 2
            ],
            [
                "label": "app start",
                "kind": 15,
                "detail": "Application start handler",
                "insertText": "(Application-Start: ${1:App Name}) {\n\tLog \"Starting...\" to the <console>.\n\t$0\n\tReturn an <OK: status> for the <startup>.\n}",
                "insertTextFormat": 2
            ],
            [
                "label": "http handler",
                "kind": 15,
                "detail": "HTTP operation handler",
                "insertText": "(${1:operationId}: ${2:API}) {\n\tExtract the <data> from the <request: body>.\n\t$0\n\tReturn an <OK: status> with <result>.\n}",
                "insertTextFormat": 2
            ],
        ]
    }
}

#endif
