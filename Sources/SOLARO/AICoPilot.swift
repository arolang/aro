// ============================================================
// AICoPilot.swift
// SOLARO — `aro ask` co-pilot panel (#233 §4)
// ============================================================
//
// Local-first co-pilot per ADR-006. Runs `aro ask` IN-PROCESS
// through a warm AskSession rooted at the project directory —
// the model loads once and stays resident, every prompt gets the
// full tool registry (read/write/edit files, grep, aro
// check/run/build/test, plugin scaffolding, ...), tool activity
// streams into the chat, and files the model modifies are pushed
// back into the open editor via `onFilesModified`.
//
// The currently open editor file rides along as the session's
// focus file, so "fix this" / "add an endpoint here" target the
// file the user is looking at without any path typing.
//
// A subprocess fallback (`aro ask --yes --no-think <prompt>`)
// remains for the case where the in-process backend cannot
// prepare in the app (e.g. missing Metal shader library) but the
// CLI works.
//
// No auto-download of models, no auto-configuration of remote
// endpoints. The panel shows a first-use disclaimer card so the
// user knows what's about to run.

import SwiftUI
import Foundation
#if canImport(AROAsk)
import AROAsk

/// Approval policy for the in-process co-pilot. File reads and
/// project-scoped writes flow without prompting — they're confined to
/// the project by PathGuard and every call is shown in the chat. Shell
/// commands (`run_shell`, risk tier .execute) are the exception: they
/// escape the sandbox, so each one stops for explicit confirmation,
/// with an opt-in "always allow" that lasts for this session only.
actor CoPilotToolApprover: ToolApprover {
    private var alwaysAllowShell = false

    func approve(toolName: String, description: String,
                 arguments: String, riskLevel: AskToolRiskLevel) async -> Bool {
        guard riskLevel == .execute else { return true }
        if alwaysAllowShell { return true }
        let command = Self.extractCommand(from: arguments) ?? arguments
        let verdict = await Self.promptOnMain(toolName: toolName, command: command)
        if verdict == .always { alwaysAllowShell = true }
        return verdict != .deny
    }

    private enum Verdict { case allow, always, deny }

    private static func extractCommand(from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj["command"] as? String
    }

    @MainActor
    private static func promptOnMain(toolName: String, command: String) -> Verdict {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Run this shell command?"
        alert.informativeText =
            "The AI co-pilot (\(toolName)) wants to execute:\n\n\(command)"
        let run = alert.addButton(withTitle: "Run")
        let deny = alert.addButton(withTitle: "Deny")
        let always = alert.addButton(withTitle: "Always Allow This Session")
        // No Return-key default: the dialog can appear while the user is
        // typing in the chat field, and a stolen Return must not execute
        // a shell command. Esc denies.
        run.keyEquivalent = ""
        deny.keyEquivalent = "\u{1b}"
        always.keyEquivalent = ""
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .allow
        case .alertThirdButtonReturn: return .always
        default: return .deny
        }
    }
}
#endif

@MainActor
@Observable
final class AICoPilotProcess {
    struct Turn: Identifiable, Equatable {
        let id = UUID()
        let role: Role
        var text: String
        let timestamp: Date

        enum Role { case user, assistant, system, tool, error }
    }

    var turns: [Turn] = []
    private(set) var isThinking: Bool = false
    private(set) var lastError: String?

    /// Called on the main actor with resolved URLs of files the
    /// assistant modified via its tools, as each write lands. The
    /// workspace reloads open editors and reparses through this.
    var onFilesModified: (([URL]) -> Void)?

    // Subprocess plumbing — fallback path only.
    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdinPipe: Pipe?
    private var currentAssistantTurnIndex: Int?

#if canImport(AROAsk)
    /// Warm in-process session: one model load per project, full tool
    /// registry rooted at the project directory.
    private var askSession: AskSession?
    private var askSessionRoot: URL?
    private var askTask: Task<Void, Never>?
    /// Set after an in-process backend failure so later prompts go
    /// straight to the subprocess fallback instead of re-failing.
    private var inProcessUnavailable = false

    /// Raised when the co-pilot cannot start at all (as opposed to a
    /// transient backend error worth retrying via the subprocess).
    private struct CoPilotSetupError: Error { let message: String }
#endif

    /// Send a prompt to `aro ask` in the project's directory.
    /// `focusFile` is the file currently open in the editor — it is
    /// injected into the model's context as the "OPEN FILE" so
    /// unnamed requests ("fix this", "add logging here") target it.
    func send(prompt: String, in project: Project, focusFile: URL? = nil) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        cancel()
        turns.append(Turn(role: .user, text: trimmed, timestamp: Date()))
        isThinking = true
        lastError = nil

        // Log the outgoing prompt in the Internal Logs window so
        // the user can see exactly what we sent to `aro ask`.
        InternalLogStore.shared.record(
            category: .ask, direction: .outbound,
            summary: "→ ask chat  ·  \(trimmed.prefix(60))",
            body: trimmed
        )

