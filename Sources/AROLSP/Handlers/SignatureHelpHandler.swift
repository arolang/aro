// ============================================================
// SignatureHelpHandler.swift
// AROLSP - Signature Help Provider
// ============================================================

#if !os(Windows)
import Foundation
import AROParser
import LanguageServerProtocol

/// Handles textDocument/signatureHelp requests
public struct SignatureHelpHandler: Sendable {

    // Action signatures database
    private static let actionSignatures: [String: ActionSignature] = [
        // REQUEST actions
        "Extract": ActionSignature(
            label: "Extract the <result: qualifier> from the <source: qualifier>.",
            documentation: "Extracts or retrieves data from external sources into the local scope.",
            parameters: [
                ParameterInfo(label: "result", documentation: "The variable to store the extracted data"),
                ParameterInfo(label: "source", documentation: "The source to extract data from (e.g., request, parameters)")
            ]
        ),
        "Parse": ActionSignature(
            label: "Parse the <result: qualifier> from the <source: qualifier>.",
            documentation: "Parses structured data from a string or raw format.",
            parameters: [
                ParameterInfo(label: "result", documentation: "The parsed data structure"),
                ParameterInfo(label: "source", documentation: "The raw data to parse")
            ]
        ),
        "Retrieve": ActionSignature(
            label: "Retrieve the <result> from the <repository> where <field> = <value>.",
            documentation: "Retrieves data from a repository or data store.",
            parameters: [
                ParameterInfo(label: "result", documentation: "The retrieved record(s)"),
                ParameterInfo(label: "repository", documentation: "The data repository to query"),
                ParameterInfo(label: "where clause", documentation: "Optional filter condition")
            ]
        ),
        "Fetch": ActionSignature(
            label: "Fetch the <result> from the <url>.",
            documentation: "Fetches data from a remote URL or API endpoint.",
            parameters: [
                ParameterInfo(label: "result", documentation: "The fetched data"),
                ParameterInfo(label: "url", documentation: "The URL to fetch from")
            ]
        ),

        // OWN actions
        "Create": ActionSignature(
            label: "Create the <result> with <data>.",
            documentation: "Creates a new data structure or entity.",
            parameters: [
                ParameterInfo(label: "result", documentation: "The newly created entity"),
                ParameterInfo(label: "data", documentation: "The data to initialize with")
            ]
        ),
        "Compute": ActionSignature(
            label: "Compute the <result: operation> from <input>.",
            documentation: "Computes or transforms data. Operations: length, uppercase, lowercase, hash, arithmetic (+, -, *, /, %).",
            parameters: [
                ParameterInfo(label: "result", documentation: "The computed value"),
                ParameterInfo(label: "operation", documentation: "Optional: length, uppercase, lowercase, hash"),
                ParameterInfo(label: "input", documentation: "The input data or expression")
            ]
        ),
        "Validate": ActionSignature(
            label: "Validate the <result> for the <input>.",
            documentation: "Validates input data against rules or schemas.",
            parameters: [
                ParameterInfo(label: "result", documentation: "The validation result"),
                ParameterInfo(label: "input", documentation: "The data to validate")
            ]
        ),
        "Compare": ActionSignature(
            label: "Compare the <result> against the <other>.",
            documentation: "Compares two values and stores the comparison result.",
            parameters: [
                ParameterInfo(label: "result", documentation: "The comparison result"),
                ParameterInfo(label: "other", documentation: "The value to compare against")
            ]
        ),
        "Transform": ActionSignature(
            label: "Transform the <result> from the <input>.",
            documentation: "Transforms data from one format to another.",
            parameters: [
                ParameterInfo(label: "result", documentation: "The transformed data"),
                ParameterInfo(label: "input", documentation: "The data to transform")
            ]
        ),

        // RESPONSE actions
        "Return": ActionSignature(
            label: "Return an <status: code> for the <result>.",
            documentation: "Returns a result with a status code. Used to end feature set execution.",
            parameters: [
                ParameterInfo(label: "status", documentation: "The status code (OK, Created, Error, etc.)"),
                ParameterInfo(label: "result", documentation: "The data to return")
            ]
        ),
        "Throw": ActionSignature(
            label: "Throw an <error: type> for the <reason>.",
            documentation: "Throws an error and terminates execution.",
            parameters: [
                ParameterInfo(label: "error", documentation: "The error type"),
                ParameterInfo(label: "reason", documentation: "The error reason or message")
            ]
        ),

        // EXPORT actions
        "Log": ActionSignature(
            label: "Log <message> to the <destination>.",
            documentation: "Logs a message to a destination (console, file, etc.).",
            parameters: [
                ParameterInfo(label: "message", documentation: "The message to log"),
                ParameterInfo(label: "destination", documentation: "Where to log (console, file)")
            ]
        ),
        "Send": ActionSignature(
            label: "Send the <data> to the <destination>.",
            documentation: "Sends data to an external destination.",
            parameters: [
                ParameterInfo(label: "data", documentation: "The data to send"),
                ParameterInfo(label: "destination", documentation: "The recipient or endpoint")
            ]
        ),
        "Store": ActionSignature(
            label: "Store the <data> into the <repository>.",
            documentation: "Stores data into a repository.",
            parameters: [
                ParameterInfo(label: "data", documentation: "The data to store"),
                ParameterInfo(label: "repository", documentation: "The repository to store in")
            ]
        ),
        "Emit": ActionSignature(
            label: "Emit a <event: type> with <data>.",
            documentation: "Emits an event that can be handled by event handlers.",
            parameters: [
                ParameterInfo(label: "event", documentation: "The event name/type"),
                ParameterInfo(label: "data", documentation: "The event payload")
            ]
        ),
        "Publish": ActionSignature(
            label: "<Publish> as <external-name> <internal-variable>.",
            documentation: "Makes a variable globally accessible under an alias.",
            parameters: [
                ParameterInfo(label: "external-name", documentation: "The public name for the variable"),
                ParameterInfo(label: "internal-variable", documentation: "The variable to publish")
            ]
        ),

        // LIFECYCLE actions
        "Start": ActionSignature(
            label: "Start the <service> with <config>.",
            documentation: "Starts a service (HTTP server, file watcher, etc.).",
            parameters: [
                ParameterInfo(label: "service", documentation: "The service to start"),
                ParameterInfo(label: "config", documentation: "Configuration options")
            ]
        ),
        "Stop": ActionSignature(
            label: "Stop the <service> with <context>.",
            documentation: "Stops a running service.",
            parameters: [
                ParameterInfo(label: "service", documentation: "The service to stop"),
                ParameterInfo(label: "context", documentation: "Context or reason for stopping")
            ]
        ),
        "Keepalive": ActionSignature(
            label: "Keepalive the <application> for the <events>.",
            documentation: "Keeps the application running to process events.",
            parameters: [
                ParameterInfo(label: "application", documentation: "The application context"),
                ParameterInfo(label: "events", documentation: "The events to wait for")
            ]
        ),
    ]

