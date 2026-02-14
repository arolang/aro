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

    func run() async throws {
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
}