        // Detect a `/clean` prompt so we can clear the chat output
        // after `.context` is wiped. Matches whether the user typed
        // exactly `/clean` or `/clean some args`.
        let isCleanCommand = trimmed
            .split(separator: " ", maxSplits: 1)
            .first
            .map { String($0).lowercased() == "/clean" } ?? false

#if canImport(AROAsk)
        if !inProcessUnavailable {
            sendInProcess(trimmed, project: project, focusFile: focusFile,
                          isCleanCommand: isCleanCommand)
            return
        }
#endif
        sendViaSubprocess(trimmed, project: project, isCleanCommand: isCleanCommand)
    }

    // MARK: - In-process path

#if canImport(AROAsk)
    private func sendInProcess(_ prompt: String, project: Project,
                               focusFile: URL?, isCleanCommand: Bool) {
        askTask = Task { [weak self] in
            guard let self else { return }
            do {
                let session = try await self.ensureSession(project: project)
                await session.setFocusFile(focusFile)
                let answer: String
                if let slash = try await self.runSlashCommand(prompt, session: session) {
                    answer = slash
                } else {
                    answer = try await session.ask(prompt)
                }
                guard !Task.isCancelled else { return }
                self.finishAssistantTurn(answer)
                if isCleanCommand {
                    // `.context` is gone on disk; wipe the chat so the
                    // panel matches the fresh conversation.
                    self.turns.removeAll()
                    self.currentAssistantTurnIndex = nil
                }
            } catch is CancellationError {
                self.isThinking = false
            } catch let setup as CoPilotSetupError {
                // Don't route to the subprocess — it would hit the same
                // wall and hang on its interactive download prompt.
                self.failWith(setup.message)
            } catch {
                // In-process backend broke — remember, and fall back to
                // the subprocess path for this and future prompts.
                self.inProcessUnavailable = true
                self.appendSystemNote(
                    "in-process ask failed (\(error.localizedDescription)) — falling back to the `aro ask` subprocess"
                )
                self.sendViaSubprocess(prompt, project: project,
                                       isCleanCommand: isCleanCommand)
            }
        }
    }

    /// Get (or build) the warm session for this project. The session is
    /// recreated when the user switches projects; the model container
    /// itself is cached by the backend, so a rebuild is cheap.
    private func ensureSession(project: Project) async throws -> AskSession {
        let root = project.rootPath.standardizedFileURL
        if let session = askSession, askSessionRoot == root { return session }
        if let old = askSession {
            askSession = nil
            await old.shutdown()
        }

        // The in-process tools (aro_check, aro_run, the MCP bridge)
        // spawn the `aro` CLI. Inside the app bundle CommandLine
        // .arguments.first is SOLARO itself, so hand AROAsk the same
        // binary the console panel uses via $ARO_BIN.
        let aroBin = ConsoleProcess.resolveAroBinary(near: project)
        if aroBin != "/usr/bin/env" {
            setenv("ARO_BIN", aroBin, 1)
        }

        let model = "ARO-Lang/aro-coder-4bit"
        let manager = try ModelManager()
        let env = ProcessInfo.processInfo.environment
        var available = !((env["ARO_ASK_ENDPOINT"] ?? env["ARO_LM_ENDPOINT"]) ?? "").isEmpty
        if !available {
            available = await manager.isInstalled(model)
        }
        guard available else {
            throw CoPilotSetupError(message:
                "The local model \(model) is not installed. Run `aro ask` once in a " +
                "terminal to download it (a few GB), or set ARO_ASK_ENDPOINT to an " +
                "OpenAI-compatible server."
            )
        }

        appendSystemNote("loading \(model) — the first prompt takes a moment…")
        let config = AskSessionConfig(
            workingDirectory: root,
            model: model,
            temperature: 0.2,
            quiet: true             // progress flows through the event sink, not stdout
        )
        // CoPilotToolApprover: sandboxed file tools run freely (every
        // call is shown in the chat); shell commands prompt first.
        let session = AskSession(config: config, approver: CoPilotToolApprover())
        try await session.prepare(modelManager: manager)
        await session.setEventSink { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleAskEvent(event, root: root)
            }
        }
        askSession = session
        askSessionRoot = root
        return session
    }

    /// Mirror `aro ask`'s status lines and tool activity into the chat,
    /// and push modified files back into the workspace as they land.
    private func handleAskEvent(_ event: AskEvent, root: URL) {
        switch event {
        case .status(let message):
            appendSystemNote(message)
        case .toolCallStarted(let name, let arguments):
            appendToolNote("▶ \(name)  \(Self.compactArgs(arguments))")
        case .toolCallFinished(let name, _, let failed, let modifiedPath):
            if failed {
                appendToolNote("✖ \(name) failed")
            } else if let path = modifiedPath {
                appendToolNote("✔ \(name) — wrote \(path)")
                let url = URL(fileURLWithPath: path, relativeTo: root).standardizedFileURL
                onFilesModified?([url])
            }
            // Successful read-only calls stay quiet — the ▶ line
            // already shows what ran; dumping every result would
            // swamp the chat.
        }
    }

    /// One-line argument preview: long values (file contents, edit
    /// strings) collapse to their character count.
    private static func compactArgs(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return String(json.prefix(80)) }
        let parts = obj.keys.sorted().compactMap { key -> String? in
            guard let value = obj[key] else { return nil }
            if let s = value as? String {
                return s.count > 48 ? "\(key): (\(s.count) chars)" : "\(key): \(s)"
            }
            return "\(key): \(value)"
        }
        return String(parts.joined(separator: ", ").prefix(120))
    }

    /// In-process equivalents of the CLI's inline slash commands, so
    /// the picker's commands work identically without a subprocess.
    /// Returns nil when `text` is not a slash command (regular prompt).
    private func runSlashCommand(_ text: String, session: AskSession) async throws -> String? {
        guard text.hasPrefix("/") else { return nil }
        let parts = text.split(separator: " ", maxSplits: 1).map(String.init)
        let cmd = parts[0].lowercased()
        let arg = parts.count > 1
            ? parts[1].trimmingCharacters(in: .whitespaces)
            : ""

        switch cmd {
        case "/help":
            return AskSlashCommand.all
                .map { "`\($0.id)\($0.displayUsage)` — \($0.description)" }
                .joined(separator: "\n")
        case "/clean":
            _ = try? await session.clear()
            return "Deleted .context — the conversation starts fresh."
        case "/tools":
            let names = await session.toolNames().sorted()
            return names.isEmpty ? "No tools registered." : names.joined(separator: "\n")
        case "/model":
            let info = await session.backendInfo()
            return "backend: \(info.name)\nmodel: \(info.model)"
        case "/mcp":
            let labels = await session.mcpServerLabels()
            return labels.isEmpty ? "No MCP servers bridged." : labels.joined(separator: "\n")
        case "/index":
            let count = try await session.rebuildIndex()
            return "Indexed \(count) chunks."
        case "/search":
            guard !arg.isEmpty else { return "Usage: /search <query>" }
            let results = try await session.search(query: arg, k: 5)
            guard !results.isEmpty else { return "No results — run /index first." }
            return results
                .map { "\($0.chunk.path):\($0.chunk.startLine)-\($0.chunk.endLine)  (\(String(format: "%.3f", $0.score)))" }
                .joined(separator: "\n")
        case "/show":
            guard let context = try await session.currentContext() else {
                return "No .context yet."
            }
            return context.messages
                .map { "[\($0.role)] \(($0.content ?? "(tool call)").prefix(120))" }
                .joined(separator: "\n")
        case "/fix":
            guard !arg.isEmpty else { return "Usage: /fix <path>" }
            return try await session.fix(path: arg)
        case "/explain":
            guard !arg.isEmpty else { return "Usage: /explain <path>" }
            return try await session.ask(
                "Use the read_file tool to read \(arg), then explain what each feature set does."
            )
        case "/docs":
            guard !arg.isEmpty else { return "Usage: /docs <path>" }
            return try await session.ask(
                "Read all .aro files in \(arg), then use generate_docs to create a README.md."
            )
        case "/plugin":
            guard !arg.isEmpty else { return "Usage: /plugin <name>" }
            return try await session.ask(
                "Create a new ARO plugin named '\(arg)' using create_plugin. Pick an appropriate language. Then explain how to use it."
            )
        case "/openapi":
            if arg.isEmpty {
                return try await session.ask(
                    "Look at the .aro files in this directory and generate an openapi.yaml using write_openapi."
                )
            }
            return try await session.ask(
                "Generate an openapi.yaml for: \(arg). Use write_openapi."
            )
        case "/quit", "/exit":
            return "Nothing to quit — close the panel with its header controls."
        default:
            return "Unknown command: \(cmd). Type /help for the list."
        }
    }

    private func finishAssistantTurn(_ answer: String) {
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        turns.append(Turn(role: .assistant,
                          text: text.isEmpty ? "(no reply)" : text,
                          timestamp: Date()))
        isThinking = false
        InternalLogStore.shared.record(
            category: .ask, direction: .inbound,
            summary: "← ask chat reply",
            body: text.isEmpty ? "(empty reply)" : text
        )
    }

    private func failWith(_ message: String) {
        lastError = message
        isThinking = false
        turns.append(Turn(role: .error, text: message, timestamp: Date()))
        InternalLogStore.shared.record(
            category: .ask, direction: .error,
            summary: "← ask chat error",
            body: message
        )
    }
