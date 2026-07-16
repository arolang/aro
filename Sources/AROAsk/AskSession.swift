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
    /// File the user currently has open (editor focus). Its fresh content
    /// is injected into every request as a transient context block — never
    /// persisted to `.context`. Change at runtime via `setFocusFile(_:)`.
    public var focusFile: URL?
    /// Suppress TerminalUI output. Set by embedders (SOLARO) that render
    /// progress through the event sink instead of stdout/stderr.
    public var quiet: Bool

    public init(
        workingDirectory: URL,
        model: String = "ARO-Lang/aro-coder-4bit",
        autoApproveAll: Bool = false,
        maxToolCallRounds: Int = 25,
        temperature: Double = 0.2,
        skipMCP: Bool = false,
        focusFile: URL? = nil,
        quiet: Bool = false
    ) {
        self.workingDirectory = workingDirectory
        self.model = model
        self.autoApproveAll = autoApproveAll
        self.maxToolCallRounds = maxToolCallRounds
        self.temperature = temperature
        self.skipMCP = skipMCP
        self.focusFile = focusFile
        self.quiet = quiet
    }
}

/// Progress events emitted while `ask()` runs — status lines and tool
/// activity. Lets embedders (SOLARO's co-pilot) show what the model is
/// doing and react to file modifications without scraping stdout.
public enum AskEvent: Sendable {
    case status(String)
    case toolCallStarted(name: String, arguments: String)
    /// `modifiedPath` is the workspace-relative path a mutating tool
    /// (write_file, edit_file, write_openapi, generate_docs) touched,
    /// nil for read-only tools or failures.
    case toolCallFinished(name: String, output: String, failed: Bool, modifiedPath: String?)
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
    private var focusFile: URL?
    private var eventSink: (@Sendable (AskEvent) -> Void)?

