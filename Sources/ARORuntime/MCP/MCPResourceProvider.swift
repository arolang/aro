// ============================================================
// MCPResourceProvider.swift
// ARO MCP - Resource Implementations (GitHub-backed)
// ============================================================

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Provides MCP resources for ARO documentation
/// Fetches content from GitHub when local files are not available
public actor MCPResourceProvider {
    /// GitHub repository info
    private static let githubOwner = "arolang"
    private static let githubRepo = "aro"
    private static let githubBranch = "main"

    /// Base URLs
    private static let apiBase = "https://api.github.com/repos/\(githubOwner)/\(githubRepo)/contents"
    private static let rawBase = "https://raw.githubusercontent.com/\(githubOwner)/\(githubRepo)/\(githubBranch)"

    /// Local base path (for development)
    private let localBasePath: String?

    /// Cache for fetched content
    private var cache: [String: CacheEntry] = [:]
    private let cacheDuration: TimeInterval = 300 // 5 minutes

    private struct CacheEntry {
        let content: String
        let timestamp: Date
    }

    public init() {
        self.localBasePath = MCPResourceProvider.detectLocalBasePath()
    }

    public init(basePath: String) {
        self.localBasePath = basePath
    }

    /// Detect local ARO installation path (for development)
    private static func detectLocalBasePath() -> String? {
        var candidates: [String] = []

        // Development: relative to executable
        if let execPath = ProcessInfo.processInfo.arguments.first {
            let url = URL(fileURLWithPath: execPath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            candidates.append(url.path)
        }

        // Current directory (for development)
        candidates.append(FileManager.default.currentDirectoryPath)

        for candidate in candidates {
            let proposalsPath = (candidate as NSString).appendingPathComponent("Proposals")
            let bookPath = (candidate as NSString).appendingPathComponent("Book")
            if FileManager.default.fileExists(atPath: proposalsPath) ||
               FileManager.default.fileExists(atPath: bookPath) {
                return candidate
            }
        }

        return nil
    }

    // MARK: - Public API

    /// List all available resources
    public func listResources() async -> MCPResourcesListResult {
        var resources: [MCPResource] = [
            MCPResource(
                uri: "aro://proposals",
                name: "Language Proposals",
                description: "ARO language specification proposals",
                mimeType: "text/directory"
            ),
            MCPResource(
                uri: "aro://examples",
                name: "Example Applications",
                description: "Complete ARO example applications",
                mimeType: "text/directory"
            ),
            MCPResource(
                uri: "aro://books",
                name: "ARO Books",
                description: "Official ARO documentation books",
                mimeType: "text/directory"
            ),
            MCPResource(
                uri: "aro://syntax",
                name: "Syntax Reference",
                description: "Quick ARO syntax reference",
                mimeType: "text/markdown"
            ),
            MCPResource(
                uri: "aro://actions",
                name: "Action Reference",
                description: "All available ARO actions",
                mimeType: "text/markdown"
            )
        ]

        // Try to list proposals from GitHub or local
        if let proposals = await listProposalFiles() {
            for file in proposals {
                let number = String(file.prefix(8))
                let name = String(file.dropFirst(9).dropLast(3))
                    .replacingOccurrences(of: "-", with: " ")
                    .capitalized
                resources.append(MCPResource(
                    uri: "aro://proposals/\(number)",
                    name: "\(number): \(name)",
                    description: nil,
                    mimeType: "text/markdown"
                ))
            }
        }

        return MCPResourcesListResult(resources: resources)
    }

    /// Read a specific resource
    public func readResource(uri: String) async -> MCPResourceReadResult? {
        guard uri.hasPrefix("aro://") else { return nil }
        let path = String(uri.dropFirst(6))
        let components = path.split(separator: "/", maxSplits: 1).map(String.init)

        guard !components.isEmpty else { return nil }

        switch components[0] {
        case "proposals":
            if components.count > 1 {
                return await readProposal(components[1])
            } else {
                return await listProposals()
            }

        case "examples":
            if components.count > 1 {
                return await readExample(components[1])
            } else {
                return await listExamples()
            }

        case "books":
            if components.count > 1 {
                return await readBook(components[1])
            } else {
                return listBooks()
            }

        case "syntax":
            return MCPResourceReadResult(contents: [
                MCPResourceContent(uri: uri, mimeType: "text/markdown", text: syntaxReference)
            ])

        case "actions":
            return MCPResourceReadResult(contents: [
                MCPResourceContent(uri: uri, mimeType: "text/markdown", text: actionsReference)
            ])

        default:
            return nil
        }
    }

    // MARK: - GitHub Fetching

    /// Fetch file content from GitHub or local cache
    private func fetchContent(_ path: String) async -> String? {
        let cacheKey = path

        // Check cache
        if let entry = cache[cacheKey], Date().timeIntervalSince(entry.timestamp) < cacheDuration {
            return entry.content
        }

        // Try local first (for development)
        if let base = localBasePath {
            let localPath = (base as NSString).appendingPathComponent(path)
            if let content = try? String(contentsOfFile: localPath, encoding: .utf8) {
                cache[cacheKey] = CacheEntry(content: content, timestamp: Date())
                return content
            }
        }

        // Fetch from GitHub
        let urlString = "\(Self.rawBase)/\(path)"
        guard let url = URL(string: urlString) else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return nil
            }
            if let content = String(data: data, encoding: .utf8) {
                cache[cacheKey] = CacheEntry(content: content, timestamp: Date())
                return content
            }
        } catch {
            // Network error - return nil
        }

        return nil
    }

    /// List files in a directory from GitHub or local
    private func listDirectory(_ path: String) async -> [String]? {
        // Try local first
        if let base = localBasePath {
            let localPath = (base as NSString).appendingPathComponent(path)
            if let files = try? FileManager.default.contentsOfDirectory(atPath: localPath) {
                return files.sorted()
            }
        }

        // Fetch from GitHub API
        let urlString = "\(Self.apiBase)/\(path)"
        guard let url = URL(string: urlString) else { return nil }

        do {
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return nil
            }

            // Parse GitHub API response
            if let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                return json.compactMap { $0["name"] as? String }.sorted()
            }
        } catch {
            // Network error
        }

        return nil
    }

    // MARK: - Proposals

    private func listProposalFiles() async -> [String]? {
        guard let files = await listDirectory("Proposals") else { return nil }
        return files.filter { $0.hasSuffix(".md") }
    }

    private func listProposals() async -> MCPResourceReadResult {
        guard let files = await listProposalFiles() else {
            return MCPResourceReadResult(contents: [
                MCPResourceContent(
                    uri: "aro://proposals",
                    mimeType: "text/markdown",
                    text: "# ARO Language Proposals\n\nUnable to fetch proposals. Check your network connection."
                )
            ])
        }

        var text = "# ARO Language Proposals\n\n"
        text += "Proposals define the ARO language specification.\n\n"

        for file in files {
            let number = String(file.prefix(8))
            let name = String(file.dropFirst(9).dropLast(3))
                .replacingOccurrences(of: "-", with: " ")
                .capitalized
            text += "- **\(number)**: \(name)\n"
        }

        text += "\n\nUse `aro://proposals/ARO-XXXX` to read a specific proposal."

        return MCPResourceReadResult(contents: [
            MCPResourceContent(uri: "aro://proposals", mimeType: "text/markdown", text: text)
        ])
    }

    private func readProposal(_ number: String) async -> MCPResourceReadResult? {
        guard let files = await listProposalFiles() else { return nil }

        let normalizedNumber = number.uppercased()
        guard let file = files.first(where: { $0.uppercased().hasPrefix(normalizedNumber) }) else {
            return nil
        }

        guard let content = await fetchContent("Proposals/\(file)") else {
            return nil
        }

        return MCPResourceReadResult(contents: [
            MCPResourceContent(uri: "aro://proposals/\(number)", mimeType: "text/markdown", text: content)
        ])
    }

    // MARK: - Examples

    private func listExamples() async -> MCPResourceReadResult {
        guard let dirs = await listDirectory("Examples") else {
            return MCPResourceReadResult(contents: [
                MCPResourceContent(
                    uri: "aro://examples",
                    mimeType: "text/markdown",
                    text: "# ARO Example Applications\n\nUnable to fetch examples. Check your network connection."
                )
            ])
        }

        var text = "# ARO Example Applications\n\n"

        for dir in dirs {
            // Skip hidden files and non-example directories
            if dir.hasPrefix(".") || dir == "README.md" { continue }
            text += "- **\(dir)**\n"
        }

        text += "\n\nUse `aro://examples/{name}` to read an example."

        return MCPResourceReadResult(contents: [
            MCPResourceContent(uri: "aro://examples", mimeType: "text/markdown", text: text)
        ])
    }

    private func readExample(_ name: String) async -> MCPResourceReadResult? {
        guard let files = await listDirectory("Examples/\(name)") else {
            return nil
        }

        let relevantFiles = files.filter {
            $0.hasSuffix(".aro") || $0 == "openapi.yaml" || $0 == "aro.yaml"
        }

        var combinedText = "# Example: \(name)\n\n"

        for file in relevantFiles.sorted() {
            if let content = await fetchContent("Examples/\(name)/\(file)") {
                let lang = file.hasSuffix(".aro") ? "aro" : "yaml"
                combinedText += "## \(file)\n\n```\(lang)\n\(content)\n```\n\n---\n\n"
            }
        }

        if combinedText.count < 50 {
            return nil
        }

        return MCPResourceReadResult(contents: [
            MCPResourceContent(uri: "aro://examples/\(name)", mimeType: "text/markdown", text: combinedText)
        ])
    }

    // MARK: - Books

    private func listBooks() -> MCPResourceReadResult {
        var text = "# ARO Documentation Books\n\n"
        text += "Official ARO documentation:\n\n"
        text += "- **language-guide**: The ARO Language Guide - comprehensive language reference\n"
        text += "- **getting-started**: Getting Started with ARO - tutorial for beginners\n"
        text += "- **plugin-guide**: The Plugin Guide - how to write plugins in Swift, Rust, C, Python\n"
        text += "- **reference**: ARO Reference - API and action reference\n"
        text += "\n\nUse `aro://books/{name}` to read a book."

        return MCPResourceReadResult(contents: [
            MCPResourceContent(uri: "aro://books", mimeType: "text/markdown", text: text)
        ])
    }

    private func readBook(_ name: String) async -> MCPResourceReadResult? {
        let bookDirs: [String: String] = [
            "language-guide": "TheLanguageGuide",
            "getting-started": "AROByExample",
            "plugin-guide": "ThePluginGuide",
            "reference": "Reference"
        ]

        guard let dirName = bookDirs[name] else { return nil }

        guard let files = await listDirectory("Book/\(dirName)") else {
            return nil
        }

        let mdFiles = files.filter { $0.hasSuffix(".md") }.sorted()

        var combinedContent = "# \(name.replacingOccurrences(of: "-", with: " ").capitalized)\n\n"

        for file in mdFiles {
            if let content = await fetchContent("Book/\(dirName)/\(file)") {
                combinedContent += content
                combinedContent += "\n\n---\n\n"
            }
        }

        if combinedContent.count < 50 {
            return nil
        }

        return MCPResourceReadResult(contents: [
            MCPResourceContent(uri: "aro://books/\(name)", mimeType: "text/markdown", text: combinedContent)
        ])
    }

    // MARK: - Static Resources

    private var syntaxReference: String {
        """
        # ARO Syntax Quick Reference

        ## Feature Set

        ```aro
        (Feature Name: Business Activity) {
            <Statement>.
            <Statement>.
        }
        ```

        ## Statement Structure

        ```aro
        <Action> article <result: qualifier> preposition article <object: qualifier>.
        ```

        ## Articles
        - `a`, `an`, `the` (semantic, optional)

        ## Prepositions
        - `from` - source/origin
        - `to` - destination
        - `with` - accompaniment/parameter
        - `for` - purpose/benefit
        - `in` - container/location
        - `on` - surface/topic
        - `against` - comparison
        - `via` - channel/method
        - `into` - container (storage)

        ## Common Patterns

        ### Extract data
        ```aro
        Extract the <field> from the <source: field>.
        Extract the <id> from the <pathParameters: id>.
        Extract the <body> from the <request: body>.
        ```

        ### Extract list elements (ARO-0038)
        ```aro
        Extract the <first-item: first> from the <items>.
        Extract the <last-item: last> from the <items>.
        Extract the <third: 2> from the <items>.
        ```

        ### Log output
        ```aro
        Log "message" to the <console>.
        Log <variable> to the <console>.
        ```

        ### Return result
        ```aro
        Return an <OK: status> for the <result>.
        Return an <OK: status> with <data>.
        Return a <Created: status> with <user>.
        Return a <NotFound: error> for the <id>.
        ```

        ### Store data
        ```aro
        Store the <entity> into the <entity-repository>.
        Store the <stored-entity: entity> into the <entity-repository>.
        ```

        ### Retrieve data
        ```aro
        Retrieve the <entities> from the <entity-repository>.
        Retrieve the <entity> from the <entity-repository> where id = <id>.
        ```

        ### Emit event
        ```aro
        Emit a <EventName: event> with <data>.
        ```

        ### Compute values
        ```aro
        Compute the <result> from <a> + <b>.
        Compute the <length> from the <text>.
        ```

        ### Qualifier-as-name (multiple results of same operation)
        ```aro
        (* Use qualifier to name the operation; base name becomes the variable *)
        Compute the <first-length: length> from the <first-message>.
        Compute the <second-length: length> from the <second-message>.
        Compute the <upper: uppercase> from the <text>.
        Compute the <hash: hash> from the <password>.
        ```

        ### Handler guards (filter event handlers)
        ```aro
        (* Guard on feature set declaration - filters which events this handler processes *)
        (Welcome Email: NotificationSent Handler) when <age> >= 18 {
            Extract the <user> from the <event: user>.
            Send the <email> to the <user: email>.
            Return an <OK: status> for the <notification>.
        }
        ```

        ### Plugin qualifiers (namespace syntax)
        ```aro
        (* Access plugin qualifiers as handler.qualifier-name *)
        Compute the <random: collections.pick-random> from the <items>.
        Compute the <sorted: stats.sort> from the <numbers>.
        ```

        ### Terminal input
        ```aro
        Prompt the <name> with "Enter your name: " from the <terminal>.
        Prompt the <password: hidden> with "Password: " from the <terminal>.
        Select the <env> from the <environments> with "Choose environment: ".
        ```

        ## Special Feature Sets

        ```aro
        (* Application entry point - exactly one required *)
        (Application-Start: My App) { ... }

        (* Optional graceful shutdown handlers - at most one each *)
        (Application-End: Success) { ... }
        (Application-End: Error) { ... }

        (* HTTP handler - matches OpenAPI operationId *)
        (listUsers: User API) { ... }

        (* Event handler *)
        (Handle Event: EventName Handler) { ... }

        (* Event handler with guard *)
        (Handler Name: EventName Handler) when <field> >= value { ... }

        (* Repository observer *)
        (Observe Changes: repository-name Observer) { ... }

        (* File event handler *)
        (On File Created: File Event Handler) { ... }

        (* Socket event handler *)
        (On Message: Socket Event Handler) { ... }
        ```
        """
    }

    private var actionsReference: String {
        """
        # ARO Action Reference

        ## Action Roles

        | Role | Direction | Purpose |
        |------|-----------|---------|
        | REQUEST | External → Internal | Bring data into the feature set |
        | OWN | Internal → Internal | Transform data within the feature set |
        | RESPONSE | Internal → External | Return results or produce output |
        | EXPORT | Internal → Persistent | Make data globally visible |
        | SERVER | System-level | Manage services and connections |
        | TEST | Verification | BDD-style test assertions |

        ---

        ## REQUEST Actions

        ### Extract
        Pull data from structured sources: events, requests, path parameters, body.
        Prepositions: `from`, `via` | Aliases: `parse`, `get`
        ```aro
        Extract the <field> from the <source: field>.
        Extract the <id> from the <pathParameters: id>.
        Extract the <body> from the <request: body>.
        Extract the <first-item: first> from the <list>.
        Extract the <last-item: last> from the <list>.
        Extract the <third: 2> from the <list>.
        ```

        ### Retrieve
        Get data from a repository or data store.
        Prepositions: `from` | Aliases: `fetch`, `load`, `find`
        ```aro
        Retrieve the <users> from the <user-repository>.
        Retrieve the <user> from the <user-repository> where id = <id>.
        ```

        ### Request
        Make an HTTP request to an external URL or API.
        Prepositions: `from`, `to`, `via`, `with` | Aliases: `http`
        ```aro
        Request the <weather> from the <api-url> via GET.
        Request the <result> to the <endpoint> with <payload> via POST.
        ```

        ### Read
        Read file contents or a URL response body.
        Prepositions: `from`
        ```aro
        Read the <config> from the <file: "./config.json">.
        Read the <page> from the <url: "https://example.com">.
        ```

        ### Receive
        Receive data from a socket, stream, or event source.
        Prepositions: `from`, `via`
        ```aro
        Receive the <message> from the <event>.
        ```

        ### List
        List directory contents.
        Prepositions: `from`
        ```aro
        List the <files> from the <directory: "./src">.
        ```

        ### Stat
        Get metadata about a file or directory.
        Prepositions: `for`
        ```aro
        Stat the <info> for the <file: "./doc.pdf">.
        ```

        ### Exists
        Check whether a file or path exists.
        Prepositions: `for`
        ```aro
        Exists the <found> for the <file: "./config.json">.
        ```

        ### Prompt
        Prompt the user for text input via the terminal. Use the `hidden` qualifier to mask input.
        Prepositions: `with`, `from` | Aliases: `ask`
        ```aro
        Prompt the <name> with "Enter your name: " from the <terminal>.
        Prompt the <password: hidden> with "Password: " from the <terminal>.
        ```

        ### Select
        Present a numbered selection menu to the user.
        Prepositions: `from`, `with` | Aliases: `choose`
        ```aro
        Select the <env> from the <environments> with "Choose environment: ".
        ```

        ---

        ## OWN Actions

        ### Create
        Create a new object or data structure.
        Prepositions: `with`, `from`, `for`, `to` | Aliases: `build`, `construct`
        ```aro
        Create the <user> with { name: "Alice", role: "admin" }.
        ```

        ### Compute
        Perform calculations or built-in transformations.
        Prepositions: `from`, `for`, `with` | Aliases: `calculate`, `derive`
        Built-in operations (via qualifier-as-name): `length`, `count`, `uppercase`, `lowercase`, `hash`, `trim`, `reverse`, `abs`
        ```aro
        Compute the <total> from <price> * <quantity>.
        Compute the <upper: uppercase> from the <text>.
        Compute the <hash: hash> from the <password>.
        Compute the <first-len: length> from the <first>.
        ```

        ### Validate
        Check data against rules or schemas.
        Prepositions: `for`, `against`, `with` | Aliases: `verify`, `check`
        ```aro
        Validate the <data> against the <schema>.
        ```

        ### Compare
        Compare two values.
        Prepositions: `against`, `with`, `to` | Aliases: `match`
        ```aro
        Compare the <hash> against the <stored-hash>.
        ```

        ### Transform
        Convert data from one format to another.
        Prepositions: `from`, `into`, `to` | Aliases: `convert`
        ```aro
        Transform the <dto> from the <entity>.
        ```

        ### Update
        Modify or change an existing value.
        Prepositions: `with`, `to`, `for`, `from` | Aliases: `modify`, `change`, `set`, `configure`
        ```aro
        Update the <user> with <changes>.
        ```

        ### Sort
        Order a collection.
        Prepositions: `for`, `with` | Aliases: `order`, `arrange`
        ```aro
        Sort the <users> for the <name>.
        ```

        ### Merge
        Combine two data structures.
        Prepositions: `with`, `from` | Aliases: `combine`
        ```aro
        Merge the <existing-user> with <update-data>.
        ```

        ### Delete
        Remove data or files.
        Prepositions: `from`, `for` | Aliases: `remove`, `destroy`
        ```aro
        Delete the <user> from the <user-repository> where id = <id>.
        Delete the <file: "./temp.txt">.
        ```

        ### Accept
        Accept a state transition (used in state machines).
        Prepositions: `on`
        ```aro
        Accept the <order: placed>.
        ```

        ### Execute
        Run a shell command and capture the output.
        Prepositions: `on`, `with`, `for` | Aliases: `exec`, `run`, `shell`
        ```aro
        Execute the <result> for the <command: "git"> with "status".
        ```

        ### Call
        Call an external service, plugin action, or API endpoint.
        Prepositions: `from`, `to`, `with`, `via` | Aliases: `invoke`
        ```aro
        Call the <result> via <API: POST /users> with <payload>.
        ```

        ### ParseHtml
        Parse HTML content into structured data.
        Prepositions: `from`
        Specifiers: `markdown` (convert to Markdown), `links` (extract hyperlinks), `title` (extract page title)
        ```aro
        ParseHtml the <document> from the <html-content>.
        ParseHtml the <links: links> from the <html-content>.
        ParseHtml the <text: markdown> from the <html-content>.
        ```

        ### Map
        Transform each element in a collection.
        Prepositions: `from`, `to`
        ```aro
        Map the <names> from the <users: name>.
        ```

        ### Filter
        Select elements matching a condition.
        Prepositions: `from`
        ```aro
        Filter the <active> from the <users> where status = "active".
        ```

        ### Reduce
        Aggregate a collection to a single value.
        Prepositions: `from`, `with` | Aliases: `aggregate`
        ```aro
        Reduce the <total> from the <items> with sum(<amount>).
        ```

        ### Split
        Split a string by a delimiter or regex.
        Prepositions: `from`
        ```aro
        Split the <parts> from the <csv-line> by /,/.
        ```

        ### Clear
        Clear the terminal screen.
        Prepositions: `for`
        ```aro
        Clear the <screen> for the <terminal>.
        ```

        ---

        ## RESPONSE Actions

        ### Return
        Return a result from the feature set.
        Prepositions: `for`, `to`, `with` | Aliases: `respond`
        Status codes: `OK`, `Created`, `Accepted`, `NoContent`, `BadRequest`, `Unauthorized`, `Forbidden`, `NotFound`, `Error`, `InternalError`
        ```aro
        Return an <OK: status> with <data>.
        Return a <Created: status> with <user>.
        Return a <NotFound: error> for the <id>.
        ```

        ### Throw
        Return an error result.
        Prepositions: `for` | Aliases: `raise`, `fail`
        ```aro
        Throw a <NotFound: error> for the <resource>.
        ```

        ### Send
        Send data to a destination (email, HTTP endpoint, etc.).
        Prepositions: `to`, `via`, `with` | Aliases: `dispatch`
        ```aro
        Send the <email> to the <recipient: email>.
        ```

        ### Log
        Write a message to the console or log output.
        Prepositions: `for`, `to`, `with` | Aliases: `print`, `output`, `debug`
        ```aro
        Log "Starting..." to the <console>.
        Log <error> to the <console>.
        ```

        ### Write
        Write data to a file or URL.
        Prepositions: `to`, `into`
        ```aro
        Write the <report> to the <file: "./report.txt">.
        ```

        ### Broadcast
        Send a message to all connected socket clients.
        Prepositions: `to`, `via`
        ```aro
        Broadcast the <message> to the <socket-server>.
        ```

        ### Notify
        Send a notification to a recipient or collection of recipients.
        When given a collection, one notification is dispatched per item.
        Prepositions: `to`, `for`, `with` | Aliases: `alert`, `signal`
        ```aro
        Notify the <user> with "Your order shipped".
        Notify the <subscribers> with "New post available".
        ```
        Handler guards filter which handler processes each notification:
        ```aro
        (Welcome Email: NotificationSent Handler) when <age> >= 18 {
            Extract the <user> from the <event: user>.
            Return an <OK: status> for the <notification>.
        }
        ```

        ---

        ## EXPORT Actions

        ### Store
        Save data to a repository. The stored entity has an auto-generated `id` added.
        Prepositions: `into`, `to`, `in` | Aliases: `save`, `persist`
        ```aro
        Store the <user> into the <user-repository>.
        Store the <stored-user: user> into the <user-repository>.
        ```

        ### Publish
        Make a variable available across feature sets with the same business activity.
        Prepositions: `with` | Aliases: `export`, `expose`, `share`
        ```aro
        Publish as <config> <settings>.
        ```

        ### Emit
        Emit a domain event to the event bus.
        Prepositions: `with`, `to`
        ```aro
        Emit a <UserCreated: event> with <user>.
        ```

        ### Append
        Append content to a file.
        Prepositions: `to`, `into`
        ```aro
        Append the <entry> to the <file: "./log.txt">.
        ```

        ---

        ## SERVER Actions

        ### Start
        Start a service (HTTP server, socket server, file monitor).
        Prepositions: `with`
        ```aro
        Start the <http-server> with <contract>.
        Start the <socket-server> with { port: 9000 }.
        Start the <file-monitor> with "./uploads".
        ```

        ### Stop
        Stop a running service.
        Prepositions: `with`
        ```aro
        Stop the <http-server> with <application>.
        ```

        ### Listen
        Listen for incoming socket connections.
        Prepositions: `on`, `for`, `to`
        ```aro
        Listen on port 9000 as <socket-server>.
        ```

        ### Keepalive
        Keep the application running to process events. Blocks until SIGINT/SIGTERM.
        Prepositions: `for` | Aliases: `wait`, `block`
        ```aro
        Keepalive the <application> for the <events>.
        ```

        ### Connect
        Connect to a socket or external service.
        Prepositions: `to`, `with`
        ```aro
        Connect the <client> to the <host: "localhost:9000">.
        ```

        ### Close
        Close a connection or socket.
        Prepositions: `with`, `from` | Aliases: `disconnect`, `terminate`
        ```aro
        Close the <connection>.
        ```

        ### Make
        Create a directory (with all intermediate directories).
        Prepositions: `to`, `for`, `at` | Aliases: `createdirectory`, `mkdir`
        ```aro
        Make the <dir> to the <path: "./output/reports">.
        ```

        ### Copy
        Copy a file or directory.
        Prepositions: `to`
        ```aro
        Copy the <file: "./source.txt"> to the <destination: "./copy.txt">.
        ```

        ### Move
        Move or rename a file or directory.
        Prepositions: `to` | Aliases: `rename`
        ```aro
        Move the <file: "./draft.txt"> to the <destination: "./final.txt">.
        ```

        ### Call
        Call an external service or plugin action.
        Prepositions: `from`, `to`, `with`, `via` | Aliases: `invoke`
        ```aro
        Call the <result> via <API: POST /users> with <payload>.
        ```

        ---

        ## TEST Actions

        ### Given / When / Then / Assert
        BDD-style test setup, action, and assertion.
        ```aro
        Given the <user> with { name: "Test User" }.
        When the <result> from the <action>.
        Then the <result> with <expected>.
        Assert the <value> for <condition>.
        ```

        ---

        ## Preposition Reference

        | Preposition | Meaning | Typical Usage |
        |-------------|---------|---------------|
        | `from` | Source / origin | `Extract the <x> from the <y>` |
        | `to` | Destination | `Send the <x> to the <y>` |
        | `with` | Parameter / accompaniment | `Create the <x> with <data>` |
        | `for` | Purpose / benefit | `Return an <OK: status> for the <result>` |
        | `into` | Container | `Store the <x> into the <repo>` |
        | `on` | Surface / event | `Accept the <x: state> on <event>` |
        | `against` | Comparison target | `Compare the <x> against the <y>` |
        | `via` | Channel / method | `Request the <x> via POST` |

        ---

        ## Qualifier Reference

        | Qualifier | Context | Description |
        |-----------|---------|-------------|
        | `status` | Return / Throw | HTTP response status code |
        | `event` | Extract / Emit | Domain event type |
        | `first` | Extract | First element of a list |
        | `last` | Extract | Last element of a list |
        | `0`, `1`, `2` | Extract | Reverse index (0 = last) |
        | `hidden` | Prompt | Mask input (password entry) |
        | `length` / `count` | Compute | String or collection length |
        | `uppercase` | Compute | Convert to uppercase |
        | `lowercase` | Compute | Convert to lowercase |
        | `hash` | Compute | Hash a value |
        | `markdown` | ParseHtml | Convert HTML to Markdown |
        | `links` | ParseHtml | Extract all hyperlinks |
        | `title` | ParseHtml | Extract page title |
        | `handler.qualifier` | Compute | Plugin qualifier (e.g. `collections.pick-random`) |
        """
    }
}
