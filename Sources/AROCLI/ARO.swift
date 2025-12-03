// ============================================================
// main.swift
// ARO CLI - Command Line Interface
// ============================================================

import ArgumentParser
import Foundation
import AROParser
import ARORuntime
import AROCompiler

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
        version: "1.0.0",
        subcommands: [
            RunCommand.self,
            BuildCommand.self,
            CompileCommand.self,
            CheckCommand.self,
            TestCommand.self,
        ],
        defaultSubcommand: RunCommand.self
    )
}
