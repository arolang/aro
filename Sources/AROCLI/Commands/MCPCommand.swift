// ============================================================
// MCPCommand.swift
// ARO CLI - MCP Server Command
// ============================================================

import ArgumentParser
import Foundation
import ARORuntime
import AROVersion

struct MCPCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Start ARO as an MCP (Model Context Protocol) server",
        discussion: """
            Starts ARO as an MCP server that LLMs can use to learn about
            and interact with ARO.

            The server exposes:
            - Tools: aro_check, aro_run, aro_actions, aro_parse, aro_syntax
            - Resources: proposals, examples, books, syntax reference
            - Prompts: guided workflows for creating features, APIs, etc.

            Usage with Claude Desktop:
            Add to ~/.config/claude/claude_desktop_config.json:

              {
                "mcpServers": {
                  "aro": {
                    "command": "aro",
                    "args": ["mcp"]
                  }
                }
              }

            The server uses stdio transport (reads JSON-RPC from stdin,
            writes to stdout).
            """
    )

    @Option(name: .long, help: "Path to ARO installation (for documentation)")
    var basePath: String?

    @Flag(name: .long, help: "Enable verbose logging to stderr")
    var verbose: Bool = false

    func run() async throws {
        // Determine base path
        let path = basePath ?? findAROBasePath()

        // Create and run server
        let server = MCPServer(basePath: path, verbose: verbose, version: AROVersion.version)
        await server.run()
    }

    /// Try to find the ARO installation path
    private func findAROBasePath() -> String? {
        // Check common locations
        let candidates = [
            // Development: current directory
            FileManager.default.currentDirectoryPath,
            // Homebrew
            "/opt/homebrew/share/aro",
            "/usr/local/share/aro",
            // User home
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".aro").path
        ]

        for candidate in candidates {
            let proposalsPath = (candidate as NSString).appendingPathComponent("Proposals")
            if FileManager.default.fileExists(atPath: proposalsPath) {
                return candidate
            }
        }

        return nil
    }
}
