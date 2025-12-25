// ============================================================
// LSPCommand.swift
// AROCLI - Language Server Protocol Command
// ============================================================

#if !os(Windows)
import ArgumentParser
import Foundation
import AROLSP

struct LSPCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lsp",
        abstract: "Start the ARO Language Server",
        discussion: """
            Starts the ARO Language Server for IDE integration.

            The server communicates via stdio using the Language Server Protocol (LSP).
            This command is typically invoked by IDE extensions, not directly by users.

            Features supported:
              - Real-time diagnostics (errors and warnings)
              - Hover information (types, documentation)
              - Go to definition
              - Find references
              - Code completion
              - Document outline (symbols)

            Example:
              aro lsp               # Start server on stdio
              aro lsp --debug       # Start with debug logging
            """
    )

    @Flag(name: .long, help: "Enable debug logging to stderr")
    var debug: Bool = false

    func run() async throws {
        if debug {
            FileHandle.standardError.write("ARO Language Server starting...\n".data(using: .utf8)!)
        }

        let server = AROLanguageServer()
        try await server.runStdio()
    }
}
#endif
