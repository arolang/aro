// ReplCommand.swift
// ARO REPL CLI Command
//
// Launches the interactive ARO REPL

import ArgumentParser
import Foundation
import ARORuntime
import AROVersion

struct ReplCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "repl",
        abstract: "Start the interactive ARO REPL"
    )

    @Argument(help: ArgumentHelp(
        "Project directory to open the session inside",
        discussion: """
            Wires in what `aro run` discovers for that directory — openapi.yaml,             .store seed data, templates/, project plugins and the project's own             feature sets — without executing Application-Start (GitLab #691).
            """))
    var project: String?

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

        // One session for the whole command. A project is wired into *this*
        // one and the shell is handed it, because whatever the project
        // registers has to be there when the first line is typed — building a
        // throwaway session to load into was the shape of the original bug.
        let session = REPLSession()

        if let project {
            let context = await REPLProjectContext.load(
                directory: project, into: session)
            print(context.summary)
            print("")
        }

        let shell = REPLShell(session: session)
        shell.useColors = !noColor

        // Pre-load file if specified
        if let loadPath = load {
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
        let session = REPLSession()

        // Plugins installed by `:plugin add` in earlier sessions load
        // here too — a notebook restarted yesterday's kernel must not
        // silently lose yesterday's plugins (the terminal REPL has
        // always reloaded them; the JSON server forgot to).
        let replPluginsDir = PluginCommand.replPluginsDirectory
        if FileManager.default.fileExists(
            atPath: replPluginsDir.appendingPathComponent("Plugins").path) {
            do {
                try UnifiedPluginLoader.shared.loadPlugins(from: replPluginsDir)
            } catch {
                FileHandle.standardError.write(Data(
                    "Warning: failed to load installed REPL plugins: \(error)\n".utf8))
            }
        }

        if let project {
            let context = await REPLProjectContext.load(
                directory: project, into: session)
            // stderr, not stdout: stdout is the protocol (ARO-0091), and a
            // notice on it would be a line the client cannot parse.
            FileHandle.standardError.write(Data((context.summary + "\n").utf8))
        }

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
