// ============================================================
// LMCommand.swift
// AROLM - `aro lm` ArgumentParser entry point
// ============================================================

import ArgumentParser
import Foundation
import LineNoise

public struct LMCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "lm",
        abstract: "Run prompts against a local LLM for ARO coding assistance",
        discussion: """
            `aro lm` starts an interactive coding assistant backed by a local
            language model (default: ARO-Lang/aro-coder-4bit).

            Examples:
              aro lm "write a feature set that greets a user"   # one-shot
              aro lm                                              # interactive REPL
              aro lm /clean                                       # delete .context in cwd
              aro lm /show                                        # print the current context
              aro lm /tools                                       # list available tools
              aro lm /model                                       # print backend + model
              aro lm /mcp                                         # list bridged MCP servers
              aro lm /index                                       # (re)build the project index
              aro lm /search "openapi contract"                  # search the indexed project

            Backend selection is automatic:
              1. $ARO_LM_ENDPOINT (OpenAI-compatible URL)
              2. llama-server on PATH (GGUF via llama.cpp)
              3. mlx_lm.server on PATH (Apple Silicon)

            The conversation is persisted to .context (YAML) in the current
            working directory.
            """
    )

    public init() {}

    @Argument(parsing: .remaining, help: "Prompt or slash command. Omit to enter the REPL.")
    public var prompt: [String] = []

    @Option(name: .long, help: "Model identifier (default: ARO-Lang/aro-coder-4bit)")
    public var model: String = "ARO-Lang/aro-coder-4bit"

    @Flag(name: .long, help: "Approve every shell tool call without prompting")
    public var yes: Bool = false

    @Flag(name: .long, help: "Do not connect to any MCP servers")
    public var noMCP: Bool = false

    @Option(name: .long, help: "Sampling temperature (default 0.2)")
    public var temperature: Double = 0.2

    public func run() async throws {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

        // Slash commands that don't need a live backend run in a lightweight
        // "offline" session. `/clean`, `/show`, `/tools`, `/model`, `/index`,
        // `/search` all fall in this category.
        let firstWord = prompt.first ?? ""
        if firstWord.hasPrefix("/") {
            try await runSlashCommand(cwd: cwd)
            return
        }

        // Interactive REPL if no prompt was provided.
        if prompt.isEmpty {
            try await runREPL(cwd: cwd)
            return
        }

        // One-shot.
        let session = LMSession(config: sessionConfig(cwd: cwd))
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
        case "/clean":
            let store = ContextStore(workingDirectory: cwd)
            if try store.clear() {
                print("deleted .context")
            } else {
                print("no .context to delete")
            }

        case "/show":
            let store = ContextStore(workingDirectory: cwd)
            guard let context = try store.load() else {
                print("no .context in \(cwd.path)")
                return
            }
            print("model: \(context.model)")
            print("messages: \(context.messages.count)")
            for (i, m) in context.messages.enumerated() {
                let preview = (m.content ?? "").prefix(200)
                print("[\(i)] \(m.role): \(preview)")
            }

        case "/tools":
            // Register tools with a dummy session so MCP + built-ins show up.
            let session = LMSession(config: sessionConfig(cwd: cwd))
            let manager = try ModelManager()
            // Don't start a backend — we only need the registry populated.
            _ = manager
            try await session.prepareRegistryOnly()
            for name in await session.toolNames() {
                print(name)
            }
            await session.shutdown()

        case "/model":
            let manager = try ModelManager()
            let entry = try await manager.entry(for: model)
            let dir = await manager.modelDirectory(for: model)
            print("model: \(model)")
            print("path: \(dir.path)")
            print("primary file: \(entry.primaryFile)")
            print("context length: \(entry.contextLength ?? 0)")
            print("backend hint: \(entry.backend)")

        case "/mcp":
            let session = LMSession(config: sessionConfig(cwd: cwd))
            let manager = try ModelManager()
            _ = manager
            try await session.prepareRegistryOnly()
            let labels = await session.mcpServerLabels()
            if labels.isEmpty {
                print("no MCP servers bridged")
            } else {
                for l in labels { print(l) }
            }
            await session.shutdown()

        case "/index":
            let session = LMSession(config: sessionConfig(cwd: cwd))
            let manager = try ModelManager()
            _ = manager
            try await session.prepareRegistryOnly()
            let count = try await session.rebuildIndex()
            print("indexed \(count) chunks")
            await session.shutdown()

        case "/search":
            let query = args.joined(separator: " ")
            guard !query.isEmpty else {
                print("usage: aro lm /search <query>")
                return
            }
            let session = LMSession(config: sessionConfig(cwd: cwd))
            let manager = try ModelManager()
            _ = manager
            try await session.prepareRegistryOnly()
            let results = try await session.search(query: query, k: 5)
            if results.isEmpty {
                print("no results — run `aro lm /index` first")
            } else {
                for r in results {
                    print("\(r.chunk.path):\(r.chunk.startLine)-\(r.chunk.endLine)  (\(String(format: "%.3f", r.score)))")
                }
            }
            await session.shutdown()

        case "/quit":
            return

        default:
            print("unknown slash command: \(cmd)")
            throw ExitCode.failure
        }
    }

    // MARK: - REPL

    private func runREPL(cwd: URL) async throws {
        let session = LMSession(config: sessionConfig(cwd: cwd))
        let manager = try ModelManager()
        try await ensureModel(manager: manager)
        try await session.prepare(modelManager: manager)
        defer { Task { await session.shutdown() } }

        let isTTY = isatty(fileno(stdin)) != 0
        let ln: LineNoise? = isTTY ? LineNoise() : nil

        let info = await session.backendInfo()
        print("aro lm — backend: \(info.name), model: \(info.model)")
        print("type /quit to exit, /help for commands")

        while true {
            let line: String?
            if let ln = ln {
                do {
                    let raw = try ln.getLine(prompt: "lm> ")
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
                print("lm> ", terminator: "")
                fflush(nil)
                line = readLine()
            }

            guard let text = line else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if trimmed == "/quit" || trimmed == "/exit" { return }
            if trimmed == "/help" {
                print("/clean /show /tools /model /mcp /index /search /quit")
                continue
            }
            if trimmed == "/clean" {
                _ = try await session.clear()
                print("deleted .context")
                continue
            }
            if trimmed == "/tools" {
                for name in await session.toolNames() { print(name) }
                continue
            }
            if trimmed == "/model" {
                let info = await session.backendInfo()
                print("backend: \(info.name), model: \(info.model)")
                continue
            }
            if trimmed == "/mcp" {
                let labels = await session.mcpServerLabels()
                print(labels.isEmpty ? "no MCP servers" : labels.joined(separator: "\n"))
                continue
            }
            if trimmed == "/index" {
                let count = try await session.rebuildIndex()
                print("indexed \(count) chunks")
                continue
            }
            if trimmed.hasPrefix("/search ") {
                let query = String(trimmed.dropFirst("/search ".count))
                let results = try await session.search(query: query, k: 5)
                if results.isEmpty {
                    print("no results")
                } else {
                    for r in results {
                        print("\(r.chunk.path):\(r.chunk.startLine)-\(r.chunk.endLine)  (\(String(format: "%.3f", r.score)))")
                    }
                }
                continue
            }
            if trimmed == "/show" {
                if let context = try await session.currentContext() {
                    print("messages: \(context.messages.count)")
                }
                continue
            }

            do {
                let answer = try await session.ask(trimmed)
                print(answer)
            } catch {
                print("error: \(error)")
            }
        }
    }

    // MARK: - Helpers

    private func sessionConfig(cwd: URL) -> LMSessionConfig {
        LMSessionConfig(
            workingDirectory: cwd,
            model: model,
            autoApproveShell: yes,
            temperature: temperature,
            skipMCP: noMCP
        )
    }

    private func ensureModel(manager: ModelManager) async throws {
        let capturedModel = model
        _ = try await manager.ensureInstalled(
            capturedModel,
            confirm: { sizeGb in
                let msg = "Model '\(capturedModel)' (~\(String(format: "%.1f", sizeGb)) GB) is not installed. Download from Hugging Face? [y/N] "
                FileHandle.standardError.write(Data(msg.utf8))
                guard let line = readLine() else { return false }
                return line.lowercased().hasPrefix("y")
            },
            progress: { file, received, total in
                if let total = total, total > 0 {
                    let pct = Int(Double(received) / Double(total) * 100)
                    let msg = "\r\(file): \(pct)%"
                    FileHandle.standardError.write(Data(msg.utf8))
                }
            }
        )
        FileHandle.standardError.write(Data("\n".utf8))
    }
}

