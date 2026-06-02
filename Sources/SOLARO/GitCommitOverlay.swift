// ============================================================
// GitCommitOverlay.swift
// SOLARO — commit changed files from the status bar.
// ============================================================
//
// Opened from the status bar's "N changed" chip. Shows the file
// list, fires `aro ask` to suggest a commit message from the
// diff, and lets the user edit / overwrite before pressing
// Commit. If `aro ask` fails or returns nothing useful, the
// message field stays empty for manual entry.

import SwiftUI
import Foundation

@MainActor
@Observable
final class GitCommitModel {
    var message: String = ""
    var suggestion: String = ""
    var isSuggesting: Bool = false
    var suggestionFailed: Bool = false
    var suggestionError: String?

    /// Stderr from the last failed commit, surfaced to the user
    /// so they can read e.g. "nothing to commit" or hook errors.
    var commitError: String?
    var isCommitting: Bool = false

    private var askProcess: Process?

    /// Spawn `aro ask` with the diff as context. The first non-
    /// blank, non-trivial line we get back is treated as the
    /// commit subject; the rest becomes the body. We bail out on
    /// 30s with `suggestionFailed = true` so the user can type
    /// their own message.
    func requestSuggestion(diff: String, in project: Project) {
        cancelSuggestion()
        suggestion = ""
        suggestionFailed = false
        suggestionError = nil
        isSuggesting = true

        let prompt = Self.buildPrompt(diff: diff)
        let aro = ConsoleProcess.resolveAroBinary(near: project)
        let task = Process()
        var args: [String]
        if aro == "/usr/bin/env" {
            task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            args = ["aro", "ask", "--yes", "--no-think", prompt]
        } else {
            task.executableURL = URL(fileURLWithPath: aro)
            args = ["ask", "--yes", "--no-think", prompt]
        }
        task.arguments = args
        task.currentDirectoryURL = project.rootPath

        let out = Pipe()
        let err = Pipe()
        task.standardOutput = out
        task.standardError = err
        task.terminationHandler = { [weak self] proc in
            let stdout = (try? out.fileHandleForReading.readToEnd()) ?? Data()
            let stderr = (try? err.fileHandleForReading.readToEnd()) ?? Data()
            let outText = ConsoleProcess.stripANSI(
                String(data: stdout, encoding: .utf8) ?? ""
            )
            let errText = String(data: stderr, encoding: .utf8) ?? ""
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isSuggesting = false
                self.askProcess = nil
                guard proc.terminationStatus == 0 else {
                    self.suggestionFailed = true
                    self.suggestionError = errText
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return
                }
                let cleaned = Self.cleanSuggestion(outText)
                guard !cleaned.isEmpty else {
                    self.suggestionFailed = true
                    self.suggestionError =
                        "`aro ask` returned an empty message."
                    return
                }
                self.suggestion = cleaned
                // Only fill the editor when the user hasn't typed
                // anything yet — otherwise we'd clobber their work.
                if self.message
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
                {
                    self.message = cleaned
                }
            }
        }

