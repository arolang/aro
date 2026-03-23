// ============================================================
// MCPToolProvider.swift
// ARO MCP - Tool Implementations
// ============================================================

import Foundation
import AROParser

/// Provides MCP tools for ARO operations
public struct MCPToolProvider: Sendable {

    public init() {}

    /// List all available tools
    public func listTools() -> MCPToolsListResult {
        MCPToolsListResult(tools: [
            MCPTool(
                name: "aro_check",
                description: "Check ARO code for syntax errors. Returns diagnostics if any errors are found.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "code": .object([
                            "type": .string("string"),
                            "description": .string("ARO source code to check")
                        ]),
                        "directory": .object([
                            "type": .string("string"),
                            "description": .string("Path to directory containing .aro files")
                        ])
                    ])
                ])
            ),
            MCPTool(
                name: "aro_run",
                description: "Run an ARO application from a directory. Returns the output or error.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "directory": .object([
                            "type": .string("string"),
                            "description": .string("Path to directory containing the ARO application")
                        ]),
                        "timeout": .object([
                            "type": .string("number"),
                            "description": .string("Timeout in seconds (default: 30)")
                        ]),
                        "args": .object([
                            "type": .string("array"),
                            "description": .string("Optional command-line arguments to pass to the application"),
                            "items": .object(["type": .string("string")])
                        ])
                    ]),
                    "required": .array([.string("directory")])
                ])
            ),
            MCPTool(
                name: "aro_compile",
                description: "Compile an ARO application to a native binary using aro build. Returns the output path or error.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "directory": .object([
                            "type": .string("string"),
                            "description": .string("Path to directory containing the ARO application to compile")
                        ]),
                        "optimize": .object([
                            "type": .string("boolean"),
                            "description": .string("Enable compiler optimizations (default: false)")
                        ])
                    ]),
                    "required": .array([.string("directory")])
                ])
            ),
            MCPTool(
                name: "aro_examples",
                description: "List available ARO example applications with descriptions.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "category": .object([
                            "type": .string("string"),
                            "description": .string("Filter by category: core, http, events, files, plugins, data, sockets, templates (optional)")
                        ])
                    ])
                ])
            ),
            MCPTool(
                name: "aro_actions",
                description: "List all available ARO actions with their roles, verbs, and valid prepositions.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "role": .object([
                            "type": .string("string"),
                            "description": .string("Filter by action role: request, own, response, export, server (optional)")
                        ])
                    ])
                ])
            ),
            MCPTool(
                name: "aro_parse",
                description: "Parse ARO code and return the Abstract Syntax Tree (AST) as JSON.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "code": .object([
                            "type": .string("string"),
                            "description": .string("ARO source code to parse")
                        ])
                    ]),
                    "required": .array([.string("code")])
                ])
            ),
            MCPTool(
                name: "aro_syntax",
                description: "Get ARO syntax reference with examples for common patterns.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "topic": .object([
                            "type": .string("string"),
                            "description": .string("Specific topic: feature-set, action, statement, http-api, event, repository, control-flow, plugins, state-machine, testing (optional, returns overview if not specified)")
                        ])
                    ])
                ])
            )
        ])
    }

    /// Execute a tool call
    public func callTool(name: String, arguments: JSONValue?) async -> MCPToolCallResult {
        switch name {
        case "aro_check":
            return await executeCheck(arguments: arguments)
        case "aro_run":
            return await executeRun(arguments: arguments)
        case "aro_compile":
            return await executeCompile(arguments: arguments)
        case "aro_examples":
            return executeExamples(arguments: arguments)
        case "aro_actions":
            return executeActions(arguments: arguments)
        case "aro_parse":
            return executeParse(arguments: arguments)
        case "aro_syntax":
            return executeSyntax(arguments: arguments)
        default:
            return MCPToolCallResult(
                content: [.text("Unknown tool: \(name)")],
                isError: true
            )
        }
    }

    // MARK: - Tool Implementations

    /// Check ARO code for syntax errors
    private func executeCheck(arguments: JSONValue?) async -> MCPToolCallResult {
        guard let args = arguments?.objectValue else {
            return MCPToolCallResult(
                content: [.text("Missing arguments: provide 'code' or 'directory'")],
                isError: true
            )
        }

        // Check inline code
        if let code = args["code"]?.stringValue {
            return checkCode(code)
        }

        // Check directory
        if let directory = args["directory"]?.stringValue {
            return await checkDirectory(directory)
        }

        return MCPToolCallResult(
            content: [.text("Missing arguments: provide 'code' or 'directory'")],
            isError: true
        )
    }

    private func checkCode(_ code: String) -> MCPToolCallResult {
        let compiler = Compiler()
        let result = compiler.compile(code)

        let errors = result.diagnostics.filter { $0.severity == .error }
        let warnings = result.diagnostics.filter { $0.severity == .warning }

        if errors.isEmpty {
            var message = "Syntax OK: \(result.program.featureSets.count) feature set(s) found"
            if !warnings.isEmpty {
                message += "\n\nWarnings:\n"
                for warning in warnings {
                    if let loc = warning.location {
                        message += "  Line \(loc.line): \(warning.message)\n"
                    } else {
                        message += "  \(warning.message)\n"
                    }
                }
            }
            return MCPToolCallResult(content: [.text(message)])
        } else {
            var message = "Syntax errors found:\n"
            for error in errors {
                if let loc = error.location {
                    message += "  Line \(loc.line), Column \(loc.column): \(error.message)\n"
                } else {
                    message += "  \(error.message)\n"
                }
                for hint in error.hints {
                    message += "    Hint: \(hint)\n"
                }
            }
            return MCPToolCallResult(content: [.text(message)], isError: true)
        }
    }

    private func checkDirectory(_ path: String) async -> MCPToolCallResult {
        let url = URL(fileURLWithPath: path)
        let fileManager = FileManager.default

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return MCPToolCallResult(
                content: [.text("Directory not found: \(path)")],
                isError: true
            )
        }

        // Find all .aro files synchronously
        let aroFiles = findAroFiles(in: url)

        if aroFiles.isEmpty {
            return MCPToolCallResult(
                content: [.text("No .aro files found in: \(path)")],
                isError: true
            )
        }

        var totalErrors = 0
        var totalWarnings = 0
        var messages: [String] = []

        for file in aroFiles {
            do {
                let source = try String(contentsOf: file, encoding: .utf8)
                let compiler = Compiler()
                let result = compiler.compile(source)

                let errors = result.diagnostics.filter { $0.severity == .error }
                let warnings = result.diagnostics.filter { $0.severity == .warning }

                totalErrors += errors.count
                totalWarnings += warnings.count

                if !errors.isEmpty {
                    messages.append("\(file.lastPathComponent):")
                    for error in errors {
                        if let loc = error.location {
                            messages.append("  Line \(loc.line): \(error.message)")
                        } else {
                            messages.append("  \(error.message)")
                        }
                    }
                }
            } catch {
                messages.append("\(file.lastPathComponent): Could not read file")
                totalErrors += 1
            }
        }

        if totalErrors == 0 {
            return MCPToolCallResult(
                content: [.text("All \(aroFiles.count) file(s) checked: No errors\(totalWarnings > 0 ? ", \(totalWarnings) warning(s)" : "")")]
            )
        } else {
            messages.insert("Found \(totalErrors) error(s) in \(aroFiles.count) file(s):\n", at: 0)
            return MCPToolCallResult(
                content: [.text(messages.joined(separator: "\n"))],
                isError: true
            )
        }
    }

    /// Find all .aro files in a directory (synchronous, called from async context)
    private func findAroFiles(in url: URL) -> [URL] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }

        var aroFiles: [URL] = []
        while let fileURL = enumerator.nextObject() as? URL {
            if fileURL.pathExtension == "aro" {
                aroFiles.append(fileURL)
            }
        }
        return aroFiles
    }

    /// Run an ARO application
    private func executeRun(arguments: JSONValue?) async -> MCPToolCallResult {
        guard let args = arguments?.objectValue,
              let directory = args["directory"]?.stringValue else {
            return MCPToolCallResult(
                content: [.text("Missing required argument: 'directory'")],
                isError: true
            )
        }

        let timeout = args["timeout"]?.intValue ?? 30

        // Build argument list: aro run <directory> [args...]
        var processArgs = ["aro", "run", directory]
        if let extraArgs = args["args"]?.arrayValue {
            processArgs += extraArgs.compactMap { $0.stringValue }
        }

        // Execute aro run command
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = processArgs

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()

            // Wait with timeout
            let timeoutTask = Task {
                try await Task.sleep(nanoseconds: UInt64(timeout) * 1_000_000_000)
                if process.isRunning {
                    process.terminate()
                }
            }

            process.waitUntilExit()
            timeoutTask.cancel()

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

            let output = String(data: outputData, encoding: .utf8) ?? ""
            let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

            if process.terminationStatus == 0 {
                return MCPToolCallResult(
                    content: [.text(output.isEmpty ? "Application completed successfully" : output)]
                )
            } else {
                let message = errorOutput.isEmpty ? output : errorOutput
                return MCPToolCallResult(
                    content: [.text("Application failed (exit code \(process.terminationStatus)):\n\(message)")],
                    isError: true
                )
            }
        } catch {
            return MCPToolCallResult(
                content: [.text("Failed to run application: \(error.localizedDescription)")],
                isError: true
            )
        }
    }

    /// Compile an ARO application to a native binary
    private func executeCompile(arguments: JSONValue?) async -> MCPToolCallResult {
        guard let args = arguments?.objectValue,
              let directory = args["directory"]?.stringValue else {
            return MCPToolCallResult(
                content: [.text("Missing required argument: 'directory'")],
                isError: true
            )
        }

        let optimize = args["optimize"]?.boolValue ?? false

        var processArgs = ["aro", "build", directory]
        if optimize {
            processArgs.append("--optimize")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = processArgs

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()

            let timeoutTask = Task {
                try await Task.sleep(nanoseconds: 120 * 1_000_000_000)
                if process.isRunning {
                    process.terminate()
                }
            }

            process.waitUntilExit()
            timeoutTask.cancel()

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

            let output = String(data: outputData, encoding: .utf8) ?? ""
            let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

            if process.terminationStatus == 0 {
                let message = output.isEmpty ? "Compilation successful" : output
                return MCPToolCallResult(content: [.text(message)])
            } else {
                let message = errorOutput.isEmpty ? output : errorOutput
                return MCPToolCallResult(
                    content: [.text("Compilation failed (exit code \(process.terminationStatus)):\n\(message)")],
                    isError: true
                )
            }
        } catch {
            return MCPToolCallResult(
                content: [.text("Failed to compile: \(error.localizedDescription)")],
                isError: true
            )
        }
    }

    /// List available example applications
    private func executeExamples(arguments: JSONValue?) -> MCPToolCallResult {
        let category = arguments?["category"]?.stringValue

        let allExamples: [(category: String, name: String, description: String)] = [
            // Core Language
            ("core", "HelloWorld", "Minimal single-file example"),
            ("core", "Calculator", "Basic arithmetic operations"),
            ("core", "Computations", "Compute operations and qualifier-as-name syntax"),
            ("core", "Expressions", "Arithmetic, comparison, and logical operators"),
            ("core", "Conditionals", "When guards and conditional execution"),
            ("core", "Iteration", "For-each loops, range loops, and collection iteration"),
            ("core", "Scoping", "Publish as, business activity scope, pipeline, loop isolation"),
            ("core", "Immutability", "Immutable bindings, new-name pattern, qualifier-as-name"),
            ("core", "ErrorHandling", "Error philosophy demonstration"),
            ("core", "Parameters", "Command-line argument parsing"),
            // HTTP & WebSocket
            ("http", "HelloWorldAPI", "Simple HTTP API"),
            ("http", "HTTPServer", "HTTP server with Keepalive"),
            ("http", "HTTPClient", "HTTP client requests"),
            ("http", "UserService", "Multi-file REST API application"),
            ("http", "WeatherClient", "Fetch live external API data"),
            ("http", "SimpleChat", "WebSocket real-time messaging"),
            ("http", "WebSocketDemo", "WebSocket server patterns"),
            // Events & Lifecycle
            ("events", "EventExample", "Custom event emission and handling"),
            ("events", "EventListener", "Event subscription patterns"),
            ("events", "ApplicationEnd", "Graceful shutdown handlers"),
            ("events", "StateMachine", "State transitions with Accept action"),
            ("events", "OrderService", "Full state machine example"),
            // File System
            ("files", "FileWatcher", "File system monitoring"),
            ("files", "FileOperations", "File I/O (read, write, copy, move)"),
            ("files", "FileMetadata", "File stats and attributes"),
            ("files", "FormatAwareIO", "Auto-detect JSON, YAML, CSV"),
            ("files", "DirectoryReplicator", "Directory operations"),
            // Data Processing
            ("data", "DataPipeline", "Filter, transform, aggregate"),
            ("data", "SetOperations", "Union, intersect, difference"),
            ("data", "CollectionMerge", "Merging collections and objects"),
            ("data", "RepositoryObserver", "Repository change observers"),
            ("data", "DateTimeDemo", "Date/time operations"),
            ("data", "DateRangeDemo", "Date ranges and recurrence"),
            // Sockets
            ("sockets", "EchoSocket", "TCP socket server"),
            ("sockets", "SocketClient", "TCP client connections"),
            ("sockets", "MultiService", "Multiple services in one app"),
            // Templates & Output
            ("templates", "TemplateEngine", "Mustache-style templates"),
            ("templates", "ContextAware", "Human/machine/developer formatting"),
            ("templates", "MetricsDemo", "Prometheus metrics export"),
            // Plugins
            ("plugins", "GreetingPlugin", "Swift plugin example"),
            ("plugins", "HashPluginDemo", "C plugin example"),
            ("plugins", "CSVProcessor", "Rust plugin example"),
            ("plugins", "MarkdownRenderer", "Python plugin example"),
            ("plugins", "QualifierPlugin", "Swift plugin with qualifiers"),
            ("plugins", "QualifierPluginC", "C plugin with qualifiers"),
            ("plugins", "QualifierPluginPython", "Python plugin with qualifiers"),
        ]

        let filtered = category.map { cat in
            allExamples.filter { $0.category == cat }
        } ?? allExamples

        if filtered.isEmpty {
            return MCPToolCallResult(
                content: [.text("No examples found for category: \(category ?? "").\nAvailable categories: core, http, events, files, data, sockets, templates, plugins")],
                isError: true
            )
        }

        var output = "# ARO Example Applications\n\n"

        let grouped = Dictionary(grouping: filtered, by: { $0.category })
        let categoryOrder = category.map { [$0] } ?? ["core", "http", "events", "files", "data", "sockets", "templates", "plugins"]

        for cat in categoryOrder {
            guard let examples = grouped[cat] else { continue }
            let categoryTitle: String
            switch cat {
            case "core": categoryTitle = "Core Language"
            case "http": categoryTitle = "HTTP & WebSocket"
            case "events": categoryTitle = "Events & Lifecycle"
            case "files": categoryTitle = "File System"
            case "data": categoryTitle = "Data Processing"
            case "sockets": categoryTitle = "Sockets"
            case "templates": categoryTitle = "Templates & Output"
            case "plugins": categoryTitle = "Plugins"
            default: categoryTitle = cat.capitalized
            }
            output += "## \(categoryTitle)\n\n"
            for example in examples {
                output += "- **\(example.name)**: \(example.description)\n"
                output += "  Run with: `aro run ./Examples/\(example.name)`\n"
            }
            output += "\n"
        }

        return MCPToolCallResult(content: [.text(output)])
    }

    /// List all available actions
    private func executeActions(arguments: JSONValue?) -> MCPToolCallResult {
        let roleFilter = arguments?["role"]?.stringValue?.lowercased()

        struct ActionGroup {
            let role: String
            let title: String
            let description: String
            let actions: [(name: String, description: String, prepositions: String)]
        }

        let groups: [ActionGroup] = [
            ActionGroup(
                role: "request",
                title: "REQUEST Actions (External → Internal)",
                description: "Bring data into the feature set:",
                actions: [
                    ("Extract", "Get data from events, requests, parameters, path parameters", "from"),
                    ("Retrieve", "Get data from repositories; supports `where field = value` and `default` fallback", "from"),
                    ("Fetch", "Make HTTP GET requests to external services", "from"),
                    ("Request", "Make HTTP requests (GET, POST, PUT, DELETE)", "from"),
                    ("Read", "Read content from files", "from"),
                    ("Receive", "Receive data from socket connections", "from"),
                    ("Parse", "Parse structured data (JSON, HTML, XML, CSV)", "from"),
                    ("ParseLinkHeader", "Parse HTTP Link header into pagination info", "from"),
                ]
            ),
            ActionGroup(
                role: "own",
                title: "OWN Actions (Internal → Internal)",
                description: "Transform data within the feature set:",
                actions: [
                    ("Compute", "Calculate values; supports arithmetic, length, uppercase, lowercase, hash, string concat (++)", "from, with"),
                    ("Validate", "Check data against rules or schemas", "against, with"),
                    ("Compare", "Compare two values; result is a boolean", "against"),
                    ("Transform", "Convert data between types (int, float, string, bool)", "to, with"),
                    ("Create", "Create new objects or collections", "with, from"),
                    ("Update", "Update fields on an existing object", "in, with"),
                    ("Delete", "Remove data from a collection", "from"),
                    ("Filter", "Filter collections by predicate", "with, from"),
                    ("Sort", "Sort collections by field", "with"),
                    ("Split", "Split strings by delimiter or regex (`by /pattern/`)", "with, by"),
                    ("Join", "Join list elements into a string with separator", "with"),
                    ("Merge", "Merge two collections or objects", "with"),
                ]
            ),
            ActionGroup(
                role: "response",
                title: "RESPONSE Actions (Internal → External)",
                description: "Return results from the feature set:",
                actions: [
                    ("Return", "Return success with optional data (HTTP 200/201/etc via qualifier)", "for, with"),
                    ("Throw", "Return an error response", "for"),
                    ("Render", "Render a template and return the result", "from, with"),
                ]
            ),
            ActionGroup(
                role: "export",
                title: "EXPORT Actions (Internal → External)",
                description: "Send data outside the feature set:",
                actions: [
                    ("Log", "Write to console/logs", "to"),
                    ("Store", "Save to repository (auto-generates `id`)", "in, into"),
                    ("Write", "Write content to a file", "to"),
                    ("Append", "Append content to a file", "to"),
                    ("Send", "Send HTTP request or message to service/socket", "to"),
                    ("Notify", "Send notification to target(s); dispatches NotificationSent events", "to, with"),
                    ("Emit", "Emit a domain event to the event bus", "with"),
                    ("Publish", "Make a variable globally visible across feature sets", "as"),
                    ("Stream", "Stream data lazily to an output or pipe", "to, with"),
                ]
            ),
            ActionGroup(
                role: "server",
                title: "SERVER Actions",
                description: "Control servers, services, and timing:",
                actions: [
                    ("Start", "Start a server or service (http-server, file-monitor, socket-server)", "with"),
                    ("Stop", "Stop a running service", "with"),
                    ("Listen", "Listen for incoming connections on a port", "on"),
                    ("Keepalive", "Keep the application running to process events (blocks until SIGINT/SIGTERM)", "for"),
                    ("Schedule", "Schedule a repeating timer event every N seconds", "with"),
                    ("Sleep", "Pause execution for N seconds", "for"),
                    ("WaitForEvents", "Wait until all pending events are processed", "for"),
                    ("Configure", "Configure runtime settings (timeout, retry, etc.)", "with"),
                    ("Accept", "Accept a state transition for an entity (triggers StateTransition events)", "for"),
                ]
            ),
        ]

        var output = "# ARO Actions\n\n"
        output += "ARO has \(groups.flatMap { $0.actions }.count)+ built-in actions organized by role.\n\n"

        for group in groups {
            if let filter = roleFilter, group.role != filter { continue }
            output += "## \(group.title)\n"
            output += "\(group.description)\n\n"
            for action in group.actions {
                output += "- **\(action.name)**: \(action.description). Prepositions: `\(action.prepositions)`\n"
            }
            output += "\n"
        }

        if roleFilter != nil && !groups.contains(where: { $0.role == roleFilter }) {
            return MCPToolCallResult(
                content: [.text("Unknown role filter. Use: request, own, response, export, server")],
                isError: true
            )
        }

        // File system actions (always shown unless filtered to a different role)
        if roleFilter == nil {
            output += """
            ## FILE Actions
            File system operations:

            - **List**: List directory contents. Prepositions: `from`
            - **Stat**: Get file metadata (size, dates, permissions). Prepositions: `from`
            - **Exists**: Check if a path exists. Prepositions: `for`
            - **Make**: Create a directory. Prepositions: `for`
            - **Copy**: Copy file to destination. Prepositions: `to`
            - **Move**: Move/rename file. Prepositions: `to`

            ## SOCKET Actions
            TCP/WebSocket communication:

            - **Connect**: Connect to a TCP server. Prepositions: `to`
            - **Broadcast**: Broadcast message to all connected clients. Prepositions: `to`
            - **Close**: Close a connection. Prepositions: `for`

            ## TEST Actions
            Testing framework (Given/When/Then):

            - **Given**: Set up test context. Prepositions: `with`
            - **When**: Execute the action under test. Prepositions: `for`
            - **Then**: Assert expected outcomes. Prepositions: `for`
            - **Assert**: Make a specific assertion. Prepositions: `for`

            ## SPECIAL Actions

            - **Call**: Call an external plugin action. Prepositions: `with`
            - **Execute**: Execute a system shell command. Prepositions: `with`
            - **Include**: Include a template file. Prepositions: `from`

            """
        }

        return MCPToolCallResult(content: [.text(output)])
    }

    /// Parse ARO code to AST
    private func executeParse(arguments: JSONValue?) -> MCPToolCallResult {
        guard let args = arguments?.objectValue,
              let code = args["code"]?.stringValue else {
            return MCPToolCallResult(
                content: [.text("Missing required argument: 'code'")],
                isError: true
            )
        }

        let compiler = Compiler()
        let result = compiler.compile(code)

        // Check for errors
        if result.hasErrors {
            var message = "Parse failed:\n"
            for diag in result.diagnostics where diag.severity == .error {
                message += "  \(diag.message)\n"
            }
            return MCPToolCallResult(content: [.text(message)], isError: true)
        }

        let program = result.program

        // Build AST representation
        var ast: [[String: Any]] = []
        for featureSet in program.featureSets {
            let fsDict: [String: Any] = [
                "name": featureSet.name,
                "businessActivity": featureSet.businessActivity,
                "statements": featureSet.statements.map { stmt -> [String: Any] in
                    serializeStatement(stmt)
                }
            ]
            ast.append(fsDict)
        }

        // Convert to JSON string
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: ast, options: [.prettyPrinted, .sortedKeys])
            if let jsonString = String(data: jsonData, encoding: .utf8) {
                return MCPToolCallResult(content: [.text(jsonString)])
            }
        } catch {
            return MCPToolCallResult(
                content: [.text("Failed to serialize AST: \(error.localizedDescription)")],
                isError: true
            )
        }

        return MCPToolCallResult(content: [.text("[]")])
    }

    /// Serialize any Statement to a dictionary for JSON output
    private func serializeStatement(_ stmt: Statement) -> [String: Any] {
        if let aro = stmt as? AROStatement {
            var dict: [String: Any] = [
                "type": "AROStatement",
                "action": aro.action.verb,
                "result": [
                    "base": aro.result.base,
                    "typeAnnotation": aro.result.typeAnnotation as Any
                ],
                "preposition": aro.object.preposition.rawValue,
                "object": [
                    "base": aro.object.noun.base,
                    "typeAnnotation": aro.object.noun.typeAnnotation as Any
                ]
            ]
            if let whereClause = aro.queryModifiers.whereClause {
                dict["whereField"] = whereClause.field
            }
            return dict
        } else if let publish = stmt as? PublishStatement {
            return [
                "type": "PublishStatement",
                "externalName": publish.externalName,
                "internalVariable": publish.internalVariable
            ]
        } else if let forEach = stmt as? ForEachLoop {
            return [
                "type": "ForEachLoop",
                "itemVariable": forEach.itemVariable,
                "collection": forEach.collection.base,
                "body": forEach.body.map { serializeStatement($0) }
            ]
        } else if let range = stmt as? RangeLoop {
            return [
                "type": "RangeLoop",
                "variable": range.variable,
                "from": range.from.description,
                "to": range.to.description,
                "body": range.body.map { serializeStatement($0) }
            ]
        } else if let match = stmt as? MatchStatement {
            var dict: [String: Any] = [
                "type": "MatchStatement",
                "subject": match.subject.base,
                "cases": match.cases.map { caseClause -> [String: Any] in
                    [
                        "pattern": caseClause.pattern.description,
                        "body": caseClause.body.map { serializeStatement($0) }
                    ]
                }
            ]
            if let otherwise = match.otherwise {
                dict["otherwise"] = otherwise.map { serializeStatement($0) }
            }
            return dict
        }
        return ["type": "Unknown"]
    }

    /// Get syntax reference
    private func executeSyntax(arguments: JSONValue?) -> MCPToolCallResult {
        let topic = arguments?["topic"]?.stringValue

        switch topic {
        case "feature-set":
            return MCPToolCallResult(content: [.text(featureSetSyntax)])
        case "action":
            return MCPToolCallResult(content: [.text(actionSyntax)])
        case "statement":
            return MCPToolCallResult(content: [.text(statementSyntax)])
        case "http-api":
            return MCPToolCallResult(content: [.text(httpApiSyntax)])
        case "event":
            return MCPToolCallResult(content: [.text(eventSyntax)])
        case "repository":
            return MCPToolCallResult(content: [.text(repositorySyntax)])
        case "control-flow":
            return MCPToolCallResult(content: [.text(controlFlowSyntax)])
        case "plugins":
            return MCPToolCallResult(content: [.text(pluginsSyntax)])
        case "state-machine":
            return MCPToolCallResult(content: [.text(stateMachineSyntax)])
        case "testing":
            return MCPToolCallResult(content: [.text(testingSyntax)])
        default:
            return MCPToolCallResult(content: [.text(syntaxOverview)])
        }
    }

    // MARK: - Syntax Reference Content

    private var syntaxOverview: String {
        """
        # ARO Syntax Reference

        ARO (Action-Result-Object) is a domain-specific language for expressing business features.

        ## Core Concepts

        1. **Feature Set**: A named block containing statements
        2. **Statement**: An action operating on result and object
        3. **Action**: A verb like Extract, Compute, Return
        4. **Result**: The output variable with optional qualifier
        5. **Object**: The input/target with optional qualifier

        ## Basic Syntax

        ```aro
        (Feature Name: Business Activity) {
            <Action> the <result: qualifier> preposition the <object: qualifier>.
        }
        ```

        ## Example

        ```aro
        (Application-Start: Hello World) {
            Log "Hello, World!" to the <console>.
            Return an <OK: status> for the <startup>.
        }
        ```

        ## Topics

        Use the 'topic' argument for detailed info:
        - `feature-set` - Feature set syntax and application lifecycle
        - `action` - Action syntax and roles
        - `statement` - Statement structure and qualifiers
        - `http-api` - Contract-first HTTP APIs with OpenAPI
        - `event` - Event handlers and emitting events
        - `repository` - Repository operations (CRUD, observers)
        - `control-flow` - Loops (for-each, range), match, when guards
        - `plugins` - Plugin system (Swift, Rust, C, Python)
        - `state-machine` - State machines with Accept action
        - `testing` - Testing framework (Given/When/Then)
        """
    }

    private var featureSetSyntax: String {
        """
        # Feature Set Syntax

        A feature set is a named block of statements that represents a business capability.

        ## Basic Structure

        ```aro
        (Feature Name: Business Activity) {
            (* Comments use (* ... *) syntax *)
            <Statement1>.
            <Statement2>.
        }
        ```

        ## Special Feature Sets

        ### Application-Start (required, exactly one)
        ```aro
        (Application-Start: My App) {
            Log "Starting..." to the <console>.
            Return an <OK: status> for the <startup>.
        }
        ```

        ### HTTP Handler (named after OpenAPI operationId)
        ```aro
        (listUsers: User API) {
            Retrieve the <users> from the <user-repository>.
            Return an <OK: status> with <users>.
        }
        ```

        ### Event Handler
        ```aro
        (Send Email: UserCreated Handler) {
            Extract the <user> from the <event: user>.
            Send the <welcome-email> to the <user: email>.
            Return an <OK: status>.
        }
        ```
        """
    }

    private var actionSyntax: String {
        """
        # Action Syntax

        Actions are the verbs in ARO statements. They're classified by data flow direction:

        ## REQUEST Actions (External -> Internal)
        Bring data into the feature set:
        - `Extract` - Get data from events, requests, parameters
        - `Retrieve` - Get data from repositories
        - `Fetch` - Get data from external services
        - `Parse` - Parse structured data (JSON, HTML, XML)

        ## OWN Actions (Internal -> Internal)
        Transform data within the feature set:
        - `Compute` - Calculate values, transform data
        - `Validate` - Check data against rules
        - `Create` - Create new objects
        - `Compare` - Compare values
        - `Transform` - Convert data formats

        ## RESPONSE Actions (Internal -> External)
        Return results from the feature set:
        - `Return` - Return success with optional data
        - `Throw` - Return error/exception

        ## EXPORT Actions (Internal -> External)
        Send data outside the feature set:
        - `Log` - Write to console/logs
        - `Store` - Save to repository
        - `Send` - Send to external service
        - `Emit` - Emit domain event
        - `<Publish>` - Make variable globally visible
        """
    }

    private var statementSyntax: String {
        """
        # Statement Syntax

        Every ARO statement follows the Action-Result-Object pattern:

        ```aro
        <Action> article <result: qualifier> preposition article <object: qualifier>.
        ```

        ## Components

        - **Action**: Verb without angle brackets: `Extract`, `Return`, `Log`
        - **Article**: a, an, the (semantic, not syntactic)
        - **Result**: Output variable `<user>` or `<user: name>`
        - **Preposition**: from, to, with, for, in, on, against
        - **Object**: Input/target `<request: body>` or `<console>`

        ## Examples

        ```aro
        (* Simple *)
        Log "Hello" to the <console>.

        (* With qualifiers *)
        Extract the <user-id: id> from the <request: pathParameters>.

        (* Computation *)
        Compute the <total> from <price> * <quantity>.

        (* Conditional Return *)
        Return an <OK: status> for a <valid: result>.
        ```

        ## Qualifiers

        Qualifiers add specificity:
        - `<request: body>` - The body property of request
        - `<OK: status>` - An OK status code
        - `<user: email>` - The email property of user
        """
    }

    private var httpApiSyntax: String {
        """
        # HTTP API Syntax (Contract-First)

        ARO uses contract-first development with OpenAPI specifications.

        ## Requirements

        1. Create `openapi.yaml` in your application directory
        2. Name feature sets after `operationId` values

        ## openapi.yaml Example

        ```yaml
        openapi: 3.0.3
        info:
          title: User API
          version: 1.0.0
        paths:
          /users:
            get:
              operationId: listUsers
            post:
              operationId: createUser
          /users/{id}:
            get:
              operationId: getUser
        ```

        ## Feature Set Examples

        ```aro
        (* GET /users - listUsers *)
        (listUsers: User API) {
            Retrieve the <users> from the <user-repository>.
            Return an <OK: status> with <users>.
        }

        (* POST /users - createUser *)
        (createUser: User API) {
            Extract the <data> from the <request: body>.
            Create the <user> with <data>.
            Store the <user> into the <user-repository>.
            Return a <Created: status> with <user>.
        }

        (* GET /users/{id} - getUser *)
        (getUser: User API) {
            Extract the <id> from the <pathParameters: id>.
            Retrieve the <user> from the <user-repository> where id = <id>.
            Return an <OK: status> with <user>.
        }
        ```

        ## Accessing Request Data

        - Path parameters: `Extract the <id> from the <pathParameters: id>.`
        - Query parameters: `Extract the <page> from the <queryParameters: page>.`
        - Request body: `Extract the <data> from the <request: body>.`
        - Headers: `Extract the <auth> from the <headers: Authorization>.`
        """
    }

    private var eventSyntax: String {
        """
        # Event Syntax

        ARO is event-driven. Feature sets respond to domain events.

        ## Emitting Events

        ```aro
        Emit a <UserCreated: event> with <user>.
        Emit an <OrderPlaced: event> with { order: <order>, timestamp: <now> }.
        ```

        ## Handling Events

        Name your feature set with "Handler" suffix:

        ```aro
        (Send Welcome Email: UserCreated Handler) {
            Extract the <user> from the <event: user>.
            Send the <welcome-email> to the <user: email>.
            Return an <OK: status> for the <notification>.
        }

        (Update Inventory: OrderPlaced Handler) {
            Extract the <items> from the <event: order>.
            Update the <inventory> with <items>.
            Return an <OK: status> for the <inventory-update>.
        }
        ```

        ## Event Payload Access

        Extract data from events using:
        ```aro
        Extract the <field> from the <event: field>.
        ```
        """
    }

    private var repositorySyntax: String {
        """
        # Repository Syntax

        Repositories provide persistent storage for domain entities.

        ## Storing Data

        ```aro
        Store the <user> into the <user-repository>.
        ```

        ## Retrieving Data

        ```aro
        (* Get all *)
        Retrieve the <users> from the <user-repository>.

        (* Get by ID *)
        Retrieve the <user> from the <user-repository> where id = <id>.

        (* Get with condition *)
        Retrieve the <orders> from the <order-repository> where status = "pending".
        ```

        ## Updating Data

        ```aro
        Update the <user> in the <user-repository>.
        ```

        ## Deleting Data

        ```aro
        Delete the <user> from the <user-repository>.
        ```

        ## Repository Observers

        React to repository changes:

        ```aro
        (Log User Changes: user-repository Observer) {
            Extract the <user> from the <change: entity>.
            Extract the <type> from the <change: type>.
            Log "User changed" to the <console>.
            Return an <OK: status> for the <observation>.
        }
        ```
        """
    }

    private var controlFlowSyntax: String {
        """
        # Control Flow Syntax

        ## When Guards (Conditional Execution)

        A `when` clause skips the following statement if the condition is false:

        ```aro
        when <count> > 0 {
            Log <count> to the <console>.
        }
        ```

        ## For-Each Loop

        Iterate over a collection:

        ```aro
        for each <item> in <items> {
            Log <item> to the <console>.
            Store the <item> into the <processed-repository>.
        }
        ```

        - Loop variable `<item>` is bound fresh each iteration
        - Variables bound inside the loop are NOT visible outside it

        ## Range Loop

        Iterate over a numeric range (inclusive):

        ```aro
        for <i> from 1 to <count> {
            Log <i> to the <console>.
        }
        ```

        ## Match Statement

        Pattern match on a value:

        ```aro
        match <status> {
            case "active" {
                Log "User is active" to the <console>.
            }
            case "inactive" {
                Log "User is inactive" to the <console>.
            }
            default {
                Log "Unknown status" to the <console>.
            }
        }
        ```

        Matching on booleans:

        ```aro
        Compute the <is-valid> from <age> > 18.
        match <is-valid> {
            case true {
                Return an <OK: status> with <user>.
            }
            case false {
                Throw an <Unauthorized: error> for the <user>.
            }
        }
        ```

        ## Handler Guards

        Event handlers can have `when` guards to filter events:

        ```aro
        (Notify Adults: UserCreated Handler) when <age> >= 18 {
            Extract the <user> from the <event: user>.
            Notify the <user> with "Welcome, adult user!".
            Return an <OK: status> for the <notification>.
        }
        ```
        """
    }

    private var pluginsSyntax: String {
        """
        # Plugin System

        ARO supports plugins in Swift, Rust, C, and Python.

        ## Directory Structure

        ```
        MyApp/
        ├── main.aro
        └── Plugins/
            └── my-plugin/
                ├── plugin.yaml      # Required manifest
                └── src/             # Source files
        ```

        ## plugin.yaml

        ```yaml
        name: plugin-swift-myaction
        version: 1.0.0
        description: Provides MyAction
        aro-version: '>=0.2.0'

        provides:
          - type: swift-plugin     # or: rust-plugin, c-plugin, python-plugin
            path: Sources/
            handler: myaction      # qualifier namespace
        ```

        ## C ABI Interface (all native plugins must implement)

        ```c
        char* aro_plugin_info(void);
        char* aro_plugin_execute(const char* action, const char* input_json);
        char* aro_plugin_qualifier(const char* qualifier, const char* input_json);
        void  aro_plugin_free(char* ptr);
        ```

        ## Using a Plugin in ARO

        ```aro
        (Process Data: My Feature) {
            (* Call a plugin action *)
            Call the <result> with <input> using <my-plugin>.

            (* Use a plugin qualifier *)
            Compute the <shuffled: myaction.shuffle> from the <items>.

            Return an <OK: status> with <result>.
        }
        ```

        ## Plugin Qualifiers

        Qualifiers are namespaced by `handler:` in plugin.yaml:

        ```aro
        Compute the <sorted: stats.sort> from the <numbers>.
        Compute the <picked: collections.pick-random> from the <items>.
        ```

        ## Installing Plugins

        ```bash
        aro add plugin-name     # Install from registry
        aro remove plugin-name  # Remove plugin
        ```
        """
    }

    private var stateMachineSyntax: String {
        """
        # State Machine Syntax

        ARO supports event-driven state machines using the `Accept` action.

        ## Basic Pattern

        ```aro
        (* Transition an entity to a new state *)
        Accept the <transition: order_to_placed> on the <order: status>.
        ```

        The `Accept` action:
        1. Updates the entity's state field in the repository
        2. Emits a `StateTransition` event with the new state
        3. Triggers any `StateTransition Handler<toState:X>` feature sets

        ## State Transition Handlers

        ```aro
        (* Triggered when order reaches 'placed' state *)
        (Notify Fulfillment: OrderPlaced StateTransition Handler<toState:placed>) {
            Extract the <order-id> from the <event: entityId>.
            Retrieve the <order> from the <order-repository> where id = <order-id>.
            Notify the <fulfillment-team> with "New order placed".
            Return an <OK: status> for the <notification>.
        }
        ```

        ## Full State Machine Example

        ```aro
        (* Initial creation - sets state to 'pending' *)
        (createOrder: Order API) {
            Extract the <data> from the <request: body>.
            Create the <order> with <data>.
            Store the <order> into the <order-repository>.
            Accept the <transition: order_to_pending> on the <order: status>.
            Return a <Created: status> with <order>.
        }

        (* Process payment - transition to 'paid' *)
        (processPayment: Order API) {
            Extract the <id> from the <pathParameters: id>.
            Extract the <payment> from the <request: body>.
            Retrieve the <order> from the <order-repository> where id = <id>.
            Validate the <payment> against the <order: total>.
            Accept the <transition: order_to_paid> on the <order: status>.
            Return an <OK: status> with <order>.
        }

        (* React to state transition *)
        (Ship Order: paid StateTransition Handler<toState:paid>) {
            Extract the <order-id> from the <event: entityId>.
            Retrieve the <order> from the <order-repository> where id = <order-id>.
            Emit a <ShipOrder: event> with <order>.
            Return an <OK: status> for the <shipment>.
        }
        ```
        """
    }

    private var testingSyntax: String {
        """
        # Testing Framework Syntax

        ARO supports colocated tests using Given/When/Then pattern.

        ## Test Feature Set Structure

        Test feature sets are named like their subject, co-located in the same file:

        ```aro
        (* Production feature set *)
        (calculateDiscount: Pricing) {
            Extract the <price> from the <request: body>.
            Extract the <code> from the <request: code>.
            Validate the <code> against the <discount-codes>.
            Compute the <discount> from <price> * 0.1.
            Return an <OK: status> with <discount>.
        }

        (* Test for calculateDiscount *)
        (Test calculateDiscount: Pricing Test) {
            Given the <price> with 100.
            Given the <code> with "SAVE10".
            When calculateDiscount for the <request>.
            Then the <discount> equals 10.
        }
        ```

        ## Given/When/Then Actions

        - **Given**: Set up test data: `Given the <variable> with <value>.`
        - **When**: Execute feature set under test: `When <feature-name> for the <context>.`
        - **Then**: Assert outcome: `Then the <variable> equals <expected>.`
        - **Assert**: Low-level assertion: `Assert the <condition> for the <test>.`

        ## Running Tests

        ```bash
        aro test ./MyApp      # Run all tests in a directory
        aro test ./MyApp --verbose  # Show all test output
        ```
        """
    }
}
