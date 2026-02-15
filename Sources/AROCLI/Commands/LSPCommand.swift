// ============================================================
// LSPCommand.swift
// AROCLI - Language Server Protocol Command
// ============================================================

#if !os(Windows)
import ArgumentParser
import Foundation
import AROLSP

struct LSPCommand: ParsableCommand {
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

            Features supported:
              - Real-time diagnostics (errors and warnings)
              - Hover information (types, documentation)
              - Go to definition
              - Find references
              - Code completion
              - Document outline (symbols)
              - Workspace symbol search
              - Code formatting
              - Symbol rename
              - Folding ranges
              - Semantic tokens (enhanced highlighting)
              - Signature help
              - Code actions (quick fixes)

            Example:
              aro lsp               # Start server on stdio
              aro lsp --debug       # Start with debug logging
            """
    )

    @Flag(name: .long, help: "Enable debug logging to stderr")
    var debug: Bool = false

    @Flag(name: .long, help: "Use stdio transport (default, accepted for compatibility)")
    var stdio: Bool = false

    func run() {
        // --stdio is accepted for compatibility with VSCode language client
        // but stdio is already the default and only transport
        let server = AROLanguageServer(debug: debug)
        // Run synchronously using RunLoop to avoid async runtime issues
        server.runStdioSync()
    }
}
#endif
