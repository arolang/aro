// ============================================================
// AskCommand.swift
// AROAsk - `aro ask` ArgumentParser entry point
// ============================================================

import ArgumentParser
import Foundation
import LineNoise

public struct AskCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "ask",
        abstract: "ARO coding assistant powered by a local language model",
        discussion: """
            `aro ask` is an interactive coding assistant that can read, write,
            and test ARO code in your project using a local language model
            (default: ARO-Lang/aro-coder-4bit).

            It can generate ARO code, answer questions about the language,
            fix errors, create plugins, generate OpenAPI contracts, and
            write documentation — all with tool calling and context awareness.

            EXAMPLES:
              aro ask "write a feature set that greets a user"
              aro ask "what actions are available in ARO?"
              aro ask /fix ./MyApp/main.aro
              aro ask /plugin my-analytics
              aro ask /docs ./MyApp
              aro ask                                            # interactive REPL

            BACKEND SELECTION (automatic):
              1. $ARO_ASK_ENDPOINT  (OpenAI-compatible URL)
              2. llama-server       (GGUF via llama.cpp)
              3. mlx_lm.server     (Apple Silicon via mlx-lm)

            The conversation is persisted to .context (YAML) in the current
            working directory. Use /clean to start fresh.
            """
    )

    public init() {}

    @Argument(parsing: .remaining, help: "Prompt or slash command. Omit to enter the REPL.")
    public var prompt: [String] = []

    @Option(name: .long, help: "Model identifier (default: ARO-Lang/aro-coder-4bit)")
    public var model: String = "ARO-Lang/aro-coder-4bit"

    @Flag(name: .long, help: "Approve all tool calls without prompting")
    public var yes: Bool = false

    @Flag(name: .long, help: "Do not connect to any MCP servers")
    public var noMcp: Bool = false

    @Option(name: .long, help: "Sampling temperature (default 0.2)")
    public var temperature: Double = 0.2

    @Flag(name: [.short, .long], help: "Print backend chatter (model loading, runner stdout/stderr). Sets ARO_ASK_VERBOSE.")
    public var verbose: Bool = false

    public func run() async throws {
        // Backends read ARO_ASK_VERBOSE from the environment to decide
        // whether to surface model-load and runner output. The flag is
        // just sugar for setting it.
        if verbose { setenv("ARO_ASK_VERBOSE", "1", 1) }

        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

        let firstWord = prompt.first ?? ""

        // Slash commands that run offline
        if firstWord.hasPrefix("/") {
            try await runSlashCommand(cwd: cwd)
            return
        }

        // Interactive REPL
        if prompt.isEmpty {
            try await runREPL(cwd: cwd)
            return
        }

        // One-shot prompt
        let session = AskSession(config: sessionConfig(cwd: cwd))
        let manager = try ModelManager()
        try await ensureModel(manager: manager)
        try await session.prepare(modelManager: manager)
        defer { Task { await session.shutdown() } }
        let answer = try await session.ask(prompt.joined(separator: " "))
        print(answer)
    }

    // MARK: - Slash dispatch

    private func runSlashCommand(cwd: URL) async throws {
        let cmd = prompt[0]
        let args = Array(prompt.dropFirst())

        switch cmd {
        case "/help":
            TerminalUI.printHelp()

        case "/clean":
            let store = ContextStore(workingDirectory: cwd)
            if try store.clear() {
                print("Deleted .context")
            } else {
                print("No .context to delete")
            }

        case "/show":
            let store = ContextStore(workingDirectory: cwd)
            guard let context = try store.load() else {
                print("No .context in \(cwd.path)")
                return
            }
            print("\(Style.bold)model:\(Style.reset) \(context.model)")
            print("\(Style.bold)messages:\(Style.reset) \(context.messages.count)")
            for (i, m) in context.messages.enumerated() {
                let preview = (m.content ?? "").prefix(200)
                let color = m.role == "assistant" ? Style.cyan : (m.role == "user" ? Style.green : Style.dim)
                print("  \(color)[\(i)] \(m.role):\(Style.reset) \(preview)")
            }

        case "/tools":
            let session = AskSession(config: sessionConfig(cwd: cwd))
            try await session.prepareRegistryOnly()
            let names = await session.toolNames()
            for name in names {
                print("  \(Style.cyan)\(name)\(Style.reset)")
            }
            await session.shutdown()

        case "/model":
            let manager = try ModelManager()
            let entry = try await manager.entry(for: model)
            let dir = await manager.modelDirectory(for: model)
            let installed = await manager.isInstalled(model)
            print("\(Style.bold)model:\(Style.reset)     \(model)")
            print("\(Style.bold)path:\(Style.reset)      \(dir.path)")
            print("\(Style.bold)backend:\(Style.reset)   \(entry.backend)")
            print("\(Style.bold)context:\(Style.reset)   \(entry.contextLength ?? 0)")
            print("\(Style.bold)installed:\(Style.reset) \(installed ? Style.green + "yes" : Style.red + "no")\(Style.reset)")

            // Check for updates
            let status = await manager.checkForUpdate(model)
            switch status {
            case .upToDate:
                print("\(Style.bold)status:\(Style.reset)    \(Style.green)up to date\(Style.reset)")
            case .updateAvailable(let local, let remote):
                print("\(Style.bold)status:\(Style.reset)    \(Style.yellow)update available\(Style.reset)")
                print("  local:  \(local.prefix(12))")
                print("  remote: \(remote.prefix(12))")
            case .notInstalled:
                print("\(Style.bold)status:\(Style.reset)    \(Style.red)not installed\(Style.reset)")
            case .checkFailed:
                print("\(Style.bold)status:\(Style.reset)    \(Style.dim)offline (cannot check)\(Style.reset)")
            }

        case "/mcp":
            let session = AskSession(config: sessionConfig(cwd: cwd))
            try await session.prepareRegistryOnly()
            let labels = await session.mcpServerLabels()
            if labels.isEmpty {
                print("No MCP servers bridged")
            } else {
                for l in labels { print("  \(Style.cyan)\(l)\(Style.reset)") }
            }
            await session.shutdown()

        case "/index":
            let session = AskSession(config: sessionConfig(cwd: cwd))
            try await session.prepareRegistryOnly()
            TerminalUI.printStatus("Indexing project...")
            let count = try await session.rebuildIndex()
            print("Indexed \(count) chunks")
            await session.shutdown()

        case "/search":
            let query = args.joined(separator: " ")
            guard !query.isEmpty else {
                print("Usage: aro ask /search <query>")
                return
            }
            let session = AskSession(config: sessionConfig(cwd: cwd))
            try await session.prepareRegistryOnly()
            let results = try await session.search(query: query, k: 5)
            if results.isEmpty {
                print("No results — run \(Style.cyan)aro ask /index\(Style.reset) first")
            } else {
                for r in results {
                    let score = String(format: "%.3f", r.score)
                    print("  \(Style.cyan)\(r.chunk.path)\(Style.reset):\(r.chunk.startLine)-\(r.chunk.endLine)  (\(score))")
                }
            }
            await session.shutdown()

        case "/fix":
            guard !args.isEmpty else {
                print("Usage: aro ask /fix <path>")
                print("  Runs aro check, diagnoses errors, fixes the code, and writes back.")
                return
            }
            let session = AskSession(config: sessionConfig(cwd: cwd))
            let manager = try ModelManager()
            try await ensureModel(manager: manager)
            try await session.prepare(modelManager: manager)
            defer { Task { await session.shutdown() } }
            let path = args.joined(separator: " ")
            let result = try await session.fix(path: path)
            print(result)

        case "/explain":
            guard !args.isEmpty else {
                print("Usage: aro ask /explain <path>")
                return
            }
            let session = AskSession(config: sessionConfig(cwd: cwd))
            let manager = try ModelManager()
            try await ensureModel(manager: manager)
            try await session.prepare(modelManager: manager)
            defer { Task { await session.shutdown() } }
            let path = args.joined(separator: " ")
            let answer = try await session.ask("Use the read_file tool to read \(path), then explain what each feature set does, what events trigger them, and how data flows through the application.")
            print(answer)

        case "/docs":
            guard !args.isEmpty else {
                print("Usage: aro ask /docs <path>")
                return
            }
            let session = AskSession(config: sessionConfig(cwd: cwd))
            let manager = try ModelManager()
            try await ensureModel(manager: manager)
            try await session.prepare(modelManager: manager)
            defer { Task { await session.shutdown() } }
            let path = args.joined(separator: " ")
            let answer = try await session.ask("Read all .aro files in \(path), then use generate_docs to create a comprehensive README.md. Also read the openapi.yaml if present and document the API endpoints.")
            print(answer)

        case "/plugin":
            guard !args.isEmpty else {
                print("Usage: aro ask /plugin <name>")
                return
            }
            let session = AskSession(config: sessionConfig(cwd: cwd))
            let manager = try ModelManager()
            try await ensureModel(manager: manager)
            try await session.prepare(modelManager: manager)
            defer { Task { await session.shutdown() } }
            let name = args[0]
            let desc = args.count > 1 ? args.dropFirst().joined(separator: " ") : ""
            let answer = try await session.ask("Create a new ARO plugin named '\(name)'\(desc.isEmpty ? "" : " that \(desc)"). Use the create_plugin tool with an appropriate language and handle. Then explain how to use the plugin in ARO code.")
            print(answer)

        case "/openapi":
            let session = AskSession(config: sessionConfig(cwd: cwd))
            let manager = try ModelManager()
            try await ensureModel(manager: manager)
            try await session.prepare(modelManager: manager)
            defer { Task { await session.shutdown() } }
            let desc = args.joined(separator: " ")
            let answer: String
            if desc.isEmpty {
                answer = try await session.ask("Look at the .aro files in this directory and generate an openapi.yaml that matches the feature sets. Use write_openapi to create the file.")
            } else {
                answer = try await session.ask("Generate an openapi.yaml for: \(desc). Use write_openapi to create the file.")
            }
            print(answer)

        case "/quit", "/exit":
            return

        default:
            TerminalUI.printError("Unknown command: \(cmd)")
            print("Type \(Style.cyan)/help\(Style.reset) for available commands")
            throw ExitCode.failure
        }
    }

    // MARK: - REPL

    private func runREPL(cwd: URL) async throws {
        let session = AskSession(config: sessionConfig(cwd: cwd))
        let manager = try ModelManager()
        try await ensureModel(manager: manager)
        try await session.prepare(modelManager: manager)
        defer { Task { await session.shutdown() } }

        let isTTY = isatty(STDIN_FILENO) != 0
        let ln: LineNoise? = isTTY ? LineNoise() : nil

        TerminalUI.printBanner()

        let info = await session.backendInfo()
        TerminalUI.printStatus("backend: \(info.name) · model: \(info.model)")
        print("Type \(Style.cyan)/help\(Style.reset) for commands, \(Style.cyan)/quit\(Style.reset) to exit\n")

        while true {
            let line: String?
            if let ln = ln {
                do {
                    // Plain prompt: LineNoise counts every byte of ANSI
                    // escapes as visible width and miscalculates the cursor
                    // column, so the cursor jumps after the first keystroke.
                    let raw = try ln.getLine(prompt: "ask> ")
                    print()
                    if !raw.trimmingCharacters(in: .whitespaces).isEmpty {
                        ln.addHistory(raw)
                    }
                    line = raw
                } catch LinenoiseError.CTRL_C {
                    line = ""
                } catch LinenoiseError.EOF {
                    return
                } catch {
                    return
                }
            } else {
                print("\(Style.green)ask>\(Style.reset) ", terminator: "")
                fflush(nil)
                line = readLine()
            }

            guard let text = line else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            // Handle inline slash commands
            if trimmed == "/quit" || trimmed == "/exit" { return }
            if trimmed == "/help" { TerminalUI.printHelp(); continue }
            if trimmed == "/clean" {
                _ = try await session.clear()
                print("Deleted .context")
                continue
            }
            if trimmed == "/tools" {
                for name in await session.toolNames() {
                    print("  \(Style.cyan)\(name)\(Style.reset)")
                }
                continue
            }
            if trimmed == "/model" {
                let info = await session.backendInfo()
                print("\(Style.bold)backend:\(Style.reset) \(info.name) · \(Style.bold)model:\(Style.reset) \(info.model)")
                continue
            }
            if trimmed == "/mcp" {
                let labels = await session.mcpServerLabels()
                print(labels.isEmpty ? "No MCP servers" : labels.joined(separator: "\n"))
                continue
            }
            if trimmed == "/index" {
                TerminalUI.printStatus("Indexing project...")
                let count = try await session.rebuildIndex()
                print("Indexed \(count) chunks")
                continue
            }
            if trimmed.hasPrefix("/search ") {
                let query = String(trimmed.dropFirst("/search ".count))
                let results = try await session.search(query: query, k: 5)
                if results.isEmpty {
                    print("No results")
                } else {
                    for r in results {
                        let score = String(format: "%.3f", r.score)
                        print("  \(Style.cyan)\(r.chunk.path)\(Style.reset):\(r.chunk.startLine)-\(r.chunk.endLine)  (\(score))")
                    }
                }
                continue
            }
            if trimmed == "/show" {
                if let context = try await session.currentContext() {
                    print("\(Style.bold)messages:\(Style.reset) \(context.messages.count)")
                    for (i, m) in context.messages.enumerated() {
                        let color = m.role == "assistant" ? Style.cyan : (m.role == "user" ? Style.green : Style.dim)
                        print("  \(color)[\(i)] \(m.role):\(Style.reset) \((m.content ?? "").prefix(120))")
                    }
                }
                continue
            }
            // Inline /fix, /explain, /docs, /plugin
            if trimmed.hasPrefix("/fix ") {
                let path = String(trimmed.dropFirst("/fix ".count))
                let result = try await session.fix(path: path)
                print(result)
                continue
            }
            if trimmed.hasPrefix("/explain ") {
                let path = String(trimmed.dropFirst("/explain ".count))
                let answer = try await session.ask("Use the read_file tool to read \(path), then explain what each feature set does.")
                print(answer)
                continue
            }
            if trimmed.hasPrefix("/docs ") {
                let path = String(trimmed.dropFirst("/docs ".count))
                let answer = try await session.ask("Read all .aro files in \(path), then use generate_docs to create a README.md.")
                print(answer)
                continue
            }
            if trimmed.hasPrefix("/plugin ") {
                let name = String(trimmed.dropFirst("/plugin ".count))
                let answer = try await session.ask("Create a new ARO plugin named '\(name)' using create_plugin. Pick an appropriate language. Then explain how to use it.")
                print(answer)
                continue
            }
            if trimmed.hasPrefix("/openapi") {
                let desc = trimmed.hasPrefix("/openapi ") ? String(trimmed.dropFirst("/openapi ".count)) : ""
                let answer: String
                if desc.isEmpty {
                    answer = try await session.ask("Look at the .aro files in this directory and generate an openapi.yaml using write_openapi.")
                } else {
                    answer = try await session.ask("Generate an openapi.yaml for: \(desc). Use write_openapi.")
                }
                print(answer)
                continue
            }

            // Regular prompt
            do {
                let answer = try await session.ask(trimmed)
                print("\n\(answer)")
            } catch {
                TerminalUI.printError("\(error)")
            }
        }
    }

    // MARK: - Helpers

    private func sessionConfig(cwd: URL) -> AskSessionConfig {
        AskSessionConfig(
            workingDirectory: cwd,
            model: model,
            autoApproveAll: yes,
            temperature: temperature,
            skipMCP: noMcp
        )
    }

    private func ensureModel(manager: ModelManager) async throws {
        let capturedModel = model

        // First check for updates if already installed
        let status = await manager.checkForUpdate(capturedModel)
        switch status {
        case .updateAvailable(let local, let remote):
            TerminalUI.printStatus("Update available for \(capturedModel)")
            TerminalUI.printStatus("  local:  \(local.prefix(12))")
            TerminalUI.printStatus("  remote: \(remote.prefix(12))")
            let msg = "Download update? [y/N] "
            FileHandle.standardError.write(Data(msg.utf8))
            if let line = readLine(), line.lowercased().hasPrefix("y") {
                TerminalUI.printStatus("Updating \(capturedModel) (removing old files)...")
                _ = try await manager.update(
                    capturedModel,
                    progress: { TerminalUI.printDownloadProgress($0) }
                )
            }
        case .notInstalled:
            _ = try await manager.ensureInstalled(
                capturedModel,
                confirm: { sizeGb in
                    let sizeStr = sizeGb > 0 ? "~\(String(format: "%.1f", sizeGb)) GB" : "unknown size"
                    let msg = "\(Style.bold)Model '\(capturedModel)'\(Style.reset) (\(sizeStr)) is not installed.\nDownload from Hugging Face? [y/N] "
                    FileHandle.standardError.write(Data(msg.utf8))
                    guard let line = readLine() else { return false }
                    return line.lowercased().hasPrefix("y")
                },
                progress: { TerminalUI.printDownloadProgress($0) }
            )
        default:
            break
        }
    }
}
