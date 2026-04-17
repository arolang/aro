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
    private var contextLength: Int = 8192

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
        self.contextLength = entry.contextLength ?? 8192
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

        // Auto-compact: summarize old turns when context grows too large
        try await compactIfNeeded(&context)

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

            // If no tool calls, we have a final text reply — validate any ARO code
            guard let toolCalls = reply.toolCalls, !toolCalls.isEmpty else {
                let finalText = reply.content ?? ""
                let validated = try await selfRepairIfNeeded(
                    text: finalText,
                    context: &context,
                    tools: tools
                )
                return validated
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

    // MARK: - Post-inference self-repair

    /// Maximum number of aro-check → fix cycles before giving up.
    private static let maxRepairAttempts = 3

    /// Extract ```aro code blocks from text.
    private func extractAroBlocks(_ text: String) -> [String] {
        let pattern = #"```aro\n([\s\S]*?)```"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let r = Range(match.range(at: 1), in: text) else { return nil }
            let block = String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
            return block.isEmpty ? nil : block
        }
    }

    /// Run `aro check` on code. Returns (passed, errorMessage).
    private func runAroCheck(_ code: String) -> (Bool, String) {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            try code.write(to: tmp.appendingPathComponent("main.aro"), atomically: true, encoding: .utf8)
            let aroBin = ProcessRunner.which("aro") ?? CommandLine.arguments.first ?? "aro"
            let result = try ProcessRunner.runAndCapture(
                executable: aroBin,
                arguments: ["check", tmp.path],
                timeout: 10
            )
            try? fm.removeItem(at: tmp)
            if result.exitCode == 0 {
                return (true, "")
            }
            let error = (result.stderr.isEmpty ? result.stdout : result.stderr)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (false, String(error.prefix(500)))
        } catch {
            try? fm.removeItem(at: tmp)
            return (false, "aro check failed: \(error)")
        }
    }

    /// If the model's reply contains ```aro blocks, validate them with aro check.
    /// On failure, feed the error back and ask the model to fix it, up to
    /// `maxRepairAttempts` times. The repair loop is printed to console but
    /// collapsed to a single assistant message in the saved context.
    private func selfRepairIfNeeded(
        text: String,
        context: inout AskContext,
        tools: [LMToolDefinition]
    ) async throws -> String {
        guard let backend = backend else { return text }

        let blocks = extractAroBlocks(text)
        guard !blocks.isEmpty else { return text }  // no ARO code to validate

        let combined = blocks.joined(separator: "\n\n")
        let (passed, _) = runAroCheck(combined)
        if passed { return text }  // already valid

        // Track how many messages we had before the repair loop started
        let preRepairCount = context.messages.count

        var currentText = text
        for attempt in 1...Self.maxRepairAttempts {
            let aroCode = extractAroBlocks(currentText).joined(separator: "\n\n")
            let (ok, error) = runAroCheck(aroCode)

            if ok {
                TerminalUI.printStatus("aro check passed (after \(attempt - 1) repair\(attempt == 2 ? "" : "s"))")
                break
            }

            TerminalUI.printStatus("aro check failed (attempt \(attempt)/\(Self.maxRepairAttempts)): \(error.prefix(120))")

            if attempt == Self.maxRepairAttempts {
                TerminalUI.printStatus("giving up after \(Self.maxRepairAttempts) repair attempts — returning last output")
                break
            }

            // Feed error back to model
            let repairPrompt = """
            `aro check` found errors in the ARO code you produced:

            ```
            \(error)
            ```

            Fix the errors and output the corrected code.
            """

            context.messages.append(AskMessage(role: "user", content: repairPrompt))
            try contextStore.save(context)

            let request = LMChatRequest(
                model: config.model,
                messages: context.messages.map { $0.toRequestMessage() },
                tools: tools.isEmpty ? nil : tools,
                temperature: config.temperature,
                stream: false
            )
            let reply = try await backend.chat(request: request)
            currentText = reply.content ?? currentText

            let encodedToolCalls = try encodeToolCalls(reply.toolCalls)
            context.messages.append(AskMessage(
                role: "assistant",
                content: reply.content,
                toolCalls: encodedToolCalls
            ))
            try contextStore.save(context)
        }

        // Collapse repair loop: remove intermediate repair turns from context,
        // keep only the final (corrected) assistant message.
        let repairMessages = Array(context.messages[preRepairCount...])
        if repairMessages.count > 1, let lastAssistant = repairMessages.last(where: { $0.role == "assistant" }) {
            context.messages.removeSubrange(preRepairCount...)
            context.messages.append(lastAssistant)
            try contextStore.save(context)
        }

        return currentText
    }

    // MARK: - Auto context compaction

    /// Rough token estimate: ~4 characters per token, which is conservative
    /// enough to trigger compaction before the backend truncates.
    private func estimateTokens(_ messages: [AskMessage]) -> Int {
        messages.reduce(0) { total, msg in
            let chars = (msg.content?.count ?? 0)
                + (msg.toolCalls?.count ?? 0)
                + (msg.name?.count ?? 0)
                + 4  // role + framing overhead
            return total + (chars + 3) / 4
        }
    }

    /// When the conversation exceeds 70% of the context window, summarize
    /// older turns into a single message so the model stays sharp.
    /// Keeps: system prompt (index 0), summary, and the most recent turns.
    private func compactIfNeeded(_ context: inout AskContext) async throws {
        guard let backend = backend else { return }
        let tokens = estimateTokens(context.messages)
        let threshold = contextLength * 70 / 100
        guard tokens > threshold else { return }

        // Keep the system prompt and the last few messages (recent context).
        // Everything in between gets summarized.
        let keepRecent = min(6, context.messages.count - 1)
        let summarizeEnd = context.messages.count - keepRecent
        guard summarizeEnd > 1 else { return }  // nothing to summarize beyond system prompt

        let toSummarize = Array(context.messages[1..<summarizeEnd])
        let recentMessages = Array(context.messages[summarizeEnd...])

        // Build a one-shot summarization request
        var summaryText = ""
        for msg in toSummarize {
            let content = msg.content ?? "(tool call)"
            let prefix = msg.role == "user" ? "User" :
                         msg.role == "assistant" ? "Assistant" :
                         msg.role == "tool" ? "Tool[\(msg.name ?? "")]" : msg.role
            summaryText += "\(prefix): \(content.prefix(500))\n"
        }

        let summaryRequest = LMChatRequest(
            model: config.model,
            messages: [
                LMChatRequest.Message(role: "system", content:
                    "Summarize the following conversation concisely. Focus on: " +
                    "what the user asked for, what files were read or modified, " +
                    "what code was written, and any decisions made. " +
                    "Keep it under 200 words."),
                LMChatRequest.Message(role: "user", content: summaryText),
            ],
            tools: nil,
            temperature: 0.1,
            stream: false
        )

        let summaryReply = try await backend.chat(request: summaryRequest)
        let summary = summaryReply.content ?? "(summary unavailable)"

        TerminalUI.printStatus("Context compacted: \(toSummarize.count) messages → summary")

        // Rebuild messages: system + summary + recent
        context.messages = [context.messages[0]]  // system prompt
        context.messages.append(AskMessage(
            role: "assistant",
            content: "[Conversation summary] \(summary)"
        ))
        context.messages.append(contentsOf: recentMessages)

        try contextStore.save(context)
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