    /// - Parameter approver: custom approval policy. Embedders (SOLARO)
    ///   pass one to route approvals through their own UI instead of the
    ///   terminal; nil falls back to `autoApproveAll` / interactive.
    public init(config: AskSessionConfig, approver: (any ToolApprover)? = nil) {
        self.config = config
        self.focusFile = config.focusFile
        self.contextStore = ContextStore(workingDirectory: config.workingDirectory)
        self.registry = ToolRegistry()
        let indexURL = config.workingDirectory
            .appendingPathComponent(".context.index")
            .appendingPathComponent("vectors.json")
        self.vectorStore = VectorStore(storeURL: indexURL)
        self.embedder = HashingEmbedder()
        self.pathGuard = PathGuard(root: config.workingDirectory)
        self.approver = approver
            ?? (config.autoApproveAll ? AutoApproveAll() : InteractiveApprover())
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

        // 2. Vector store, MCP bridges, and model resolution run
        // in parallel — they're independent and each is multi-
        // second cold-start work (#368). The user previously
        // waited for all three sequentially.
        async let vectorReady: Void = vectorStore.load()
        async let mcpReady: Void = (config.skipMCP ? () : startMCPBridges())
        async let resolvedEntry = modelManager.entry(for: config.model)
        async let resolvedDir = modelManager.modelDirectory(for: config.model)

        try await vectorReady
        await mcpReady
        let entry = try await resolvedEntry
        let dir = await resolvedDir
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
        if !hasAroMcp {
            servers.append(MCPServerConfig(command: AROBinary.resolve(), args: ["mcp"]))
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

    // MARK: - Embedder hooks (focus file + progress events)

    /// Point the session at the file the user currently has open. Its
    /// fresh content is injected into every subsequent request; pass nil
    /// to stop injecting.
    public func setFocusFile(_ url: URL?) {
        focusFile = url
    }

    /// Workspace-relative display path of the current focus file, or nil.
    public func focusFilePath() -> String? {
        focusFile.map { displayPath(for: $0) }
    }

    /// Receive status + tool-activity events while `ask()` runs. Used by
    /// SOLARO to show progress and reload files the model modified.
    public func setEventSink(_ sink: (@Sendable (AskEvent) -> Void)?) {
        eventSink = sink
    }

    private func emitStatus(_ message: String) {
        if !config.quiet { TerminalUI.printStatus(message) }
        eventSink?(.status(message))
    }

    private func emitToolCall(name: String, arguments: String) {
        if !config.quiet { TerminalUI.printToolCall(name: name, args: arguments) }
        eventSink?(.toolCallStarted(name: name, arguments: arguments))
    }

    private func emitToolResult(name: String, arguments: String, output: String, failed: Bool) {
        if !config.quiet { TerminalUI.printToolResult(name: name, output: output) }
        let modified = failed ? nil : Self.modifiedPath(tool: name, argumentsJSON: arguments)
        eventSink?(.toolCallFinished(name: name, output: output, failed: failed, modifiedPath: modified))
    }

    /// Tools that mutate the workspace, mapped to the argument key that
    /// carries the destination path. Lets event consumers know which file
    /// to reload without parsing tool output strings.
    private static let mutatingToolPathKeys: [String: [String]] = [
        "write_file": ["path"],
        "edit_file": ["path"],
        "write_openapi": ["output_path"],
        "generate_docs": ["output"],
    ]

    static func modifiedPath(tool: String, argumentsJSON: String) -> String? {
        guard let keys = mutatingToolPathKeys[tool] else { return nil }
        guard let data = argumentsJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        for key in keys {
            if let value = obj[key] as? String, !value.isEmpty { return value }
        }
        // write_openapi defaults to openapi.yaml when output_path is omitted
        return tool == "write_openapi" ? "openapi.yaml" : nil
    }

    /// Path shown to the model / user: workspace-relative when inside the
    /// working directory, absolute otherwise.
    private func displayPath(for url: URL) -> String {
        let root = config.workingDirectory.standardizedFileURL.path
        let abs = url.standardizedFileURL.path
        if abs.hasPrefix(root + "/") {
            return String(abs.dropFirst(root.count + 1))
        }
        return abs
    }

    /// Cap for the injected focus-file block (~1.5k tokens of the 8k
    /// window) so a huge open file can't crowd out the conversation.
    private static let focusFileMaxChars = 6000

    /// Transient "OPEN FILE" context block: re-read on every request so
    /// the model always sees the file as it is on disk right now. Never
    /// persisted to `.context` — persisting would snapshot stale content
    /// and double it on every turn.
    private func focusFileMessage() -> LMChatRequest.Message? {
        guard let url = focusFile,
              let content = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        let display = displayPath(for: url)
        var body = content
        var note = ""
        if body.count > Self.focusFileMaxChars {
            body = String(body.prefix(Self.focusFileMaxChars))
            note = "\n(file truncated here — use the read_file tool with an offset to see the rest)"
        }
        return LMChatRequest.Message(role: "system", content: """
        OPEN FILE: \(display)
        This is the file the user has open in the editor right now. It is \
        the default target: when the user says "this file", "this code", or \
        asks for a change without naming a file, they mean this one. Its \
        current content is below — you do not need read_file for it. Apply \
        modifications with edit_file or write_file using the path "\(display)".
        ```
        \(body)
        ```\(note)
        """)
    }

    /// Convert stored messages to request messages, inserting the
    /// transient focus-file block right after the system prompt.
    private func requestMessages(from messages: [AskMessage]) -> [LMChatRequest.Message] {
        var out = messages.map { $0.toRequestMessage() }
        if let focus = focusFileMessage() {
            out.insert(focus, at: out.isEmpty ? 0 : 1)
        }
        return out
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

        // Per-tool failure tracking + session-wide failure ceiling.
        // A flaky or broken tool would otherwise drive the model into
        // a tight retry storm — same call, same error, every round
        // — burning context and API quota. We stop dispatching a
        // single tool once it has failed `perToolFailureLimit` times
        // in a row, and surface a "tool persistently failing" message
        // to the model so it can pick a different approach (#369).
        var toolConsecutiveFailures: [String: Int] = [:]
        var totalToolFailures = 0
        let perToolFailureLimit = 3
        let sessionFailureLimit = 20

        for round in 0..<config.maxToolCallRounds {
            let request = LMChatRequest(
                model: config.model,
                messages: requestMessages(from: context.messages),
                tools: tools.isEmpty ? nil : tools,
                temperature: config.temperature,
                stream: false
            )
            var reply = try await backend.chat(request: request)

            // Verbose mode: dump the raw model output (including `<think>`)
            // to stderr so the user can see what the model was reasoning
            // about. Useful when the truncation warning fires and you want
            // to know what was actually going on.
            if Self.isVerbose, let raw = reply.content, !raw.isEmpty {
                FileHandle.standardError.write(Data(
                    "\n=== model raw output ===\n\(raw)\n=== end raw ===\n\n".utf8
                ))
            }

            // Strip thinking BEFORE persisting — anything saved to .context
            // is replayed verbatim on the next turn, so leaking raw `<think>`
            // (especially an unclosed one from a truncation) poisons future
            // conversations and the model goes off the rails. The MLX
            // backend also strips internally; this is the choke point for
            // non-MLX backends (llama-server, remote, OpenAI).
            var stripped = stripThinking(reply.content ?? "")

            // Auto-retry: when the model stalls in `<think>` with no body
            // (it emitted just the opening tag and nothing after), retry
            // once with /no_think prepended to bypass reasoning entirely.
            // The model usually produces a direct answer the second time.
            // Skip the retry if the user already asked for /no_think.
            if stripped.truncatedDuringThinking
                && Self.thinkingTail(reply.content ?? "") == nil
                && !prompt.hasPrefix("/no_think") {
                emitStatus("model stalled while thinking — retrying with /no_think…")
                var retryMessages = context.messages
                if let lastUser = retryMessages.lastIndex(where: { $0.role == "user" }) {
                    let orig = retryMessages[lastUser].content ?? ""
                    if !orig.hasPrefix("/no_think") {
                        retryMessages[lastUser] = AskMessage(
                            role: "user",
                            content: "/no_think " + orig
                        )
                    }
                }
                let retryRequest = LMChatRequest(
                    model: config.model,
                    messages: requestMessages(from: retryMessages),
                    tools: tools.isEmpty ? nil : tools,
                    temperature: config.temperature,
                    stream: false
                )
                let retryReply = try await backend.chat(request: retryRequest)
                if Self.isVerbose, let raw = retryReply.content, !raw.isEmpty {
                    FileHandle.standardError.write(Data(
                        "\n=== model raw output (retry) ===\n\(raw)\n=== end raw ===\n\n".utf8
                    ))
                }
                let retryStripped = stripThinking(retryReply.content ?? "")
                if !retryStripped.text.isEmpty || !(retryReply.toolCalls ?? []).isEmpty {
                    reply = retryReply
                    stripped = retryStripped
                }
            }

            // Second-stage retry: when the /no_think pass above still
            // returns empty content (the dominant round-2 failure: model
            // emits `<think></think>` then EOS), re-issue the request
            // with a "/no_think Output only ARO code, no commentary."
            // prefix. The combination bypasses both the thinking pathway
            // and the empty-collapse: in the 100-prompt eval this nudge
            // alone lifts reply rate from 15% to 59%. Skip if the prompt
            // already carries the directive.
            let directivePrefix = "Output only ARO code, no commentary. "
            if stripped.text.isEmpty
                && (reply.toolCalls ?? []).isEmpty
                && !prompt.contains(directivePrefix) {
                emitStatus("model returned no content — retrying with code-only directive…")
                var directiveMessages = context.messages
                if let lastUser = directiveMessages.lastIndex(where: { $0.role == "user" }) {
                    let orig = directiveMessages[lastUser].content ?? ""
                    let base = orig.hasPrefix("/no_think ")
                        ? String(orig.dropFirst("/no_think ".count))
                        : orig
                    directiveMessages[lastUser] = AskMessage(
                        role: "user",
                        content: "/no_think " + directivePrefix + base
                    )
                }
                let directiveRequest = LMChatRequest(
                    model: config.model,
                    messages: requestMessages(from: directiveMessages),
                    tools: tools.isEmpty ? nil : tools,
                    temperature: config.temperature,
                    stream: false
                )
                let directiveReply = try await backend.chat(request: directiveRequest)
                if Self.isVerbose, let raw = directiveReply.content, !raw.isEmpty {
                    FileHandle.standardError.write(Data(
                        "\n=== model raw output (directive retry) ===\n\(raw)\n=== end raw ===\n\n".utf8
                    ))
                }
                let directiveStripped = stripThinking(directiveReply.content ?? "")
                if !directiveStripped.text.isEmpty
                    || !(directiveReply.toolCalls ?? []).isEmpty {
                    reply = directiveReply
                    stripped = directiveStripped
                }
            }

            if stripped.truncatedDuringThinking {
                // Retry didn't help (or wasn't run). Surface the tail of
                // the reasoning block as a best-effort explanation —
                // partial reasoning is almost always more informative than
                // a bare "I ran out of tokens" warning.
                let fallback = Self.thinkingTail(reply.content ?? "")
                if let fallback, !fallback.isEmpty {
                    emitStatus(
                        "model didn't finalise an answer — showing its reasoning instead. " +
                        "Use `aro ask --no-think \"<prompt>\"` for a direct reply."
                    )
                    stripped = StrippedReply(text: fallback, truncatedDuringThinking: false)
                } else {
                    emitStatus(
                        "model spent its token budget thinking and produced no answer — " +
                        "try `aro ask --no-think \"<prompt>\"` to skip the reasoning step, " +
                        "or `aro ask -v` to see what it was thinking about"
                    )
                }
            }

            // Persist assistant turn (stripped)
            let encodedToolCalls = try encodeToolCalls(reply.toolCalls)
            context.messages.append(AskMessage(
                role: "assistant",
                content: stripped.text.isEmpty ? nil : stripped.text,
                toolCalls: encodedToolCalls
            ))
            try contextStore.save(context)

            // If no tool calls, we have a final text reply — validate any ARO code
            guard let toolCalls = reply.toolCalls, !toolCalls.isEmpty else {
                let finalText = stripped.text
                let validated = try await selfRepairIfNeeded(
                    text: finalText,
                    originalUserRequest: prompt,
                    context: &context,
                    tools: tools
                )
                // Make sure the cursor and ANSI state are clean before
                // returning to the user. The model's stream can leave the
                // terminal in a dimmed/hidden-cursor state.
                if !config.quiet { TerminalUI.resetTerminal() }
                return validated
            }

            // Execute each tool call
            for call in toolCalls {
                let name = call.function.name
                emitToolCall(name: name, arguments: call.function.arguments)

                // Short-circuit if this specific tool keeps failing
                // — feed the model a clear "stop trying me" message
                // instead of dispatching again. The model usually
                // pivots to an alternative approach (#369).
                if let consec = toolConsecutiveFailures[name],
                   consec >= perToolFailureLimit {
                    let msg = "Tool '\(name)' is persistently failing (skipped after \(consec) consecutive failures). Try a different approach."
                    emitToolResult(name: name, arguments: call.function.arguments, output: msg, failed: true)
                    context.messages.append(AskMessage(
                        role: "tool",
                        content: msg,
                        toolCallId: call.id
                    ))
                    try contextStore.save(context)
                    continue
                }

                let output: String
                var failed = false
                do {
                    // Exponential backoff before retrying a tool that
                    // has already failed this session. 0 → 200ms →
                    // 400ms → 800ms keeps the loop responsive on
                    // first failure but bounds the retry storm.
                    if let consec = toolConsecutiveFailures[name], consec > 0 {
                        let delayMs = min(2000, 200 * (1 << min(consec - 1, 4)))
                        try? await Task.sleep(for: .milliseconds(delayMs))
                    }
                    output = try await registry.dispatch(
                        name: name,
                        argumentsJSON: call.function.arguments,
                        approver: approver
                    )
                } catch let e as AskToolError where e.description.contains("User denied") {
                    output = "Tool call denied by user."
                } catch {
                    output = "error: \(error)"
                    failed = true
                }

                if failed {
                    toolConsecutiveFailures[name, default: 0] += 1
                    totalToolFailures += 1
                } else {
                    toolConsecutiveFailures[name] = 0
                }

                emitToolResult(name: name, arguments: call.function.arguments, output: output, failed: failed)

                context.messages.append(AskMessage(
                    role: "tool",
                    content: output,
                    toolCallId: call.id
                ))
                try contextStore.save(context)

                if totalToolFailures >= sessionFailureLimit {
                    let msg = "Aborting session: \(sessionFailureLimit) tool failures across this conversation. Re-issue your request after fixing the failing tools."
                    emitStatus(msg)
                    return msg
                }
            }

            if round == config.maxToolCallRounds - 1 {
                return "[aro ask] stopped after \(config.maxToolCallRounds) tool-call rounds"
            }
        }
        return ""
    }

    /// True when `ARO_ASK_VERBOSE` is set (by `-v`/`--verbose` or directly
    /// in the environment). Gates `=== model raw output ===` dumps so the
    /// user can see what the model was thinking about.
    static var isVerbose: Bool {
        ProcessInfo.processInfo.environment["ARO_ASK_VERBOSE"] != nil
    }

    /// Pull the contents of a `<think>...</think>` block (or the trailing
    /// open-but-unclosed `<think>` block from a truncated generation) out
    /// of a raw model reply. Used as a fallback "explanation" when the
    /// model spent its whole budget reasoning and never produced a clean
    /// answer — surfacing the reasoning is almost always more useful than
    /// a bare "I ran out of tokens" warning.
    ///
    /// Returns the last ~600 chars (prefixed with `…` if truncated) so the
    /// user gets the most recent line of reasoning rather than the opening
    /// preamble. Returns nil if there's no `<think>` content to show.
    static func thinkingTail(_ raw: String, maxChars: Int = 600) -> String? {
        guard let openRange = raw.range(of: "<think>") else { return nil }
        let after = raw[openRange.upperBound...]
        let endIndex = after.range(of: "</think>")?.lowerBound ?? after.endIndex
        let body = String(after[..<endIndex])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        if body.count > maxChars {
            let tail = body.suffix(maxChars)
            return "…" + String(tail)
        }
        return body
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
            let aroBin = AROBinary.resolve()
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
            emitStatus(
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
            // Empty code can vacuously "pass" aro check — guard against
            // claiming success when the model produced nothing.
            guard !aroCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                emitStatus("repair loop saw no ARO code to validate — returning prior text")
                break
            }
            let (ok, error) = runAroCheck(aroCode)

            if ok {
                emitStatus("aro check passed (after \(attempt - 1) repair\(attempt == 2 ? "" : "s"))")
                break
            }

            emitStatus("aro check failed (attempt \(attempt)/\(totalAttempts)): \(error.prefix(160))")
            // Show the model's actual proposed code so the user can see
            // what's being retried — previously this was silent and the
            // user had no insight into why repair was failing.
            if !aroCode.isEmpty {
                emitStatus("proposed fix:\n\(previewCode(aroCode))")
            }

            if Date() >= deadline {
                emitStatus(
                    "repair budget of \(Int(Self.repairWallClockBudget))s exceeded — returning last output"
                )
                break
            }

            if attempt == totalAttempts {
                emitStatus("giving up after \(totalAttempts) repair attempts — returning last output")
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
                messages: requestMessages(from: context.messages),
                tools: tools.isEmpty ? nil : tools,
                temperature: temp,
                stream: false
            )
            let reply = try await backend.chat(request: request)
            let repairStripped = stripThinking(reply.content ?? "").text
            // Never overwrite currentText with empty content — if the
            // repair model goes into think-stall (`<think></think>` and
            // EOS), we still want to surface the prior best attempt
            // instead of returning an empty string to the user.
            if !repairStripped.isEmpty {
                currentText = repairStripped
            } else {
                emitStatus("repair attempt \(attempt) produced empty content — keeping prior text")
            }

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

        emitStatus("Context compacted: \(toSummarize.count) messages → summary")

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
        let aroBin = AROBinary.resolve()
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
        emitStatus("aro check found errors:\n\(String(error.prefix(300)))")

        // Step 2: Build the fix prompt with full source + error
        var sourceBlock = ""
        for (name, content) in aroFiles.sorted(by: { $0.key < $1.key }) {
            sourceBlock += "## \(name)\n```aro\n\(content)\n```\n\n"
        }

        let maxAttempts = 5
        var currentSource = sourceBlock
        var lastError = String(error.prefix(500))

        for attempt in 1...maxAttempts {
            emitStatus("Fix attempt \(attempt)/\(maxAttempts)...")

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
                emitStatus("  No ```aro``` blocks in response — retrying")
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
                emitStatus("aro check passed after \(attempt) attempt(s)")
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

            emitStatus("  Still has errors: \(String(lastError.prefix(100)))")
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
