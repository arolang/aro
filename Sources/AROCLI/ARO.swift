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

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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
                  echo 'Log "Hi" to the <console>.' | aro   # Evaluate piped source
                """,
            version: AROVersion.shortVersion,
            subcommands: subcommandsList,
            defaultSubcommand: RunCommand.self
        )
    }()

    /// Custom entry point: when invoked with no arguments and stdin is not a
    /// TTY, evaluate the piped ARO source through the REPL session (issue
    /// #200). Otherwise dispatch to ArgumentParser as usual.
    static func main() async {
        if shouldRunStdinScript() {
            await runStdinScript()
            return
        }
        await self.main(nil)
    }

    /// True when no CLI arguments were supplied and stdin is connected to a
    /// pipe or file rather than a terminal.
    private static func shouldRunStdinScript() -> Bool {
        return CommandLine.arguments.count == 1 && !TTYDetector.stdinIsTTY
    }

    private static func runStdinScript() async {
        // Force unbuffered stdout so output reaches the consumer of the pipe
        // immediately. Mirrors RunCommand.run().
        #if canImport(Darwin)
        setvbuf(stdout, nil, _IONBF, 0)
        #endif

        guard let source = StdinScriptRunner.readStdin() else {
            FileHandle.standardError.write(Data("Error: invalid UTF-8 on stdin\n".utf8))
            Self.exit(withError: ExitCode.failure)
        }

        let result = await StdinScriptRunner.run(source: source)
        switch result {
        case .success, .empty:
            return
        case .failure(let message):
            FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
            Self.exit(withError: ExitCode.failure)
        }
    }

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
