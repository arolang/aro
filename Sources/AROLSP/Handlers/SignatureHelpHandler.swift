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
            label: "Retrieve the <result> from the <repository> where <field> = <value> default <fallback>.",
            documentation: "Retrieves data from a repository or data store. The `default` clause provides a fallback value when no record matches the where clause.",
            parameters: [
                ParameterInfo(label: "result", documentation: "The retrieved record(s)"),
                ParameterInfo(label: "repository", documentation: "The data repository to query"),
                ParameterInfo(label: "where clause", documentation: "Optional filter condition (e.g., where id = <id>)"),
                ParameterInfo(label: "default", documentation: "Optional fallback value when no match is found")
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
        "Split": ActionSignature(
            label: "Split the <result> from the <input> by /<pattern>/.",
            documentation: "Splits a string into a list using a regex delimiter. The `by` clause accepts a regex literal (e.g., `/,/` or `/\\n/`).",
            parameters: [
                ParameterInfo(label: "result", documentation: "The resulting list of substrings"),
                ParameterInfo(label: "input", documentation: "The string to split"),
                ParameterInfo(label: "pattern", documentation: "Regex delimiter (e.g., by /,/ or by /\\n/)")
            ]
        ),
        "Join": ActionSignature(
            label: "Join the <result> from <collection> with \"separator\".",
            documentation: "Joins all elements of a collection into a single string, separated by the given separator.",
            parameters: [
                ParameterInfo(label: "result", documentation: "The joined string"),
                ParameterInfo(label: "collection", documentation: "The list or collection to join"),
                ParameterInfo(label: "separator", documentation: "The string to place between elements")
            ]
        ),
        "Schedule": ActionSignature(
            label: "Schedule the <event> with <seconds>.",
            documentation: "Schedules a recurring timer event every N seconds.",
            parameters: [
                ParameterInfo(label: "event", documentation: "The event to emit on each tick"),
                ParameterInfo(label: "seconds", documentation: "Interval in seconds")
            ]
        ),
        "Sleep": ActionSignature(
            label: "Sleep the <result> with <seconds>.",
            documentation: "Pauses execution for the specified number of seconds.",
            parameters: [
                ParameterInfo(label: "result", documentation: "The sleep result"),
                ParameterInfo(label: "seconds", documentation: "Duration to sleep in seconds")
            ]
        ),
        "WaitForEvents": ActionSignature(
            label: "WaitForEvents the <application> for the <events>.",
            documentation: "Suspends the feature set until pending events are processed. Lighter alternative to Keepalive.",
            parameters: [
                ParameterInfo(label: "application", documentation: "The application context"),
                ParameterInfo(label: "events", documentation: "The events to wait for")
            ]
        ),
        "Stream": ActionSignature(
            label: "Stream the <result> from the <source>.",
            documentation: "Streams data incrementally from a source, emitting chunks as they arrive.",
            parameters: [
                ParameterInfo(label: "result", documentation: "Each streamed chunk"),
                ParameterInfo(label: "source", documentation: "The data source to stream from")
            ]
        ),
        "Notify": ActionSignature(
            label: "Notify the <recipient> with \"message\".",
            documentation: "Sends a notification to a recipient or collection of recipients. Emits a NotificationSent event for each recipient.",
            parameters: [
                ParameterInfo(label: "recipient", documentation: "The recipient or collection of recipients"),
                ParameterInfo(label: "message", documentation: "The notification message")
            ]
        ),
        "Render": ActionSignature(
            label: "Render the <result: template> with <data>.",
            documentation: "Renders a Mustache-style template with the provided data context.",
            parameters: [
                ParameterInfo(label: "result", documentation: "The rendered output"),
                ParameterInfo(label: "template", documentation: "The template name to render"),
                ParameterInfo(label: "data", documentation: "The data context for the template")
            ]
        ),

        // Additional REQUEST actions
        "Read": ActionSignature(
            label: "Read the <result> from the <file: path>.",
            documentation: "Reads content from a file. Supports auto-format detection (JSON, YAML, CSV).",
            parameters: [
                ParameterInfo(label: "result", documentation: "The file content"),
                ParameterInfo(label: "file", documentation: "The file path to read from")
            ]
        ),
        "Request": ActionSignature(
            label: "Request the <result> from the <url> with { method: \"GET\" }.",
            documentation: "Makes an HTTP request to a URL. Supports GET, POST, PUT, DELETE methods.",
            parameters: [
                ParameterInfo(label: "result", documentation: "The HTTP response"),
                ParameterInfo(label: "url", documentation: "The URL to request"),
                ParameterInfo(label: "config", documentation: "Optional request configuration (method, headers, body)")
            ]
        ),
        "Receive": ActionSignature(
            label: "Receive the <result> from the <connection>.",
            documentation: "Receives data from a socket connection or event stream.",
            parameters: [
                ParameterInfo(label: "result", documentation: "The received data"),
                ParameterInfo(label: "connection", documentation: "The connection to receive from")
            ]
        ),
        "List": ActionSignature(
            label: "List the <result> for the <directory: path>.",
            documentation: "Lists contents of a directory.",
            parameters: [
                ParameterInfo(label: "result", documentation: "The directory listing"),
                ParameterInfo(label: "directory", documentation: "The directory path to list")
            ]
        ),
        "Stat": ActionSignature(
            label: "Stat the <result> for the <file: path>.",
            documentation: "Retrieves file or directory metadata (size, dates, permissions).",
            parameters: [
                ParameterInfo(label: "result", documentation: "The metadata object"),
                ParameterInfo(label: "file", documentation: "The file or directory path")
            ]
        ),
        "Exists": ActionSignature(
            label: "Exists the <result> for the <file: path>.",
            documentation: "Checks if a file or directory exists. Returns a boolean.",
            parameters: [
                ParameterInfo(label: "result", documentation: "Boolean existence result"),
                ParameterInfo(label: "file", documentation: "The file or directory path to check")
            ]
        ),

        // Additional OWN actions
        "Filter": ActionSignature(
            label: "Filter the <result> from the <collection> where <field> is <value>.",
            documentation: "Filters a collection based on a where clause condition.",
            parameters: [
                ParameterInfo(label: "result", documentation: "The filtered collection"),
                ParameterInfo(label: "collection", documentation: "The collection to filter"),
                ParameterInfo(label: "where", documentation: "Filter condition (where field is value)")
            ]
        ),
        "Sort": ActionSignature(
            label: "Sort the <result> from the <collection>.",
            documentation: "Sorts a collection. Use a by clause to specify the sort field.",
            parameters: [
                ParameterInfo(label: "result", documentation: "The sorted collection"),
                ParameterInfo(label: "collection", documentation: "The collection to sort")
            ]
        ),
        "Map": ActionSignature(
            label: "Map the <result> from the <collection>.",
            documentation: "Transforms each element of a collection.",
            parameters: [
                ParameterInfo(label: "result", documentation: "The transformed collection"),
                ParameterInfo(label: "collection", documentation: "The collection to transform")
            ]
        ),
        "Reduce": ActionSignature(
            label: "Reduce the <result> from the <collection> with sum(<field>).",
            documentation: "Reduces a collection to a single value using an aggregation function (sum, count, avg, min, max).",
            parameters: [
                ParameterInfo(label: "result", documentation: "The aggregated value"),
                ParameterInfo(label: "collection", documentation: "The collection to reduce"),
                ParameterInfo(label: "aggregation", documentation: "Aggregation function: sum, count, avg, min, max")
            ]
        ),
        "Group": ActionSignature(
            label: "Group the <result> from the <collection> by <field>.",
            documentation: "Groups collection elements by a field value, creating a map of field value to list of items.",
            parameters: [
                ParameterInfo(label: "result", documentation: "The grouped map"),
                ParameterInfo(label: "collection", documentation: "The collection to group"),
                ParameterInfo(label: "field", documentation: "The field to group by")
            ]
        ),
        "Update": ActionSignature(
            label: "Update the <result> with <data>.",
            documentation: "Updates or modifies a value with new data.",
            parameters: [
                ParameterInfo(label: "result", documentation: "The updated value"),
                ParameterInfo(label: "data", documentation: "The data to update with")
            ]
        ),
        "Delete": ActionSignature(
            label: "Delete the <result> from the <repository>.",
            documentation: "Deletes data from a repository or removes a file.",
            parameters: [
                ParameterInfo(label: "result", documentation: "The deletion result"),
                ParameterInfo(label: "repository", documentation: "The repository to delete from")
            ]
        ),
        "Execute": ActionSignature(
            label: "Execute the <result> with \"command\".",
            documentation: "Executes a shell command and captures the output.",
            parameters: [
                ParameterInfo(label: "result", documentation: "The command output"),
                ParameterInfo(label: "command", documentation: "The shell command to execute")
            ]
        ),
        "Call": ActionSignature(
            label: "Call the <result> from the <service: method> with { args }.",
            documentation: "Calls an external service or plugin action.",
            parameters: [
                ParameterInfo(label: "result", documentation: "The call result"),
                ParameterInfo(label: "service", documentation: "The service and method to invoke"),
                ParameterInfo(label: "args", documentation: "Arguments to pass")
            ]
        ),
        "Copy": ActionSignature(
            label: "Copy the <result> from the <source: path> to <destination: path>.",
            documentation: "Copies a file from source to destination.",
            parameters: [
                ParameterInfo(label: "result", documentation: "The copy result"),
                ParameterInfo(label: "source", documentation: "Source file path"),
                ParameterInfo(label: "destination", documentation: "Destination file path")
            ]
        ),
        "Move": ActionSignature(
            label: "Move the <result> from the <source: path> to <destination: path>.",
            documentation: "Moves a file from source to destination.",
            parameters: [
                ParameterInfo(label: "result", documentation: "The move result"),
                ParameterInfo(label: "source", documentation: "Source file path"),
                ParameterInfo(label: "destination", documentation: "Destination file path")
            ]
        ),
        "Merge": ActionSignature(
            label: "Merge the <result> from the <source> with <other>.",
            documentation: "Merges two collections or objects together.",
            parameters: [
                ParameterInfo(label: "result", documentation: "The merged result"),
                ParameterInfo(label: "source", documentation: "The base collection/object"),
                ParameterInfo(label: "other", documentation: "The collection/object to merge with")
            ]
        ),

        // Additional EXPORT actions
        "Write": ActionSignature(
            label: "Write <data> to the <file: path>.",
            documentation: "Writes data to a file. Supports auto-format serialization (JSON, YAML, CSV).",
            parameters: [
                ParameterInfo(label: "data", documentation: "The data to write"),
                ParameterInfo(label: "file", documentation: "The file path to write to")
            ]
        ),
        "Broadcast": ActionSignature(
            label: "Broadcast the <message> to the <socket-server>.",
            documentation: "Broadcasts data to all connected socket or WebSocket clients.",
            parameters: [
                ParameterInfo(label: "message", documentation: "The message to broadcast"),
                ParameterInfo(label: "target", documentation: "The server to broadcast through")
            ]
        ),

        // SERVER actions
        "Connect": ActionSignature(
            label: "Connect to <host: \"address\"> with { port: 8080 }.",
            documentation: "Establishes a TCP connection to a remote host.",
            parameters: [
                ParameterInfo(label: "host", documentation: "The host address to connect to"),
                ParameterInfo(label: "port", documentation: "The port number")
            ]
        ),
        "Close": ActionSignature(
            label: "Close the <connection>.",
            documentation: "Closes a socket connection or stops a server.",
            parameters: [
                ParameterInfo(label: "target", documentation: "The connection or server to close")
            ]
        ),
        "Make": ActionSignature(
            label: "Make the <result> to the <path: directory-path>.",
            documentation: "Creates a directory with all intermediate directories (like mkdir -p).",
            parameters: [
                ParameterInfo(label: "result", documentation: "The created directory path"),
                ParameterInfo(label: "path", documentation: "The directory path to create")
            ]
        ),
        "Configure": ActionSignature(
            label: "Configure the <service> with { key: value }.",
            documentation: "Configures a service with runtime settings (timeouts, limits, etc.).",
            parameters: [
                ParameterInfo(label: "service", documentation: "The service to configure"),
                ParameterInfo(label: "config", documentation: "Configuration key-value pairs")
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
