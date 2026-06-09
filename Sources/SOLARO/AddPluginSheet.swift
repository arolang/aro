// ============================================================
// AddPluginSheet.swift
// SOLARO — Git URL → `aro add` plugin installer
// ============================================================
//
// Sheet shown from the sidebar Plugins tab's Add button. The user
// enters a Git URL (optionally a branch or ref), SOLARO spawns
// `aro add <url> -d <project>` as a subprocess, and the resulting
// stdout / stderr stream into the sheet's log view. On success
// the sheet auto-dismisses and the parent refreshes the plugin
// listing.

import SwiftUI
import Foundation

@MainActor
@Observable
final class AddPluginProcess {
    enum State: Equatable {
        case idle
        case running
        case success
        case failed(String)
    }

    var state: State = .idle
    var log: String = ""

    private var process: Process?

    /// Validate the URL minimally, then spawn `aro add`. The
    /// `aro` CLI does its own validation (clone, parse plugin.yaml,
    /// etc.) — we just gate on the URL being non-empty and looking
    /// like a Git URL.
    func install(
        url: String,
        ref: String?,
        branch: String?,
        project: Project
    ) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            state = .failed("Enter a Git URL.")
            return
        }
        guard isLikelyGitURL(trimmed) else {
            state = .failed("That doesn't look like a Git URL or known shorthand. Try `github:org/repo`, `https://…`, `git@host:path.git`, or a local path.")
            return
        }
        log = ""
        state = .running

        let aro = ConsoleProcess.resolveAroBinary(near: project)
        var subArgs: [String] = ["add", trimmed,
                                 "-d", project.rootPath.path]
        if let ref, !ref.isEmpty {
            subArgs.append(contentsOf: ["--ref", ref])
        }
        if let branch, !branch.isEmpty {
            subArgs.append(contentsOf: ["--branch", branch])
        }

        let task = Process()
        if aro == "/usr/bin/env" {
            task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            task.arguments = ["aro"] + subArgs
        } else {
            task.executableURL = URL(fileURLWithPath: aro)
            task.arguments = subArgs
        }
        task.currentDirectoryURL = project.rootPath

        let stdout = Pipe()
        let stderr = Pipe()
        task.standardOutput = stdout
        task.standardError = stderr

        readPipe(stdout) { [weak self] chunk in
            Task { @MainActor [weak self] in self?.log += chunk }
        }
        readPipe(stderr) { [weak self] chunk in
            Task { @MainActor [weak self] in self?.log += chunk }
        }

        task.terminationHandler = { [weak self] proc in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if proc.terminationStatus == 0 {
                    self.state = .success
                } else {
                    self.state = .failed("aro add exited with status \(proc.terminationStatus)")
                }
                self.process = nil
            }
        }

        do {
            try task.run()
            process = task
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func cancel() {
        process?.terminate()
        process = nil
        state = .idle
    }

    func reset() {
        cancel()
        log = ""
        state = .idle
    }

    nonisolated private func readPipe(
        _ pipe: Pipe,
        onChunk: @Sendable @escaping (String) -> Void
    ) {
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            guard let text = String(data: data, encoding: .utf8) else { return }
            onChunk(ConsoleProcess.stripANSI(text))
        }
    }

    private func isLikelyGitURL(_ string: String) -> Bool {
        // `aro add` accepts a lot of shapes — the IDE shouldn't be
        // pickier than the CLI. The branches below cover every
        // shape the CLI documents (CLAUDE.md mentions
        // `github:org/repo` shorthand, plus the canonical SSH /
        // HTTPS / git:// forms) and falls through to a permissive
        // "looks like a path or URL" check so user repos on
        // self-hosted forges aren't rejected for not matching a
        // recognised prefix.
        let scheme = string.split(separator: ":", maxSplits: 1)
            .first
            .map { String($0).lowercased() } ?? ""

        // Forge shorthand (`github:org/repo`, `gitlab:org/repo`,
        // `codeberg:…`, etc.). The set is open-ended; any prefix
        // followed by `:org/repo` flows through.
        let forgeShorthand: Set<String> = [
            "github", "gitlab", "bitbucket", "codeberg", "sourcehut", "sr.ht"
        ]
        if forgeShorthand.contains(scheme),
           string.contains(":") && string.contains("/")
        { return true }

        // Known URL schemes the CLI hands to git directly.
        let knownSchemes: Set<String> = [
            "https", "http", "git", "ssh", "file"
        ]
        if knownSchemes.contains(scheme),
           string.contains("://")
        { return true }

        // SCP-style SSH (`git@host:path`, `kris@host:path`).
        if string.contains("@") && string.contains(":") { return true }

        // Local filesystem path (absolute or `./foo`).
        if string.hasPrefix("/") || string.hasPrefix("./")
            || string.hasPrefix("~/")
        { return true }

        // Last-chance heuristic — anything that contains a `/` is
        // probably a path or a forge shorthand and worth handing
        // to `aro add`. The CLI surfaces a precise error if it
        // can't make sense of the input.
        return string.contains("/")
    }
}