#endif

    // MARK: - Subprocess fallback

    /// One-shot `aro ask --yes --no-think <prompt>` invocation. Kept as
    /// the fallback when the in-process backend cannot prepare inside
    /// the app but the CLI works.
    private func sendViaSubprocess(_ trimmed: String, project: Project,
                                   isCleanCommand: Bool) {
        turns.append(Turn(role: .assistant, text: "", timestamp: Date()))
        currentAssistantTurnIndex = turns.count - 1

        let task = Process()
        let aro = ConsoleProcess.resolveAroBinary(near: project)
        var args: [String]
        if aro == "/usr/bin/env" {
            task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            args = ["aro", "ask", "--yes", "--no-think", trimmed]
        } else {
            task.executableURL = URL(fileURLWithPath: aro)
            args = ["ask", "--yes", "--no-think", trimmed]
        }
        task.arguments = args
        task.currentDirectoryURL = project.rootPath

        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        task.standardOutput = stdout
        task.standardError = stderr
        task.standardInput = stdin
        stdoutPipe = stdout
        stderrPipe = stderr
        stdinPipe = stdin

        readPipe(stdout) { [weak self] chunk in
            Task { @MainActor [weak self] in
                self?.appendToAssistantTurn(chunk)
            }
        }
        readPipe(stderr) { [weak self] chunk in
            Task { @MainActor [weak self] in
                // stderr usually contains backend-loading chatter;
                // surface it dim so the user sees progress.
                self?.appendSystemNote(chunk)
            }
        }

        task.terminationHandler = { [weak self] proc in
            let exit = proc.terminationStatus
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isThinking = false
                let body = self.currentAssistantTurnIndex
                    .flatMap { idx -> String? in
                        idx < self.turns.count ? self.turns[idx].text : nil
                    } ?? ""
                InternalLogStore.shared.record(
                    category: .ask,
                    direction: exit == 0 ? .inbound : .error,
                    summary: exit == 0
                        ? "← ask chat reply"
                        : "← ask chat exited \(exit)",
                    body: body.isEmpty ? "(empty stdout)" : body
                )
                if exit != 0 {
                    self.lastError = "aro ask exited with status \(exit)"
                }
                self.process = nil
                if exit == 0 && isCleanCommand {
                    // `.context` is gone on disk, so anything we've
                    // been showing is from the previous session.
                    // Wipe the chat history so the panel matches.
                    self.turns.removeAll()
                    self.currentAssistantTurnIndex = nil
                }
            }
        }

        do {
            try task.run()
            process = task
        } catch {
            lastError = error.localizedDescription
            isThinking = false
            turns.append(Turn(role: .error,
                              text: "Could not launch `aro ask`: \(error.localizedDescription)",
                              timestamp: Date()))
        }
    }

    /// Cancel any in-flight prompt. Called on send() so a rapid
    /// second prompt replaces the first.
    func cancel() {
#if canImport(AROAsk)
        askTask?.cancel()
        askTask = nil
#endif
        guard let process, process.isRunning else { return }
        process.terminate()
    }

    /// Discard the conversation *and* wipe `aro ask`'s on-disk
    /// `.context` so the next prompt starts truly fresh (matches
    /// what the user expects from a Reset button). The cleanup runs
    /// in the background; we wipe the UI state up-front so the
    /// panel reacts immediately.
    func reset(in project: Project? = nil) {
        cancel()
        turns.removeAll()
        currentAssistantTurnIndex = nil
        isThinking = false
        lastError = nil
#if canImport(AROAsk)
        if let session = askSession {
            Task { _ = try? await session.clear() }
            return
        }
#endif
        if let project { Self.runClean(in: project) }
    }

    /// Spawn `aro ask /clean` so the `.context` file gets removed.
    /// Detached and unawaited — Reset doesn't block on it, and a
    /// failure here doesn't roll back the UI wipe.
    nonisolated private static func runClean(in project: Project) {
        let aro = ConsoleProcess.resolveAroBinary(near: project)
        let task = Process()
        if aro == "/usr/bin/env" {
            task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            task.arguments = ["aro", "ask", "/clean"]
        } else {
            task.executableURL = URL(fileURLWithPath: aro)
            task.arguments = ["ask", "/clean"]
        }
        task.currentDirectoryURL = project.rootPath
        // Discard stdio so it doesn't fight for terminal/pipe space.
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        try? task.run()
    }

    // MARK: - Stream plumbing

    nonisolated private func readPipe(_ pipe: Pipe,
                                      onChunk: @Sendable @escaping (String) -> Void) {
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            guard let text = String(data: data, encoding: .utf8) else { return }
            // `aro ask` emits cursor-hide / erase-line / SGR
            // escape sequences for its TTY UI. Strip them so the
            // panel doesn't display gibberish like "[0[?25[K".
            onChunk(ConsoleProcess.stripANSI(text))
        }
    }

    private func appendToAssistantTurn(_ chunk: String) {
        guard let idx = currentAssistantTurnIndex, idx < turns.count else { return }
        turns[idx].text += chunk
    }

    private func appendSystemNote(_ chunk: String) {
        let cleaned = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        // Coalesce consecutive system notes so the panel doesn't
        // grow one row per backend log line.
        if let last = turns.last, last.role == .system {
            turns[turns.count - 1].text += "\n" + cleaned
        } else {
            turns.append(Turn(role: .system, text: cleaned, timestamp: Date()))
        }
    }

    /// Tool-activity lines (▶ call / ✔ result). Coalesced like system
    /// notes so one multi-tool turn reads as a single activity card.
    private func appendToolNote(_ line: String) {
        if let last = turns.last, last.role == .tool {
            turns[turns.count - 1].text += "\n" + line
        } else {
            turns.append(Turn(role: .tool, text: line, timestamp: Date()))
        }
    }
}

