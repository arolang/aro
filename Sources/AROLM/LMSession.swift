// ============================================================
// LMSession.swift
// AROLM - the REPL/one-shot driver that holds backend + tools + context
// ============================================================

import Foundation

/// Configuration for a single `aro lm` invocation.
public struct LMSessionConfig: Sendable {
    public var workingDirectory: URL
    public var model: String
    public var autoApproveShell: Bool
    public var maxToolCallRounds: Int
    public var temperature: Double
    public var skipMCP: Bool

    public init(
        workingDirectory: URL,
        model: String = "ARO-Lang/aro-coder-4bit",
        autoApproveShell: Bool = false,
        maxToolCallRounds: Int = 25,
        temperature: Double = 0.2,
        skipMCP: Bool = false
    ) {
        self.workingDirectory = workingDirectory
        self.model = model
        self.autoApproveShell = autoApproveShell
        self.maxToolCallRounds = maxToolCallRounds
        self.temperature = temperature
        self.skipMCP = skipMCP
    }
}

/// Coordinates a single `aro lm` session: backend, tool registry, context
/// store, MCP bridges and the tool-call loop.
public actor LMSession {
    public let config: LMSessionConfig
    public let contextStore: ContextStore
    public let registry: ToolRegistry
    public let vectorStore: VectorStore
    public let embedder: any Embedder
    public let pathGuard: PathGuard

    private var backend: (any LMBackend)?
    private var mcpBridges: [MCPClientBridge] = []

    public init(config: LMSessionConfig) {
        self.config = config
        self.contextStore = ContextStore(workingDirectory: config.workingDirectory)
        self.registry = ToolRegistry()
        let indexURL = config.workingDirectory
            .appendingPathComponent(".context.index")
            .appendingPathComponent("vectors.json")
        self.vectorStore = VectorStore(storeURL: indexURL)
        self.embedder = HashingEmbedder()
        self.pathGuard = PathGuard(root: config.workingDirectory)
    }

    // MARK: - Lifecycle

    /// Prepare the session: register built-in tools, load the vector store,
    /// start the MCP bridge(s), and select a backend.
    public func prepare(modelManager: ModelManager) async throws {
        // 1. Built-in tools.
        let approver: ShellApprover = config.autoApproveShell
            ? AutoApprove()
            : InteractiveShellApprover()
        await registry.register(FileTools.all(guard: pathGuard))
        await registry.register(ShellTool.tool(guard: pathGuard, approver: approver))
        await registry.register(AROTools.all(guard: pathGuard))
        await registry.register(ProposalTools.all(cwd: config.workingDirectory))
        await registry.register(SearchTool.searchProject(store: vectorStore, embedder: embedder))

        // 2. Vector store.
        try await vectorStore.load()

        // 3. MCP bridges — the built-in `aro mcp` server plus any declared in
        //    the persisted context.
        if !config.skipMCP {
            await startMCPBridges()
        }

        // 4. Backend.
        let entry = try await modelManager.entry(for: config.model)
        let dir = await modelManager.modelDirectory(for: config.model)
        let modelFile = dir.appendingPathComponent(entry.primaryFile)
        let selected = try BackendFactory.detect(
            modelIdentifier: config.model,
            modelPath: modelFile
        )
        try await selected.start()
        self.backend = selected
    }

    /// Register built-in tools + MCP bridges and load the vector store, but
    /// skip backend startup. Used by slash commands that don't need an LLM.
    public func prepareRegistryOnly() async throws {
        let approver: ShellApprover = config.autoApproveShell
            ? AutoApprove()
            : InteractiveShellApprover()
        await registry.register(FileTools.all(guard: pathGuard))
        await registry.register(ShellTool.tool(guard: pathGuard, approver: approver))
        await registry.register(AROTools.all(guard: pathGuard))
        await registry.register(ProposalTools.all(cwd: config.workingDirectory))
        await registry.register(SearchTool.searchProject(store: vectorStore, embedder: embedder))
        try await vectorStore.load()
        if !config.skipMCP {
            await startMCPBridges()
        }
    }

    private func startMCPBridges() async {
        var servers: [MCPServerConfig] = []
        if let existing = try? contextStore.load(), let configured = existing.mcpServers {
            servers = configured
        }
        // Always try the built-in aro mcp server unless already listed.
        let hasAroMcp = servers.contains { $0.command.hasSuffix("aro") && $0.args.contains("mcp") }
        if !hasAroMcp, let aroBin = ProcessRunner.which("aro") ?? CommandLine.arguments.first {
            servers.append(MCPServerConfig(command: aroBin, args: ["mcp"]))
        }
        for server in servers {
            let bridge = MCPClientBridge(command: server.command, args: server.args)
            do {
                try await bridge.start()
                let tools = try await bridge.listTools()
                await registry.register(tools)
                mcpBridges.append(bridge)
            } catch {
                // MCP is best-effort; log to stderr and continue.
                FileHandle.standardError.write(Data("warning: MCP bridge '\(server.command)' failed: \(error)\n".utf8))
            }
        }
    }

    public func shutdown() async {
        if let b = backend { await b.stop() }
        for bridge in mcpBridges { await bridge.stop() }
    }

    // MARK: - Chat loop

    /// Send a user prompt, run the tool-call loop, and return the final
    /// assistant text. The `.context` file is updated as messages are
    /// appended.
    public func ask(_ prompt: String) async throws -> String {
        guard let backend = backend else { throw LMBackendError.notStarted }

        var context = try contextStore.loadOrCreate(model: config.model)
        context.messages.append(LMMessage(role: "user", content: prompt))
        try contextStore.save(context)

        let tools = await registry.definitions()

        for _ in 0..<config.maxToolCallRounds {
            let request = LMChatRequest(
                model: config.model,
                messages: context.messages.map { $0.toRequestMessage() },
                tools: tools.isEmpty ? nil : tools,
                temperature: config.temperature,
                stream: false
            )
            let reply = try await backend.chat(request: request)

            // Persist the assistant turn (including any tool_calls).
            let encodedToolCalls = try encodeToolCalls(reply.toolCalls)
            context.messages.append(LMMessage(
                role: "assistant",
                content: reply.content,
                toolCalls: encodedToolCalls
            ))
            try contextStore.save(context)

            guard let toolCalls = reply.toolCalls, !toolCalls.isEmpty else {
                return reply.content ?? ""
            }

            for call in toolCalls {
                let output: String
                do {
                    output = try await registry.dispatch(
                        name: call.function.name,
                        argumentsJSON: call.function.arguments
                    )
                } catch {
                    output = "error: \(error)"
                }
                context.messages.append(LMMessage(
                    role: "tool",
                    content: output,
                    toolCallId: call.id
                ))
                try contextStore.save(context)
            }
        }
        return "[aro lm] stopped after \(config.maxToolCallRounds) tool-call rounds"
    }

    private func encodeToolCalls(_ calls: [LMToolCall]?) throws -> String? {
        guard let calls = calls, !calls.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: try encoder.encode(calls), as: UTF8.self)
    }

    // MARK: - Slash commands

    public func clear() throws -> Bool {
        try contextStore.clear()
    }

    public func toolNames() async -> [String] {
        await registry.list().map { $0.name }
    }

    public func backendInfo() -> (name: String, model: String) {
        (backend?.name ?? "none", config.model)
    }

    public func currentContext() throws -> LMContext? {
        try contextStore.load()
    }

    // MARK: - Retrieval

    public func rebuildIndex() async throws -> Int {
        let indexer = ProjectIndexer(root: config.workingDirectory, embedder: embedder)
        let chunks = try await indexer.buildIndex()
        await vectorStore.replaceAll(chunks)
        try await vectorStore.save()
        return chunks.count
    }

    public func search(query: String, k: Int) async throws -> [SearchResult] {
        let vec = try await embedder.embed(query)
        return await vectorStore.search(query: vec, k: k)
    }

    public func mcpServerLabels() async -> [String] {
        var labels: [String] = []
        for bridge in mcpBridges {
            labels.append(await bridge.label)
        }
        return labels
    }
}

// MARK: - Helpers

private extension LMMessage {
    func toRequestMessage() -> LMChatRequest.Message {
        var toolCallsValue: [LMToolCall]? = nil
        if let raw = toolCalls, let data = raw.data(using: .utf8) {
            toolCallsValue = try? JSONDecoder().decode([LMToolCall].self, from: data)
        }
        return LMChatRequest.Message(
            role: role,
            content: content,
            name: name,
            toolCallId: toolCallId,
            toolCalls: toolCallsValue
        )
    }
}

/// Prompts the user on stderr for each shell command the model wants to run.
public struct InteractiveShellApprover: ShellApprover {
    public init() {}
    public func approve(command: String) async -> Bool {
        FileHandle.standardError.write(Data(
            "\n[aro lm] approve shell command? [y/N]\n  \(command)\n> ".utf8
        ))
        guard let line = readLine() else { return false }
        return line.lowercased().hasPrefix("y")
    }
}
