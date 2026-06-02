// ============================================================
// AICoPilot.swift
// SOLARO — `aro ask` co-pilot panel (#233 §4)
// ============================================================
//
// Local-first co-pilot per ADR-006. Spawns `aro ask` as a
// subprocess, streams its output, and surfaces the conversation
// as a chat-style right-rail panel.
//
// No auto-download of models, no auto-configuration of remote
// endpoints — `aro ask` handles backend selection (ARO_ASK_ENDPOINT
// → llama-server → mlx_lm.server). The panel shows a first-use
// disclaimer card so the user knows what's about to run.

import SwiftUI
import Foundation

@MainActor
@Observable
final class AICoPilotProcess {
    struct Turn: Identifiable, Equatable {
        let id = UUID()
        let role: Role
        var text: String
        let timestamp: Date

        enum Role { case user, assistant, system, error }
    }

    var turns: [Turn] = []
    private(set) var isThinking: Bool = false
    private(set) var lastError: String?

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdinPipe: Pipe?
    private var currentAssistantTurnIndex: Int?

    /// Send a prompt to `aro ask` running in the project's
    /// directory. Each prompt is its own subprocess invocation
    /// (one-shot) so we don't have to manage a long-lived REPL.
    func send(prompt: String, in project: Project) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        cancel()
        turns.append(Turn(role: .user, text: trimmed, timestamp: Date()))
        turns.append(Turn(role: .assistant, text: "", timestamp: Date()))
        currentAssistantTurnIndex = turns.count - 1
        isThinking = true
        lastError = nil

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
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isThinking = false
                if proc.terminationStatus != 0 {
                    self.lastError = "aro ask exited with status \(proc.terminationStatus)"
                }
                self.process = nil
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

    /// Cancel any in-flight subprocess. Called on send() so a
    /// rapid second prompt replaces the first.
    func cancel() {
        guard let process, process.isRunning else { return }
        process.terminate()
    }

    /// Discard the conversation. Doesn't touch `aro ask`'s own
    /// `.context` file — the user can `/clean` from the CLI for that.
    func reset() {
        cancel()
        turns.removeAll()
        currentAssistantTurnIndex = nil
        isThinking = false
        lastError = nil
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
}

// MARK: - Panel view

struct AICoPilotPanel: View {
    let project: Project
    @Bindable var process: AICoPilotProcess
    let onClose: () -> Void

    @State private var promptDraft: String = ""
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
        .background(SolaroColor.surface)
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
                process.reset()
            } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
            }
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
            Text("`aro ask` runs locally. Backends are picked in order:")
                .font(SolaroFont.caption)
                .foregroundStyle(SolaroColor.textSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("1.  $ARO_ASK_ENDPOINT  (OpenAI-compatible URL)")
                Text("2.  llama-server (GGUF via llama.cpp)")
                Text("3.  mlx_lm.server (Apple Silicon via mlx-lm)")
            }
            .font(SolaroFont.monoCaption)
            .foregroundStyle(SolaroColor.textTertiary)
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
        HStack(spacing: SolaroSpace.s) {
            TextField(
                "Ask…",
                text: $promptDraft,
                axis: .vertical
            )
            .lineLimit(1...4)
            .textFieldStyle(.roundedBorder)
            .disabled(!firstUseAcknowledged)
            .onSubmit(send)
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

    private func send() {
        let prompt = promptDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        process.send(prompt: prompt, in: project)
        promptDraft = ""
    }
}

private struct AICoPilotTurnRow: View {
    let turn: AICoPilotProcess.Turn

    var body: some View {
        HStack(alignment: .top, spacing: SolaroSpace.s) {
            Image(systemName: glyph)
                .font(.system(size: 11))
                .foregroundStyle(tint)
                .frame(width: 16, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(roleLabel)
                    .font(SolaroFont.sectionTitle)
                    .foregroundStyle(tint)
                    .tracking(2)
                Text(turn.text)
                    .font(turn.role == .system ? SolaroFont.monoCaption : SolaroFont.body)
                    .foregroundStyle(turn.role == .system
                                     ? SolaroColor.textTertiary
                                     : SolaroColor.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, SolaroSpace.m)
    }

    private var glyph: String {
        switch turn.role {
        case .user:      return "person.fill"
        case .assistant: return "sparkles"
        case .system:    return "gear"
        case .error:     return "exclamationmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch turn.role {
        case .user:      return SolaroColor.accent
        case .assistant: return SolaroColor.roleOwn
        case .system:    return SolaroColor.textTertiary
        case .error:     return SolaroColor.stateError
        }
    }

    private var roleLabel: String {
        switch turn.role {
        case .user:      return "YOU"
        case .assistant: return "ARO · ASK"
        case .system:    return "BACKEND"
        case .error:     return "ERROR"
        }
    }
}
