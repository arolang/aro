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
                        ])
                    ]),
                    "required": .array([.string("directory")])
                ])
            ),
            MCPTool(
                name: "aro_actions",
                description: "List all available ARO actions with their roles, verbs, and valid prepositions.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([:])
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
                            "description": .string("Specific topic: feature-set, action, statement, http-api, event, repository (optional, returns overview if not specified)")
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
        case "aro_actions":
            return executeActions()
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

        // Execute aro run command
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["aro", "run", directory]

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

    /// List all available actions
    private func executeActions() -> MCPToolCallResult {
        // Return static documentation of all built-in actions
        let output = """
        # ARO Actions

        ARO has approximately 48 built-in actions organized by role:

        ## REQUEST Actions (External -> Internal)
        Bring data into the feature set:

        - **Extract**: Get data from events, requests, parameters. Prepositions: from
        - **Retrieve**: Get data from repositories. Prepositions: from
        - **Receive**: Receive data from connections. Prepositions: from
        - **Request**: Make HTTP requests. Prepositions: from
        - **Read**: Read from files. Prepositions: from

        ## OWN Actions (Internal -> Internal)
        Transform data within the feature set:

        - **Compute**: Calculate values, transform data. Prepositions: from, with
        - **Validate**: Check data against rules. Prepositions: against, with
        - **Compare**: Compare values. Prepositions: against
        - **Transform**: Convert data formats. Prepositions: to, with
        - **Create**: Create new objects. Prepositions: with, from
        - **Update**: Update existing data. Prepositions: in, with
        - **Delete**: Delete data. Prepositions: from
        - **Filter**: Filter collections. Prepositions: with, from
        - **Sort**: Sort collections. Prepositions: with
        - **Split**: Split strings. Prepositions: with, by
        - **Merge**: Merge collections. Prepositions: with
        - **Parse**: Parse structured data (HTML, JSON, XML). Prepositions: from

        ## RESPONSE Actions (Internal -> External)
        Return results from the feature set:

        - **Return**: Return success with optional data. Prepositions: for, with
        - **Throw**: Return error/exception. Prepositions: for

        ## EXPORT Actions (Internal -> External)
        Send data outside the feature set:

        - **Log**: Write to console/logs. Prepositions: to
        - **Store**: Save to repository. Prepositions: in
        - **Write**: Write to file. Prepositions: to
        - **Send**: Send HTTP request or message. Prepositions: to
        - **Notify**: Send notification. Prepositions: to
        - **Publish**: Make variable globally visible. Prepositions: as
        - **Emit**: Emit domain event. Prepositions: with

        ## SERVER Actions
        Control servers and services:

        - **Start**: Start a server or service. Prepositions: with
        - **Stop**: Stop a server or service. Prepositions: with
        - **Listen**: Listen for connections. Prepositions: on

        ## SOCKET Actions
        TCP/WebSocket communication:

        - **Connect**: Connect to a server. Prepositions: to
        - **Broadcast**: Broadcast message to all connections. Prepositions: to
        - **Close**: Close a connection. Prepositions: for

        ## FILE Actions
        File system operations:

        - **List**: List directory contents. Prepositions: from
        - **Stat**: Get file information. Prepositions: from
        - **Exists**: Check if file exists. Prepositions: for
        - **Make**: Create directory. Prepositions: for
        - **Copy**: Copy file. Prepositions: to
        - **Move**: Move file. Prepositions: to
        - **Append**: Append to file. Prepositions: to

        ## DATA PIPELINE Actions
        Collection transformations:

        - **Map**: Transform each element. Prepositions: with
        - **Reduce**: Aggregate elements. Prepositions: with
        - **Filter**: Filter elements. Prepositions: with

        ## TEST Actions
        Testing framework:

        - **Given**: Setup test context. Prepositions: with
        - **When**: Execute action under test. Prepositions: for
        - **Then**: Assert expectations. Prepositions: for
        - **Assert**: Make assertions. Prepositions: for

        ## SPECIAL Actions

        - **Keepalive**: Keep application running for events. Prepositions: for
        - **Call**: Call external service (plugin). Prepositions: with
        - **Execute**: Execute system command. Prepositions: with
        - **Include**: Include template. Prepositions: from
        - **Accept**: Accept state transition. Prepositions: for
        """

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
                    if let aroStmt = stmt as? AROStatement {
                        return [
                            "type": "AROStatement",
                            "action": aroStmt.action.verb,
                            "result": [
                                "base": aroStmt.result.base,
                                "typeAnnotation": aroStmt.result.typeAnnotation as Any
                            ],
                            "preposition": aroStmt.object.preposition.rawValue,
                            "object": [
                                "base": aroStmt.object.noun.base,
                                "typeAnnotation": aroStmt.object.noun.typeAnnotation as Any
                            ]
                        ]
                    }
                    return ["type": "Unknown"]
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
        - `feature-set` - Feature set syntax
        - `action` - Action syntax and roles
        - `statement` - Statement structure
        - `http-api` - Contract-first HTTP APIs
        - `event` - Event handlers
        - `repository` - Repository operations
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
            Store the <user> in the <user-repository>.
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
        Store the <user> in the <user-repository>.
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
}
