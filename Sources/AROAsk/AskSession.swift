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
                let finalText = Self.stripThinking(reply.content ?? "")
                let validated = try await selfRepairIfNeeded(
                    text: finalText,
                    originalUserRequest: prompt,
                    context: &context,
                    tools: tools
                )
                // Make sure the cursor and ANSI state are clean before
                // returning to the user. The model's stream can leave the
                // terminal in a dimmed/hidden-cursor state.
                TerminalUI.resetTerminal()
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

    /// Wall-clock budget for the repair loop. Once exceeded the loop bails
    /// out with whatever the latest reply is, instead of burning ~60 s per
    /// attempt times five attempts (= 5 minutes wasted) on hopeless cases.
    private static let repairWallClockBudget: TimeInterval = 90

    /// Per-attempt temperature schedule. Same temperature reproduces the
    /// same wrong output, so the schedule widens monotonically. Capped at
    /// 1.5 in the loop body so a high `config.temperature` baseline doesn't
    /// run away.
    private static let repairTempOffsets: [Double] = [0.0, 0.3, 0.6, 0.9]

    /// Strip `<think>...</think>` blocks from model output. Some packaged
    /// models follow the thinking-tag protocol but emit empty `<think></think>`
    /// blocks, which previously leaked through to user output. Idempotent.
    static func stripThinking(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"<think>[\s\S]*?</think>"#,
            options: [.dotMatchesLineSeparators]
        ) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        let stripped = regex.stringByReplacingMatches(
            in: text, range: range, withTemplate: ""
        )
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

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

    /// True when the raw reply contains a ```aro fenced block whose body
    /// includes a feature-set header `(name: activity) {`. Q&A replies
    /// often include short illustrative snippets that are valid ARO syntax
    /// in context but not a runnable program; running `aro check` on those
    /// produces a misleading FAIL, so we gate the repair loop on this
    /// heuristic. Anchored on the ```aro\n fence so unfenced ARO-like
    /// prose never triggers the loop.
    private func containsCompleteProgram(in text: String) -> Bool {
        let pattern = #"```aro\n[\s\S]*?\(\s*[\w\- ]+\s*:\s*[^)]+\)\s*\{"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let r = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, range: r) != nil
    }

    /// Detect when the model has inlined a tool call as text inside an
    /// ```aro``` block (e.g. `read_file("foo.aro")`). This is not ARO
    /// syntax — it's a sign the model failed to use the tool-call protocol.
    /// Returning true tells the caller to skip aro check + emit a one-time
    /// hint instead of running the repair loop.
    private func looksLikeInlinedToolCall(_ block: String) -> Bool {
        let toolNames = [
            "read_file", "write_file", "edit_file", "list_dir", "grep",
            "search_project", "aro_check", "aro_run", "aro_build", "aro_test",
            "create_plugin", "generate_docs", "list_actions", "list_proposals",
            "read_proposal", "parse_aro", "run_shell", "write_openapi",
        ]
        let pattern = #"\b(\#(toolNames.joined(separator: "|")))\s*\("#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let r = NSRange(block.startIndex..., in: block)
        return regex.firstMatch(in: block, range: r) != nil
    }

    /// Render a short preview of a proposed fix for printing between
    /// repair attempts. Keeps the first 3 + last 2 lines, dimmed.
    private func previewCode(_ code: String) -> String {
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > 6 else {
            return lines.map { "  \($0)" }.joined(separator: "\n")
        }
        let head = lines.prefix(3).map { "  \($0)" }.joined(separator: "\n")
        let tail = lines.suffix(2).map { "  \($0)" }.joined(separator: "\n")
        return "\(head)\n  ... (\(lines.count - 5) more lines)\n\(tail)"
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

    /// If the model's reply contains a complete ARO program, validate it
    /// with aro check. On failure feed the error back and ask the model to
    /// fix it, up to `repairTempOffsets.count` times, varying temperature
    /// across attempts. The repair loop is printed to console (with a
    /// preview of each proposed fix) but collapsed to a single assistant
    /// message in the saved context.
    ///
    /// Skips entirely when:
    ///  - the reply has no ```aro``` blocks
    ///  - the only blocks are illustrative fragments (no feature-set header)
    ///  - the only blocks contain inlined tool-call syntax
    /// Times out after `repairWallClockBudget` seconds regardless of
    /// remaining attempts.
    private func selfRepairIfNeeded(
        text: String,
        originalUserRequest: String,
        context: inout AskContext,
        tools: [LMToolDefinition]
    ) async throws -> String {
        guard let backend = backend else { return text }

        // Anchor on the ```aro\n fence + feature-set header. Q&A snippets
        // without a feature-set wrapper never enter the repair loop —
        // running aro check on a fragment FAILs misleadingly and burns
        // retries on hopeless cases.
        guard containsCompleteProgram(in: text) else { return text }

        let blocks = extractAroBlocks(text)
        guard !blocks.isEmpty else { return text }

        // Skip + hint if the model inlined a tool name as ARO text.
        if blocks.contains(where: { looksLikeInlinedToolCall($0) }) {
            TerminalUI.printStatus(
                "ignored ```aro``` block containing inlined tool-call syntax — " +
                "use the JSON tool-call protocol, not function-call text in code blocks"
            )
            return text
        }

        let combined = blocks.joined(separator: "\n\n")
        let (passed, _) = runAroCheck(combined)
        if passed { return text }

        let preRepairCount = context.messages.count
        let totalAttempts = Self.repairTempOffsets.count
        let deadline = Date().addingTimeInterval(Self.repairWallClockBudget)

        var currentText = text
        for attempt in 1...totalAttempts {
            let aroCode = extractAroBlocks(currentText).joined(separator: "\n\n")
            let (ok, error) = runAroCheck(aroCode)

            if ok {
                TerminalUI.printStatus("aro check passed (after \(attempt - 1) repair\(attempt == 2 ? "" : "s"))")
                break
            }

            TerminalUI.printStatus("aro check failed (attempt \(attempt)/\(totalAttempts)): \(error.prefix(160))")
            // Show the model's actual proposed code so the user can see
            // what's being retried — previously this was silent and the
            // user had no insight into why repair was failing.
            if !aroCode.isEmpty {
                TerminalUI.printStatus("proposed fix:\n\(previewCode(aroCode))")
            }

            if Date() >= deadline {
                TerminalUI.printStatus(
                    "repair budget of \(Int(Self.repairWallClockBudget))s exceeded — returning last output"
                )
                break
            }

            if attempt == totalAttempts {
                TerminalUI.printStatus("giving up after \(totalAttempts) repair attempts — returning last output")
                break
            }

            let repairPrompt = """
            The user's original request was:

            \(originalUserRequest)

            `aro check` found errors in the ARO code you produced:

            ```
            \(error)
            ```

            Fix the syntax errors WITHOUT changing what the code does.
            Every action the user asked for must remain in the program —
            do not delete a Compute, Extract, Log, Emit or Return just to
            make `aro check` pass. If "add two numbers" was the request,
            the addition step must still be there. If the existing approach
            cannot be made syntactically valid while doing what the user
            asked, rewrite using a different action that achieves the same
            behaviour — but do not silently drop the behaviour itself.

            Output the corrected code as a complete ARO feature set wrapped
            in `(name: activity) { ... }` inside ```aro fences. Do not write
            tool-call syntax inside the code block.
            """

            context.messages.append(AskMessage(role: "user", content: repairPrompt))
            try contextStore.save(context)

            // Vary temperature across attempts. Same temperature reproduces
            // the same wrong output, which is what the original loop did.
            let temp = min(1.5, config.temperature + Self.repairTempOffsets[attempt - 1])

            let request = LMChatRequest(
                model: config.model,
                messages: context.messages.map { $0.toRequestMessage() },
                tools: tools.isEmpty ? nil : tools,
                temperature: temp,
                stream: false
            )
            let reply = try await backend.chat(request: request)
            currentText = Self.stripThinking(reply.content ?? currentText)

            let encodedToolCalls = try encodeToolCalls(reply.toolCalls)
            context.messages.append(AskMessage(
                role: "assistant",
                content: currentText,
                toolCalls: encodedToolCalls
            ))
            try contextStore.save(context)
        }

        // Save repair conversation to .context.repairs.jsonl for training data.
        // Each entry: the original broken output, the error, and the final fix.
        let repairMessages = Array(context.messages[preRepairCount...])
        if repairMessages.count > 1 {
            saveRepairLog(repairMessages)
        }

        // Collapse repair loop: remove intermediate repair turns from context,
        // keep only the final (corrected) assistant message.
        if repairMessages.count > 1, let lastAssistant = repairMessages.last(where: { $0.role == "assistant" }) {
            context.messages.removeSubrange(preRepairCount...)
            context.messages.append(lastAssistant)
            try contextStore.save(context)
        }

        return currentText
    }

    /// Append a repair conversation to `.context.repairs.jsonl` for training.
    /// Each line is a JSON object with the broken code, error, and fix — usable
    /// as debugging training pairs and DPO negatives.
    private func saveRepairLog(_ messages: [AskMessage]) {
        let logURL = config.workingDirectory.appendingPathComponent(".context.repairs.jsonl")
        let assistantMsgs = messages.filter { $0.role == "assistant" }
        let userMsgs = messages.filter { $0.role == "user" }
        guard let broken = assistantMsgs.first?.content,
              let fixed = assistantMsgs.last?.content,
              broken != fixed else { return }

        // Extract the aro check error from the first repair prompt
        let firstError = userMsgs.first?.content ?? ""

        let entry: [String: Any] = [
            "broken_output": broken,
            "error_prompt": firstError,
            "fixed_output": fixed,
            "attempts": assistantMsgs.count,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
        ]

        do {
            let data = try JSONSerialization.data(withJSONObject: entry)
            let line = String(decoding: data, as: UTF8.self) + "\n"
            if FileManager.default.fileExists(atPath: logURL.path) {
                let handle = try FileHandle(forWritingTo: logURL)
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                handle.closeFile()
            } else {
                try Data(line.utf8).write(to: logURL)
            }
        } catch {
            // Non-fatal — don't interrupt the user's session for a log write failure
        }
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

    // MARK: - Deterministic fix command

    /// Deterministic fix: runs aro check, reads source, asks the model to fix,
    /// validates the fix, and writes back. No tool calling — direct orchestration.
    /// Returns a human-readable summary of what was fixed.
    public func fix(path: String) async throws -> String {
        guard let backend = backend else { throw LMBackendError.notStarted }

        let fm = FileManager.default
        let url = URL(fileURLWithPath: path, relativeTo: config.workingDirectory)
        let resolvedPath = url.standardized.path

        // Determine if path is a file or directory
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: resolvedPath, isDirectory: &isDir) else {
            return "Error: \(resolvedPath) does not exist"
        }

        let appDir: URL
        var aroFiles: [String: String] = [:]  // relative path → content

        if isDir.boolValue {
            appDir = url.standardized
            // Read all .aro files in the directory
            if let enumerator = fm.enumerator(at: appDir, includingPropertiesForKeys: nil) {
                while let fileURL = enumerator.nextObject() as? URL {
                    if fileURL.pathExtension == "aro" {
                        let rel = fileURL.path.replacingOccurrences(of: appDir.path + "/", with: "")
                        aroFiles[rel] = try String(contentsOf: fileURL, encoding: .utf8)
                    }
                }
            }
        } else {
            appDir = url.standardized.deletingLastPathComponent()
            let rel = url.standardized.lastPathComponent
            aroFiles[rel] = try String(contentsOf: url.standardized, encoding: .utf8)
        }

        guard !aroFiles.isEmpty else {
            return "No .aro files found at \(resolvedPath)"
        }

        // Step 1: Run aro check
        let aroBin = ProcessRunner.which("aro") ?? CommandLine.arguments.first ?? "aro"
        let checkResult = try ProcessRunner.runAndCapture(
            executable: aroBin,
            arguments: ["check", appDir.path],
            timeout: 10
        )

        if checkResult.exitCode == 0 {
            return "aro check passed — no errors to fix"
        }

        let error = (checkResult.stderr.isEmpty ? checkResult.stdout : checkResult.stderr)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        TerminalUI.printStatus("aro check found errors:\n\(String(error.prefix(300)))")

        // Step 2: Build the fix prompt with full source + error
        var sourceBlock = ""
        for (name, content) in aroFiles.sorted(by: { $0.key < $1.key }) {
            sourceBlock += "## \(name)\n```aro\n\(content)\n```\n\n"
        }

        let maxAttempts = 5
        var currentSource = sourceBlock
        var lastError = String(error.prefix(500))

        for attempt in 1...maxAttempts {
            TerminalUI.printStatus("Fix attempt \(attempt)/\(maxAttempts)...")

            let fixPrompt = """
            The following ARO code has errors:

            \(currentSource)
            Error from `aro check`:
            ```
            \(lastError)
            ```

            Fix ALL errors. Output the corrected code for each file using:
            ## filename.aro
            ```aro
            <fixed code>
            ```

            Output ONLY the fixed code. No explanations.
            """

            let request = LMChatRequest(
                model: config.model,
                messages: [
                    LMChatRequest.Message(role: "system", content: AskContext.defaultSystemPrompt),
                    LMChatRequest.Message(role: "user", content: fixPrompt),
                ],
                tools: nil,
                temperature: max(0.1, 0.3 - Double(attempt) * 0.05),
                stream: false
            )

            let reply = try await backend.chat(request: request)
            let output = reply.content ?? ""

            // Parse fixed files from output
            let blocks = extractAroBlocks(output)
            guard !blocks.isEmpty else {
                TerminalUI.printStatus("  No ```aro``` blocks in response — retrying")
                continue
            }

            // Parse multi-file output (## filename.aro headers)
            var fixedFiles: [String: String] = [:]
            let filePattern = #"##\s+(\S+\.aro)\s*\n```aro\n([\s\S]*?)```"#
            if let regex = try? NSRegularExpression(pattern: filePattern) {
                let range = NSRange(output.startIndex..., in: output)
                for match in regex.matches(in: output, range: range) {
                    if let nameRange = Range(match.range(at: 1), in: output),
                       let codeRange = Range(match.range(at: 2), in: output) {
                        let name = String(output[nameRange])
                        let code = String(output[codeRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                        fixedFiles[name] = code
                    }
                }
            }

            // Fallback: if no headers, use first block as main.aro
            if fixedFiles.isEmpty {
                fixedFiles["main.aro"] = blocks[0]
            }

            // Step 3: Validate the fix with aro check
            let tmpDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tmpDir) }

            for (name, code) in fixedFiles {
                let dest = tmpDir.appendingPathComponent(name)
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try code.write(to: dest, atomically: true, encoding: .utf8)
            }
            // Copy non-.aro files (openapi.yaml, .store) from original
            if let enumerator = fm.enumerator(at: appDir, includingPropertiesForKeys: nil) {
                while let fileURL = enumerator.nextObject() as? URL {
                    if fileURL.pathExtension != "aro" && !fileURL.hasDirectoryPath {
                        let rel = fileURL.path.replacingOccurrences(of: appDir.path + "/", with: "")
                        let dest = tmpDir.appendingPathComponent(rel)
                        try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try? fm.copyItem(at: fileURL, to: dest)
                    }
                }
            }

            let verifyResult = try ProcessRunner.runAndCapture(
                executable: aroBin,
                arguments: ["check", tmpDir.path],
                timeout: 10
            )

            if verifyResult.exitCode == 0 {
                // Step 4: Write fixed files back
                for (name, code) in fixedFiles {
                    let dest = appDir.appendingPathComponent(name)
                    try code.write(to: dest, atomically: true, encoding: .utf8)
                }

                // Save the repair pair for training
                saveRepairLog([
                    AskMessage(role: "assistant", content: sourceBlock),
                    AskMessage(role: "user", content: "aro check error: \(lastError)"),
                    AskMessage(role: "assistant", content: output),
                ])

                let fixed = fixedFiles.keys.sorted().joined(separator: ", ")
                TerminalUI.printStatus("aro check passed after \(attempt) attempt(s)")
                return "Fixed \(fixed) in \(attempt) attempt(s)"
            }

            // Update error for next attempt
            lastError = (verifyResult.stderr.isEmpty ? verifyResult.stdout : verifyResult.stderr)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            lastError = String(lastError.prefix(500))

            // Update source for next attempt (show the fixed code that still fails)
            currentSource = ""
            for (name, code) in fixedFiles.sorted(by: { $0.key < $1.key }) {
                currentSource += "## \(name)\n```aro\n\(code)\n```\n\n"
            }

            TerminalUI.printStatus("  Still has errors: \(String(lastError.prefix(100)))")
        }

        return "Could not fix after \(maxAttempts) attempts. Last error:\n\(lastError)"
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
