// ============================================================
// MCPResourceProvider.swift
// ARO MCP - Resource Implementations (GitHub-backed)
// ============================================================

import Foundation

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

        ## Common Patterns

        ### Extract data
        ```aro
        <Extract> the <field> from the <source: field>.
        ```

        ### Log output
        ```aro
        <Log> "message" to the <console>.
        <Log> <variable> to the <console>.
        ```

        ### Return result
        ```aro
        <Return> an <OK: status> for the <result>.
        <Return> an <OK: status> with <data>.
        ```

        ### Store data
        ```aro
        <Store> the <entity> in the <entity-repository>.
        ```

        ### Retrieve data
        ```aro
        <Retrieve> the <entities> from the <entity-repository>.
        <Retrieve> the <entity> from the <entity-repository> where id = <id>.
        ```

        ### Emit event
        ```aro
        <Emit> a <EventName: event> with <data>.
        ```

        ### Compute values
        ```aro
        <Compute> the <result> from <a> + <b>.
        <Compute> the <length> from the <text>.
        ```

        ## Special Feature Sets

        ```aro
        (* Application entry point - exactly one required *)
        (Application-Start: My App) { ... }

        (* HTTP handler - matches OpenAPI operationId *)
        (listUsers: User API) { ... }

        (* Event handler *)
        (Handle Event: EventName Handler) { ... }

        (* Repository observer *)
        (Observe Changes: repository-name Observer) { ... }
        ```
        """
    }

    private var actionsReference: String {
        """
        # ARO Action Reference

        ## Action Roles

        Actions are classified by data flow direction:

        ### REQUEST (External -> Internal)
        Bring data into the feature set:
        - **Extract**: Get data from events, requests, parameters
        - **Retrieve**: Get data from repositories
        - **Fetch**: Get data from external HTTP services
        - **Parse**: Parse structured data (JSON, HTML, XML)
        - **Read**: Read from files

        ### OWN (Internal -> Internal)
        Transform data within the feature set:
        - **Compute**: Calculate values, transform data
        - **Validate**: Check data against rules
        - **Create**: Create new objects
        - **Compare**: Compare values
        - **Transform**: Convert data formats
        - **Match**: Pattern matching
        - **Filter**: Filter collections
        - **Sort**: Sort collections

        ### RESPONSE (Internal -> External)
        Return results from the feature set:
        - **Return**: Return success with optional data
        - **Throw**: Return error/exception

        ### EXPORT (Internal -> External)
        Send data outside the feature set:
        - **Log**: Write to console/logs
        - **Store**: Save to repository
        - **Update**: Update existing data in repository
        - **Delete**: Remove from repository
        - **Send**: Send HTTP request
        - **Emit**: Emit domain event
        - **Publish**: Make variable globally visible
        - **Write**: Write to file

        ## Preposition Reference

        Each action has valid prepositions:

        | Action | Valid Prepositions |
        |--------|-------------------|
        | Extract | from |
        | Retrieve | from |
        | Fetch | from |
        | Compute | from, with |
        | Validate | against, with |
        | Create | with, from |
        | Return | for, with |
        | Log | to |
        | Store | in |
        | Emit | with |
        | Send | to |
        """
    }
}