// MARK: - Panel view

/// One slash-command shown in the picker that appears above the
/// prompt field when the user types `/` as the first character.
/// Mirrors the menu surfaced by `aro ask /help` so what SOLARO
/// shows and what the CLI accepts stay in sync.
struct AskSlashCommand: Identifiable, Hashable {
    let id: String        // "/help"
    let usage: String?    // "<path>", "<query>"
    let description: String

    var displayUsage: String {
        usage.map { " \($0)" } ?? ""
    }

    /// Single source of truth — kept in `AskCommand.swift` order so
    /// the picker reads top-down like the terminal help text. When
    /// a new command lands in `AROAsk/AskCommand.swift`, add it
    /// here too.
    static let all: [AskSlashCommand] = [
        .init(id: "/help",   usage: nil,        description: "Show all available commands"),
        .init(id: "/fix",    usage: "<path>",   description: "Read, diagnose, and fix errors in the given file"),
        .init(id: "/explain",usage: "<path>",   description: "Explain what the ARO code does"),
        .init(id: "/docs",   usage: "<path>",   description: "Generate documentation for an ARO application"),
        .init(id: "/plugin", usage: "<name>",   description: "Scaffold a new plugin interactively"),
        .init(id: "/openapi",usage: nil,        description: "Generate an openapi.yaml from a description"),
        .init(id: "/clean",  usage: nil,        description: "Delete .context (start fresh)"),
        .init(id: "/show",   usage: nil,        description: "Print current conversation context"),
        .init(id: "/tools",  usage: nil,        description: "List all available tools"),
        .init(id: "/model",  usage: nil,        description: "Show backend and model info"),
        .init(id: "/mcp",    usage: nil,        description: "List connected MCP servers"),
        .init(id: "/index",  usage: nil,        description: "(Re)build the project search index"),
        .init(id: "/search", usage: "<query>",  description: "Search the indexed project"),
    ]

