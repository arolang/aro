// ============================================================
// main.swift
// ARO CLI - Command Line Interface
// ============================================================

import ArgumentParser
import Foundation
import AROParser
import ARORuntime
import AROCompiler
import AROVersion

@main
struct ARO: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "aro",
        abstract: "ARO Compiler and Runtime",
        discussion: """
            The ARO CLI compiles and runs ARO applications.

            ARO is a domain-specific language for expressing business features
            as Action-Result-Object statements.

            Example:
              aro run ./Examples/HelloWorld     # Run with interpreter
              aro build ./Examples/HelloWorld   # Compile to native binary
              aro test ./Examples/Calculator    # Run tests
              aro compile myapp.aro             # Compile and check syntax
              aro check myapp.aro               # Syntax check only
            """,
        version: AROVersion.shortVersion,
        subcommands: subcommandsList,
        defaultSubcommand: RunCommand.self
    )

    // LSP command is only available on non-Windows platforms
    private static var subcommandsList: [any ParsableCommand.Type] {
        var commands: [any ParsableCommand.Type] = [
            RunCommand.self,
            BuildCommand.self,
            CompileCommand.self,
            CheckCommand.self,
            TestCommand.self,
        ]
        #if !os(Windows)
        commands.append(LSPCommand.self)
        #endif
        return commands
    }
}