    public init() {}

    /// Handle a signature help request
    public func handle(
        position: Position,
        content: String,
        compilationResult: CompilationResult?
    ) -> [String: Any]? {
        // Find the action at or near the cursor position
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        guard position.line < lines.count else { return nil }

        let currentLine = String(lines[position.line])

        // Look for an action verb at the start of a statement
        if let actionMatch = findActionInLine(currentLine) {
            if let signature = Self.actionSignatures[actionMatch] {
                return formatSignatureHelp(signature)
            }
        }

        return nil
    }

    // MARK: - Helpers

    private func findActionInLine(_ line: String) -> String? {
        // Look for ActionVerb at start of statement (after whitespace)
        let pattern = "^\\s*([A-Z][a-z]+)\\s+(?:the|an|a|<)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }

        let range = NSRange(line.startIndex..., in: line)
        if let match = regex.firstMatch(in: line, range: range) {
            if let verbRange = Range(match.range(at: 1), in: line) {
                return String(line[verbRange])
            }
        }

        return nil
    }

    private func formatSignatureHelp(_ signature: ActionSignature) -> [String: Any] {
        let parameters: [[String: Any]] = signature.parameters.map { param in
            [
                "label": param.label,
                "documentation": param.documentation
            ]
        }

        return [
            "signatures": [
                [
                    "label": signature.label,
                    "documentation": [
                        "kind": "markdown",
                        "value": signature.documentation
                    ],
                    "parameters": parameters
                ]
            ],
            "activeSignature": 0,
            "activeParameter": 0
        ]
    }
}

// MARK: - Supporting Types

private struct ActionSignature {
    let label: String
    let documentation: String
    let parameters: [ParameterInfo]
}

private struct ParameterInfo {
    let label: String
    let documentation: String
}

#endif