struct AddPluginSheet: View {
    let project: Project
    @Bindable var process: AddPluginProcess
    let onCancel: () -> Void
    let onSuccess: () -> Void

    @State private var url: String = ""
    @State private var branch: String = ""
    @State private var ref: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: SolaroSpace.m) {
            header
            Divider().background(SolaroColor.divider)
            switch process.state {
            case .idle, .running:
                inputForm
            case .success:
                successView
            case .failed(let message):
                inputForm
                Text(message)
                    .font(SolaroFont.caption)
                    .foregroundStyle(SolaroColor.stateError)
                    .padding(.top, 4)
            }
            if !process.log.isEmpty {
                logView
            }
            Spacer()
            actionBar
        }
        .padding(SolaroSpace.l)
        .frame(width: 540, height: 460)
        .background(SolaroColor.surface)
    }

    private var header: some View {
        HStack(spacing: SolaroSpace.s) {
            Image(systemName: "puzzlepiece.extension")
                .foregroundStyle(SolaroColor.accent)
            Text("Install a plugin")
                .font(SolaroFont.bodyBold)
                .foregroundStyle(SolaroColor.textPrimary)
            Spacer()
        }
    }

    private var inputForm: some View {
        VStack(alignment: .leading, spacing: SolaroSpace.s) {
            Text("`aro add` clones the repository into your project's `Plugins/` directory and validates its `plugin.yaml`.")
                .font(SolaroFont.caption)
                .foregroundStyle(SolaroColor.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            field(label: "Git URL", text: $url,
                  placeholder: "git@github.com:org/repo.git or https://host/org/repo.git")
            HStack(spacing: SolaroSpace.m) {
                field(label: "Branch", text: $branch, placeholder: "main (optional)")
                field(label: "Ref", text: $ref, placeholder: "v1.0.0 (optional)")
            }
        }
    }

    private func field(label: String,
                       text: Binding<String>,
                       placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(SolaroFont.monoCaption)
                .foregroundStyle(SolaroColor.textTertiary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .disabled(process.state == .running)
        }
    }

    private var successView: some View {
        VStack(alignment: .leading, spacing: SolaroSpace.s) {
            HStack(spacing: SolaroSpace.xs) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(SolaroColor.stateOK)
                Text("Plugin installed.")
                    .font(SolaroFont.body)
                    .foregroundStyle(SolaroColor.textPrimary)
            }
            Text("The Plugins sidebar refreshes automatically.")
                .font(SolaroFont.caption)
                .foregroundStyle(SolaroColor.textSecondary)
        }
    }

    private var logView: some View {
        ScrollView {
            Text(process.log)
                .font(SolaroFont.monoCaption)
                .foregroundStyle(SolaroColor.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .frame(minHeight: 100, maxHeight: 220)
        .padding(SolaroSpace.s)
        .background(SolaroColor.backdrop)
        .clipShape(RoundedRectangle(cornerRadius: SolaroRadius.s))
        .overlay(
            RoundedRectangle(cornerRadius: SolaroRadius.s)
                .stroke(SolaroColor.divider, lineWidth: 1)
        )
    }

    private var actionBar: some View {
        HStack {
            if case .failed = process.state {
                Button("Reset") { process.reset() }
            } else if case .success = process.state {
                Button("Reset") { process.reset() }
            }
            Spacer()
            Button("Cancel") {
                process.cancel()
                onCancel()
            }
            .keyboardShortcut(.escape, modifiers: [])
            if process.state == .success {
                Button("Done") {
                    onSuccess()
                }
                .keyboardShortcut(.return, modifiers: [])
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    process.install(
                        url: url,
                        ref: ref.isEmpty ? nil : ref,
                        branch: branch.isEmpty ? nil : branch,
                        project: project
                    )
                } label: {
                    HStack(spacing: 4) {
                        if process.state == .running {
                            ProgressView().controlSize(.small)
                        }
                        Text(process.state == .running ? "Installing…" : "Install")
                    }
                }
                .keyboardShortcut(.return, modifiers: [])
                .buttonStyle(.borderedProminent)
                .disabled(process.state == .running || url.isEmpty)
            }
        }
    }
}
