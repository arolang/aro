// ReplCommand.swift
// ARO REPL CLI Command
//
// Launches the interactive ARO REPL

import ArgumentParser
import Foundation
import AROVersion

struct ReplCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "repl",
        abstract: "Start the interactive ARO REPL"
    )

    @Option(name: .shortAndLong, help: "Pre-load definitions from file")
    var load: String?

    @Flag(name: .long, help: "Disable colored output")
    var noColor: Bool = false

    @Flag(name: .long, help: "Speak line-delimited JSON on stdio instead of running a terminal REPL")
    var json: Bool = false

    func run() async throws {
        if json {
            try await runJSON()
            return
        }

        let shell = REPLShell()
        shell.useColors = !noColor

        // Pre-load file if specified
        if let loadPath = load {
            let session = REPLSession()
            let loadCmd = LoadCommand()
            let result = try await loadCmd.execute(args: [loadPath], session: session)

            switch result {
            case .output(let msg):
                print(msg)
            case .error(let msg):
                print("Error loading file: \(msg)")
                throw ExitCode.failure
            default:
                break
            }
        }

        await shell.run()
    }

    /// Machine-readable mode: one JSON object per line on stdio.
    ///
    /// The log prefix is suppressed because the consumer is a program (a
    /// notebook cell, an editor panel) that already knows where the output
    /// came from — `[_repl_session_]` in front of every line is noise there.
    private func runJSON() async throws {
        let session = REPLSession(suppressLogPrefix: true)

        if let loadPath = load {
            let result = try await LoadCommand().execute(args: [loadPath], session: session)
            if case .error(let message) = result {
                FileHandle.standardError.write(Data("Error loading file: \(message)\n".utf8))
                throw ExitCode.failure
            }
        }

        await JSONREPLServer(session: session).run()
    }
}