    /// Filter the list by what the user has typed so far. Empty
    /// query returns everything; otherwise prefix-matches on the
    /// command name (case-insensitive). Picker hides itself when
    /// nothing matches.
    static func filter(_ draft: String) -> [AskSlashCommand] {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("/") else { return [] }
        let firstWord = trimmed.split(separator: " ", maxSplits: 1)
            .first
            .map(String.init) ?? trimmed
        let key = firstWord.lowercased()
        if key == "/" { return all }
        return all.filter { $0.id.lowercased().hasPrefix(key) }
    }
}

struct AICoPilotPanel: View {
    let project: Project
    @Bindable var process: AICoPilotProcess
    /// The currently open editor file — used to pre-fill the path
    /// argument for slash commands that take one (`/fix`, `/explain`,
    /// `/docs`). Nil when no file is open; in that case those
    /// commands just expand to "<cmd> " and the user types the
    /// path manually.
    let currentFile: URL?
    let onClose: () -> Void

    @State private var promptDraft: String = ""
    /// Which row in the slash-command picker is currently
    /// highlighted. Wraps modulo the filtered list size.
    @State private var slashHighlight: Int = 0
    @AppStorage("solaro.copilot.firstUseAcknowledged")
    private var firstUseAcknowledged: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(SolaroColor.divider)
            if !firstUseAcknowledged {
                firstUseCard
            } else {
                conversationView
            }
            Divider().background(SolaroColor.divider)
            promptField
        }
        // Transparent so the frosted-glass background owned by the
        // right pane shows through. Without this the panel paints
        // an opaque rectangle on top of the material and the
        // liquid-glass effect disappears.
        .background(Color.clear)
    }

    private var header: some View {
        HStack(spacing: SolaroSpace.s) {
            Image(systemName: "sparkles")
                .foregroundStyle(SolaroColor.accent)
            Text("AI · aro ask")
                .font(SolaroFont.sectionTitle)
                .foregroundStyle(SolaroColor.textSecondary)
                .tracking(2)
            Spacer()
            if process.isThinking {
                ProgressView().controlSize(.small)
            }
            Button {
                process.reset(in: project)
            } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
            }
            .help("Clear the conversation and wipe aro ask's .context")
        }
        .padding(.horizontal, SolaroSpace.m)
        .padding(.vertical, SolaroSpace.xs)
    }

    /// Per ADR-006 the local model isn't auto-downloaded. The card
    /// surfaces the actual backend hierarchy so the user knows
    /// what's about to run before they hit Send.
    private var firstUseCard: some View {
        VStack(alignment: .leading, spacing: SolaroSpace.s) {
            Text("First-time setup")
                .font(SolaroFont.bodyBold)
                .foregroundStyle(SolaroColor.textPrimary)
            Text("`aro ask` runs locally, in-process. Backends are picked in order:")
                .font(SolaroFont.caption)
                .foregroundStyle(SolaroColor.textSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("1.  $ARO_ASK_ENDPOINT  (OpenAI-compatible URL)")
                Text("2.  native MLX (in-process, Apple Silicon)")
                Text("3.  llama-server (GGUF via llama.cpp)")
                Text("4.  mlx_lm.server (Python mlx-lm)")
            }
            .font(SolaroFont.monoCaption)
            .foregroundStyle(SolaroColor.textTertiary)
            Text("The assistant can read and write files in this project, run `aro check`, and apply fixes directly. Every tool call is shown in the chat, the open editor file is always in its context, and shell commands ask for your confirmation before they run.")
                .font(SolaroFont.caption)
                .foregroundStyle(SolaroColor.textSecondary)
            Text("No model is auto-downloaded. Per ADR-006 SOLARO won't reach out without your say-so. Configure one of the above, then continue.")
                .font(SolaroFont.caption)
                .foregroundStyle(SolaroColor.textSecondary)
            Text("If you hit \"Failed to load the default metallib\", build the MLX Metal shaders once with `tools/build-metallib.sh debug` (or `release`) from the SOLARO source tree.")
                .font(SolaroFont.caption)
                .foregroundStyle(SolaroColor.textTertiary)
            HStack {
                Spacer()
                Button("Got it") {
                    firstUseAcknowledged = true
                }
                .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(SolaroSpace.m)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var conversationView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: SolaroSpace.s) {
                    if process.turns.isEmpty {
                        Text("Ask anything — code, language questions, OpenAPI scaffolding, plugin ideas.")
                            .font(SolaroFont.caption)
                            .foregroundStyle(SolaroColor.textTertiary)
                            .padding(SolaroSpace.m)
                    }
                    ForEach(process.turns) { turn in
                        AICoPilotTurnRow(turn: turn)
                            .id(turn.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.vertical, SolaroSpace.s)
            }
            .onChange(of: process.turns.count) { _, _ in
                withAnimation(.linear(duration: 0.1)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    private var promptField: some View {
        VStack(spacing: 0) {
            slashCommandPicker
            HStack(spacing: SolaroSpace.s) {
                TextField(
                    "Ask…",
                    text: $promptDraft,
                    axis: .vertical
                )
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .disabled(!firstUseAcknowledged)
                .onSubmit(handleReturn)
                .onKeyPress(.upArrow) {
                    moveSlashHighlight(by: -1)
                }
                .onKeyPress(.downArrow) {
                    moveSlashHighlight(by: 1)
                }
                Button {
                    send()
                } label: {
                    Label("Send",
                          systemImage: process.isThinking
                            ? "stop.circle" : "arrow.up.circle.fill")
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(promptDraft.isEmpty || !firstUseAcknowledged)
            }
            .padding(.horizontal, SolaroSpace.m)
            .padding(.vertical, SolaroSpace.s)
        }
        .onChange(of: promptDraft) { _, _ in
            // Keep the highlight in range as the filter narrows; if
            // the user types past the matched prefix and the list
            // shrinks, snap back to 0 instead of pointing past end.
            let matches = AskSlashCommand.filter(promptDraft)
            if slashHighlight >= matches.count { slashHighlight = 0 }
        }
    }

    /// Pops up above the prompt field while the draft starts with
    /// `/`. Shows every matching `aro ask` slash-command with its
    /// description as a subline; clicking a row fills the prompt
    /// with that command (plus a space, so the user can type the
    /// argument directly).
    @ViewBuilder
    private var slashCommandPicker: some View {
        let matches = AskSlashCommand.filter(promptDraft)
        if !matches.isEmpty, firstUseAcknowledged {
            VStack(alignment: .leading, spacing: 0) {
                Text("aro ask · slash commands")
                    .font(SolaroFont.caption)
                    .foregroundStyle(SolaroColor.textTertiary)
                    .padding(.horizontal, SolaroSpace.m)
                    .padding(.vertical, 4)
                Divider().background(SolaroColor.divider.opacity(0.5))
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(matches.enumerated()),
                                id: \.element.id) { idx, cmd in
                            slashRow(cmd, active: idx == slashHighlight)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
            .background(SolaroColor.surfaceRaised)
            .overlay(
                Rectangle()
                    .stroke(SolaroColor.divider, lineWidth: 1)
            )
            .padding(.horizontal, SolaroSpace.m)
            .padding(.top, SolaroSpace.xs)
        }
    }

    private func slashRow(_ cmd: AskSlashCommand, active: Bool) -> some View {
        Button {
            applySlash(cmd)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: SolaroSpace.s) {
                    Text(cmd.id)
                        .font(SolaroFont.mono)
                        .foregroundStyle(SolaroColor.accent)
                    if let usage = cmd.usage {
                        Text(usage)
                            .font(SolaroFont.monoCaption)
                            .foregroundStyle(SolaroColor.textTertiary)
                    }
                    Spacer(minLength: 0)
                }
                Text(cmd.description)
                    .font(SolaroFont.caption)
                    .foregroundStyle(SolaroColor.textSecondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SolaroSpace.m)
            .padding(.vertical, 5)
            .background(
                Rectangle()
                    .fill(active
                        ? SolaroColor.selection.opacity(0.6)
                        : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Fill the prompt with the picked command. Commands that take
    /// a `<path>` argument get pre-filled with whatever file is
    /// currently open in the editor — that's almost always what the
    /// user means by "explain this" or "fix this". Other arguments
    /// (`<name>`, `<query>`) just get the trailing space so the
    /// caret lands where the user types next.
    private func applySlash(_ cmd: AskSlashCommand) {
        if cmd.usage == nil {
            promptDraft = cmd.id
        } else if cmd.usage == "<path>",
                  let path = currentFilePathForPrompt() {
            promptDraft = "\(cmd.id) \(path)"
        } else {
            promptDraft = "\(cmd.id) "
        }
        slashHighlight = 0
    }

    /// Format the open editor file as a path the `aro ask` slash
    /// command can hand to its tools. Project-relative when the
    /// file is inside the project root (Tower-friendly `./foo.aro`);
    /// absolute otherwise so files opened from outside still work.
    private func currentFilePathForPrompt() -> String? {
        guard let url = currentFile else { return nil }
        let abs = url.standardizedFileURL.path
        let root = project.rootPath.standardizedFileURL.path
        if abs.hasPrefix(root + "/") {
            return "./" + String(abs.dropFirst(root.count + 1))
        }
        return abs
    }

    /// ↑/↓ keyboard navigation in the slash-command picker. Returns
    /// `.handled` (and updates `slashHighlight`) when the picker is
    /// visible, otherwise `.ignored` so the TextField handles the
    /// arrow normally.
    private func moveSlashHighlight(by delta: Int) -> KeyPress.Result {
        let matches = AskSlashCommand.filter(promptDraft)
        guard !matches.isEmpty else { return .ignored }
        let count = matches.count
        // Modulo with negative-aware wrap so ↑ from index 0 lands
        // on the last entry instead of disappearing off the top.
        let next = ((slashHighlight + delta) % count + count) % count
        slashHighlight = next
        return .handled
    }

    /// Enter handler. When the picker is open, commit the currently
    /// highlighted slash command into the prompt instead of sending
    /// the partial `/foo` text to the model. With no picker visible
    /// it falls back to the existing send-on-Enter behavior.
    private func handleReturn() {
        let matches = AskSlashCommand.filter(promptDraft)
        if !matches.isEmpty {
            let pick = matches[min(slashHighlight, matches.count - 1)]
            applySlash(pick)
            return
        }
        send()
    }

    private func send() {
        let prompt = promptDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        // The open editor file rides along as the model's focus file,
        // so "fix this" / "add an endpoint" target it without a path.
        process.send(prompt: prompt, in: project, focusFile: currentFile)
        promptDraft = ""
    }
}

private struct AICoPilotTurnRow: View {
    let turn: AICoPilotProcess.Turn
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: SolaroSpace.s) {
            Image(systemName: glyph)
                .font(.system(size: 11))
                .foregroundStyle(tint)
                .frame(width: 16, alignment: .center)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: SolaroSpace.s) {
                    Text(roleLabel)
                        .font(SolaroFont.sectionTitle)
                        .foregroundStyle(tint)
                        .tracking(2)
                    Spacer(minLength: 0)
                    // Per-turn copy button — full body, markdown
                    // source intact so users can paste into any
                    // markdown editor.
                    if turn.role == .assistant || turn.role == .user {
                        Button {
                            copyToPasteboard(turn.text)
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                                copied = false
                            }
                        } label: {
                            Image(systemName: copied
                                  ? "checkmark"
                                  : "doc.on.doc")
                                .font(.system(size: 10))
                                .foregroundStyle(copied
                                    ? SolaroColor.stateOK
                                    : SolaroColor.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .help(copied
                              ? "Copied!"
                              : "Copy this message to the clipboard")
                    }
                }
                turnBody
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, SolaroSpace.m)
    }

    /// Render the turn's body. System/error turns stay plain mono
    /// so backend stderr (paths, stack traces) doesn't get its
    /// punctuation interpreted as markdown. Assistant + user turns
    /// flow through the markdown renderer so fenced code blocks,
    /// inline `code`, bold, italic, links, lists, and headings all
    /// look like their rendered form instead of raw source.
    @ViewBuilder
    private var turnBody: some View {
        if turn.role == .system || turn.role == .error || turn.role == .tool {
            Text(turn.text)
                .font(SolaroFont.monoCaption)
                .foregroundStyle(turn.role == .error
                    ? SolaroColor.stateError
                    : SolaroColor.textTertiary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            MarkdownView(text: turn.text)
        }
    }

    private func copyToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private var glyph: String {
        switch turn.role {
        case .user:      return "person.fill"
        case .assistant: return "sparkles"
        case .system:    return "gear"
        case .tool:      return "wrench.and.screwdriver.fill"
        case .error:     return "exclamationmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch turn.role {
        case .user:      return SolaroColor.accent
        case .assistant: return SolaroColor.roleOwn
        case .system:    return SolaroColor.textTertiary
        case .tool:      return SolaroColor.textTertiary
        case .error:     return SolaroColor.stateError
        }
    }

    private var roleLabel: String {
        switch turn.role {
        case .user:      return "YOU"
        case .assistant: return "ARO · ASK"
        case .system:    return "BACKEND"
        case .tool:      return "TOOLS"
        case .error:     return "ERROR"
        }
    }
}

// MARK: - Markdown renderer

/// Lightweight Markdown view for `aro ask` turns. Splits the text
/// on fenced ``` code blocks and renders each region appropriately:
///
///   * Fenced code blocks render in a tinted card with a copy-to-
///     clipboard button in the corner and an optional language tag.
///   * Prose renders through `AttributedString(markdown:)`, which
///     handles inline `code`, **bold**, *italic*, [links], lists,
///     and headings without any extra parsing.
///
/// Parsing is line-based and intentionally simple: a line whose
/// trimmed value starts with ``` opens (or closes) a code block.
/// That matches every model output we've seen and keeps the
/// implementation independent of any markdown library.
struct MarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(Self.parse(text).enumerated()),
                    id: \.offset) { _, seg in
                switch seg {
                case .prose(let s):
                    MarkdownProseView(source: s)
                case .codeBlock(let lang, let body):
                    MarkdownCodeBlockView(language: lang, code: body)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    enum Segment {
        case prose(String)
        case codeBlock(language: String?, code: String)
    }

    /// Walk the source, splitting on fenced code-block boundaries.
    static func parse(_ source: String) -> [Segment] {
        var segments: [Segment] = []
        var proseBuffer: [String] = []
        var codeBuffer: [String] = []
        var inCode = false
        var currentLang: String? = nil

        func flushProse() {
            if !proseBuffer.isEmpty {
                let joined = proseBuffer.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !joined.isEmpty { segments.append(.prose(joined)) }
                proseBuffer.removeAll()
            }
        }

        func flushCode() {
            let body = codeBuffer.joined(separator: "\n")
            segments.append(.codeBlock(language: currentLang, code: body))
            codeBuffer.removeAll()
            currentLang = nil
        }

        for raw in source.split(separator: "\n",
                                omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inCode {
                    flushCode()
                    inCode = false
                } else {
                    flushProse()
                    inCode = true
                    let tag = String(trimmed.dropFirst(3))
                        .trimmingCharacters(in: .whitespaces)
                    currentLang = tag.isEmpty ? nil : tag
                }
                continue
            }
            if inCode {
                codeBuffer.append(line)
            } else {
                proseBuffer.append(line)
            }
        }
        // Unclosed fence: render whatever was inside as a code
        // block anyway so the user still sees the contents.
        if inCode { flushCode() } else { flushProse() }
        return segments
    }
}

/// Prose paragraph rendered through `AttributedString(markdown:)`.
/// Handles inline `code`, **bold**, *italic*, [links], lists, and
/// ATX headings. Falls back to plain text if the source has a
/// shape `AttributedString` rejects (rare — the initializer
/// accepts almost any input).
private struct MarkdownProseView: View {
    let source: String

    var body: some View {
        Text(attributed)
            .font(SolaroFont.body)
            .foregroundStyle(SolaroColor.textPrimary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var attributed: AttributedString {
        // `.full` interprets the input as a markdown *document*
        // (paragraphs, headings, lists) rather than a single line.
        // Per-line line breaks land as soft breaks so wrapping
        // mirrors what the user typed.
        var options = AttributedString.MarkdownParsingOptions()
        options.allowsExtendedAttributes = true
        options.interpretedSyntax = .full
        options.failurePolicy = .returnPartiallyParsedIfPossible
        return (try? AttributedString(
            markdown: source, options: options
        )) ?? AttributedString(source)
    }
}

/// Fenced code block — tinted card, mono font, optional language
/// tag in the top-right, copy-to-clipboard button next to it.
private struct MarkdownCodeBlockView: View {
    let language: String?
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: SolaroSpace.xs) {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(SolaroFont.monoCaption)
                        .foregroundStyle(SolaroColor.textTertiary)
                }
                Spacer()
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(code, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                        copied = false
                    }
                } label: {
                    Image(systemName: copied
                          ? "checkmark"
                          : "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundStyle(copied
                            ? SolaroColor.stateOK
                            : SolaroColor.textTertiary)
                }
                .buttonStyle(.plain)
                .help(copied ? "Copied!" : "Copy code block")
            }
            .padding(.horizontal, SolaroSpace.s)
            .padding(.top, 4)
            Text(code)
                .font(SolaroFont.mono)
                .foregroundStyle(SolaroColor.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(SolaroSpace.s)
        }
        .background(
            RoundedRectangle(cornerRadius: SolaroRadius.s)
                .fill(SolaroColor.backdrop)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SolaroRadius.s)
                .stroke(SolaroColor.divider.opacity(0.5), lineWidth: 1)
        )
    }
}