        do {
            try task.run()
            askProcess = task
        } catch {
            isSuggesting = false
            suggestionFailed = true
            suggestionError = error.localizedDescription
        }
    }

    func cancelSuggestion() {
        guard let askProcess, askProcess.isRunning else { return }
        askProcess.terminate()
        self.askProcess = nil
        isSuggesting = false
    }

    private static func buildPrompt(diff: String) -> String {
        // Cap the diff so the prompt stays under any local model's
        // context window. Conventional-commits style is what the
        // ARO repo's own commits use, so ask for that.
        let cap = 8000
        let truncated = diff.count > cap
            ? String(diff.prefix(cap)) + "\n…(diff truncated)\n"
            : diff
        return """
        You are writing a single Git commit message for the diff below.
        Format: a Conventional Commits subject line on the first line
        (e.g. `feat(scope): summary`, `fix(scope): summary`, max 72
        chars), then a blank line, then an optional short body. Output
        only the commit message — no prose around it, no fences, no
        "Here's the commit message:" preamble.

        Diff:
        \(truncated)
        """
    }

    /// Trim the model output: drop leading prose, code fences, and
    /// blank prefixes so what's left is the bare commit message.
    private static func cleanSuggestion(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip a leading ```…``` fence if the model wrapped it.
        if text.hasPrefix("```") {
            if let firstNewline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: firstNewline)...])
            }
            if text.hasSuffix("```") {
                text = String(text.dropLast(3))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        // Drop obvious lead-ins like "Commit message:" / "Here's …".
        let lines = text.components(separatedBy: "\n")
        var firstReal = 0
        for (i, line) in lines.enumerated() {
            let t = line.trimmingCharacters(in: .whitespaces).lowercased()
            if t.hasPrefix("here") || t.hasPrefix("commit message") ||
               t.hasPrefix("sure,") || t.hasPrefix("okay") || t.isEmpty
            {
                firstReal = i + 1
                continue
            }
            break
        }
        let kept = lines.dropFirst(firstReal).joined(separator: "\n")
        return kept.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct GitCommitSheet: View {
    let project: Project
    @Bindable var model: GitCommitModel
    let monitor: GitStatusMonitor
    let onClose: () -> Void

    @State private var diff: String = ""
    @State private var loadingDiff: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: SolaroSpace.m) {
            header
            Divider()
            HSplitView {
                fileList
                    .frame(minWidth: 200, idealWidth: 240)
                diffPane
                    .frame(minWidth: 320)
            }
            messageEditor
            errorBanner
            footer
        }
        .padding(SolaroSpace.l)
        .frame(minWidth: 720, minHeight: 520)
        .background(SolaroColor.surface)
        .task {
            loadingDiff = true
            let text = await monitor.diffAgainstHEAD(in: project)
            diff = text
            loadingDiff = false
            // Kick off the suggestion right away. The result still
            // arrives async; in the meantime the editor is empty
            // and clearly labelled "(suggesting…)".
            if !text.isEmpty {
                model.requestSuggestion(diff: text, in: project)
            }
        }
        .onDisappear { model.cancelSuggestion() }
    }

    private var header: some View {
        HStack(spacing: SolaroSpace.s) {
            Image(systemName: "checkmark.seal")
                .foregroundStyle(SolaroColor.accent)
            Text("Commit changes")
                .font(SolaroFont.toolbarTitle)
            Text("\(monitor.status.files.count) files")
                .font(SolaroFont.monoCaption)
                .foregroundStyle(SolaroColor.textTertiary)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Close")
        }
    }

    private var fileList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                let ordered = monitor.status.files
                    .sorted { $0.key < $1.key }
                ForEach(ordered, id: \.key) { (path, status) in
                    HStack(spacing: SolaroSpace.xs) {
                        Text(letter(for: status))
                            .font(SolaroFont.monoCaption)
                            .foregroundStyle(color(for: status))
                            .frame(width: 14, alignment: .leading)
                        Text(relativePath(path))
                            .font(SolaroFont.monoCaption)
                            .foregroundStyle(SolaroColor.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.vertical, 1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(SolaroSpace.s)
        }
        .background(SolaroColor.backdrop)
        .clipShape(RoundedRectangle(cornerRadius: SolaroRadius.s))
    }

    private var diffPane: some View {
        ScrollView([.horizontal, .vertical]) {
            if loadingDiff {
                ProgressView()
                    .controlSize(.small)
                    .padding()
            } else if diff.isEmpty {
                Text("(no tracked changes — `git diff HEAD` is empty)")
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(SolaroColor.textTertiary)
                    .padding()
            } else {
                Text(diff)
                    .font(SolaroFont.mono)
                    .foregroundStyle(SolaroColor.textPrimary)
                    .textSelection(.enabled)
                    .padding(SolaroSpace.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(SolaroColor.backdrop)
        .clipShape(RoundedRectangle(cornerRadius: SolaroRadius.s))
    }

    private var messageEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Message")
                    .font(SolaroFont.sectionTitle)
                    .foregroundStyle(SolaroColor.textSecondary)
                    .tracking(2)
                if model.isSuggesting {
                    ProgressView()
                        .controlSize(.mini)
                    Text("aro ask is suggesting a message…")
                        .font(SolaroFont.monoCaption)
                        .foregroundStyle(SolaroColor.textTertiary)
                } else if model.suggestionFailed {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(SolaroColor.stateWarn)
                    Text("aro ask couldn't help — type your own message.")
                        .font(SolaroFont.monoCaption)
                        .foregroundStyle(SolaroColor.stateWarn)
                } else if !model.suggestion.isEmpty {
                    Image(systemName: "sparkles")
                        .foregroundStyle(SolaroColor.accent)
                    Text("suggested by aro ask · edit freely")
                        .font(SolaroFont.monoCaption)
                        .foregroundStyle(SolaroColor.textTertiary)
                }
                Spacer()
                Button("Re-suggest") {
                    model.requestSuggestion(diff: diff, in: project)
                }
                .controlSize(.small)
                .disabled(model.isSuggesting || diff.isEmpty)
            }
            TextEditor(text: $model.message)
                .font(SolaroFont.mono)
                .foregroundStyle(SolaroColor.textPrimary)
                .scrollContentBackground(.hidden)
                .background(SolaroColor.backdrop)
                .frame(minHeight: 100, maxHeight: 180)
                .clipShape(RoundedRectangle(cornerRadius: SolaroRadius.s))
                .overlay(
                    RoundedRectangle(cornerRadius: SolaroRadius.s)
                        .stroke(SolaroColor.divider, lineWidth: 1)
                )
        }
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let err = model.commitError {
            HStack(alignment: .top, spacing: SolaroSpace.s) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .foregroundStyle(SolaroColor.stateError)
                Text(err)
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(SolaroColor.stateError)
                    .textSelection(.enabled)
            }
            .padding(SolaroSpace.s)
            .background(SolaroColor.stateError.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: SolaroRadius.s))
        }
    }

    private var footer: some View {
        HStack {
            if let err = model.suggestionError, !err.isEmpty,
               model.suggestionFailed
            {
                Text(err)
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(SolaroColor.textTertiary)
                    .lineLimit(2)
            }
            Spacer()
            Button("Cancel", action: onClose)
                .keyboardShortcut(.cancelAction)
            Button {
                commit()
            } label: {
                if model.isCommitting {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Commit")
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(
                model.isCommitting ||
                model.message.trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
            )
        }
    }

    private func commit() {
        let trimmed = model.message
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        model.isCommitting = true
        model.commitError = nil
        Task {
            let err = await monitor.commit(message: trimmed, in: project)
            model.isCommitting = false
            if let err {
                model.commitError = err
            } else {
                onClose()
            }
        }
    }

    private func relativePath(_ absolute: String) -> String {
        let root = project.rootPath.standardizedFileURL.path
        if absolute.hasPrefix(root + "/") {
            return String(absolute.dropFirst(root.count + 1))
        }
        return absolute
    }

    private func letter(for status: GitStatus.FileStatus) -> String {
        switch status {
        case .modified:   return "M"
        case .added:      return "A"
        case .deleted:    return "D"
        case .renamed:    return "R"
        case .untracked:  return "?"
        case .ignored:    return "!"
        case .conflicted: return "U"
        }
    }

    private func color(for status: GitStatus.FileStatus) -> Color {
        switch status {
        case .modified:   return SolaroColor.stateWarn
        case .added:      return SolaroColor.stateOK
        case .deleted:    return SolaroColor.stateError
        case .renamed:    return SolaroColor.accent
        case .untracked:  return SolaroColor.textTertiary
        case .ignored:    return SolaroColor.textTertiary
        case .conflicted: return SolaroColor.stateError
        }
    }
}
