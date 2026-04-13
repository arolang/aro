// ============================================================
// AskSession.swift
// AROAsk - the REPL/one-shot driver: backend + tools + context
// ============================================================

import Foundation

/// Configuration for a single `aro ask` invocation.
public struct AskSessionConfig: Sendable {
    public var workingDirectory: URL
    public var model: String
    public var autoApproveAll: Bool
    public var maxToolCallRounds: Int
    public var temperature: Double
    public var skipMCP: Bool

    public init(
        workingDirectory: URL,
        model: String = "ARO-Lang/aro-coder-4bit",
        autoApproveAll: Bool = false,
        maxToolCallRounds: Int = 25,
        temperature: Double = 0.2,
        skipMCP: Bool = false
    ) {
        self.workingDirectory = workingDirectory
        self.model = model
        self.autoApproveAll = autoApproveAll
        self.maxToolCallRounds = maxToolCallRounds
        self.temperature = temperature
        self.skipMCP = skipMCP
    }
}

/// Coordinates a single `aro ask` session: backend, tool registry, context
/// store, MCP bridges and the tool-call loop.
public actor AskSession {
    public let config: AskSessionConfig
    public let contextStore: ContextStore
    public let registry: ToolRegistry
    public let vectorStore: VectorStore
    public let embedder: any Embedder
    public let pathGuard: PathGuard
    public let approver: ToolApprover

    private var backend: (any LMBackend)?
    private var mcpBridges: [MCPClientBridge] = []

    public init(config: AskSessionConfig) {
        self.config = config
        self.contextStore = ContextStore(workingDirectory: config.workingDirectory)
        self.registry = ToolRegistry()
        let indexURL = config.workingDirectory
            .appendingPathComponent(".context.index")
            .appendingPathComponent("vectors.json")
        self.vectorStore = VectorStore(storeURL: indexURL)
        self.embedder = HashingEmbedder()
        self.pathGuard = PathGuard(root: config.workingDirectory)
        self.approver = config.autoApproveAll ? AutoApproveAll() : InteractiveApprover()
    }

    // MARK: - Lifecycle

    /// Prepare the session: register tools, load vector store, start MCP, select backend.
    public func prepare(modelManager: ModelManager) async throws {
        // 1. Built-in tools
        await registry.register(FileTools.all(guard: pathGuard))
        await registry.register(ShellTool.tool(guard: pathGuard))
        await registry.register(AROTools.all(guard: pathGuard))
        await registry.register(ProposalTools.all(cwd: config.workingDirectory))
        await registry.register(ProjectTools.all(guard: pathGuard))
        await registry.register(SearchTool.searchProject(store: vectorStore, embedder: embedder))

        // 2. Vector store
        try await vectorStore.load()

        // 3. MCP bridges
        if !config.skipMCP {
            await startMCPBridges()
        }

        // 4. Backend
        let entry = try await modelManager.entry(for: config.model)
        let dir = await modelManager.modelDirectory(for: config.model)
        let modelFile = dir.appendingPathComponent(entry.primaryFile)
        let selected = try await BackendFactory.detect(
            modelIdentifier: config.model,
            modelPath: modelFile
        )
        try await selected.start()
        self.backend = selected
    }

    /// Register tools + MCP but skip backend startup (for slash commands).
    public func prepareRegistryOnly() async throws {
        await registry.register(FileTools.all(guard: pathGuard))
        await registry.register(ShellTool.tool(guard: pathGuard))
        await registry.register(AROTools.all(guard: pathGuard))
        await registry.register(ProposalTools.all(cwd: config.workingDirectory))
        await registry.register(ProjectTools.all(guard: pathGuard))
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
                FileHandle.standardError.write(Data("warning: MCP bridge '\(server.command)' failed: \(error)\n".utf8))
            }
        }
    }

    public func shutdown() async {
        if let b = backend { await b.stop() }
        for bridge in mcpBridges { await bridge.stop() }
    }

    // MARK: - Chat loop (post-inference tool-calling middleware)

    /// Send a user prompt, run the tool-call loop, and return the final
    /// assistant text. The `.context` file is updated as messages are appended.
    public func ask(_ prompt: String) async throws -> String {
        guard let backend = backend else { throw LMBackendError.notStarted }

        var context = try contextStore.loadOrCreate(model: config.model)
        context.messages.append(AskMessage(role: "user", content: prompt))
        try contextStore.save(context)

        let tools = await registry.definitions()

        for round in 0..<config.maxToolCallRounds {
            let request = LMChatRequest(
                model: config.model,
                messages: context.messages.map { $0.toRequestMessage() },
                tools: tools.isEmpty ? nil : tools,
                temperature: config.temperature,
                stream: false
            )
            let reply = try await backend.chat(request: request)

            // Persist assistant turn
            let encodedToolCalls = try encodeToolCalls(reply.toolCalls)
            context.messages.append(AskMessage(
                role: "assistant",
                content: reply.content,
                toolCalls: encodedToolCalls
            ))
            try contextStore.save(context)

            // If no tool calls, we're done
            guard let toolCalls = reply.toolCalls, !toolCalls.isEmpty else {
                return reply.content ?? ""
            }

            // Execute each tool call
            for call in toolCalls {
                TerminalUI.printToolCall(name: call.function.name, args: call.function.arguments)

                let output: String
                do {
                    output = try await registry.dispatch(
                        name: call.function.name,
                        argumentsJSON: call.function.arguments,
                        approver: approver
                    )
                } catch let e as AskToolError where e.description.contains("User denied") {
                    output = "Tool call denied by user."
                } catch {
                    output = "error: \(error)"
                }

                TerminalUI.printToolResult(name: call.function.name, output: output)

                context.messages.append(AskMessage(
                    role: "tool",
                    content: output,
                    toolCallId: call.id
                ))
                try contextStore.save(context)
            }

            if round == config.maxToolCallRounds - 1 {
                return "[aro ask] stopped after \(config.maxToolCallRounds) tool-call rounds"
            }
        }
        return ""
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

    public func currentContext() throws -> AskContext? {
        try contextStore.load()
    }

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

// MARK: - Message conversion

extension AskMessage {
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
