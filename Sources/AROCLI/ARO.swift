// ============================================================
// main.swift
// ARO CLI - Command Line Interface
// ============================================================

import ArgumentParser
import Foundation
import Logging
import AROParser
import ARORuntime
import AROCompiler
import AROPackageManager
import AROVersion

@main
struct ARO: AsyncParsableCommand {
    /// Bootstrap the logging system before any subcommand runs.
    private static let _bootstrapLogging: Void = {
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardError(label: label)
            handler.logLevel = .info
            return handler
        }
    }()

    static let configuration: CommandConfiguration = {
        _bootstrapLogging
        return CommandConfiguration(
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
    }()

    // LSP and MCP commands are only available on non-Windows platforms
    private static var subcommandsList: [any ParsableCommand.Type] {
        var commands: [any ParsableCommand.Type] = [
            RunCommand.self,
            BuildCommand.self,
            CompileCommand.self,
            CheckCommand.self,
            TestCommand.self,
            ReplCommand.self,
            NewCommand.self,
            AddCommand.self,
            RemoveCommand.self,
            PluginsCommand.self,
            ActionsCommand.self,
        ]
        #if !os(Windows)
        commands.append(LSPCommand.self)
        commands.append(MCPCommand.self)
        #endif
        return commands
    }
}
