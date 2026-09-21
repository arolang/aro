// ============================================================
// NewPluginSheet.swift
// SOLARO — starting a plugin, not just installing one (#768)
// ============================================================
//
// The Plugins sidebar could browse the marketplace, install from a Git
// URL, reveal a `plugin.yaml` and uninstall. The one verb it did not
// have was "new", although the CLI has had `aro new plugin <name>
// --lang …` all along and ARO-0087 is an entire proposal about plugin
// developer experience. The IDE is where a new plugin should start.
//
// Same shape as `AddPluginSheet`: collect the arguments, run the CLI,
// stream its output into the sheet, refresh the listing on success. The
// scaffold is the CLI's, so there is one definition of what a new
// plugin looks like.

import SwiftUI
import Foundation

/// The languages `aro new plugin` can scaffold.
///
/// `--lang` is required by the CLI — there is no default — so the
/// picker starts on Swift and the user must have chosen something by
/// the time the button is enabled.
enum PluginLanguage: String, CaseIterable, Identifiable, Sendable {
    case swift, rust, c, cpp, python, aro

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .swift:  return "Swift"
        case .rust:   return "Rust"
        case .c:      return "C"
        case .cpp:    return "C++"
        case .python: return "Python"
        case .aro:    return "ARO"
        }
    }

    /// What the scaffold gives you, in one line.
    var detail: String {
        switch self {
        case .swift:
            return "The @AROExport macro generates the C ABI for you."
        case .rust:
            return "#[no_mangle] extern \"C\" entry points."
        case .c:
            return "ARO_PLUGIN() and ARO_ACTION() macros from the SDK header."
        case .cpp:
            return "The C SDK header, compiled as C++."
        case .python:
            return "Decorators and export_abi; runs as a subprocess."
        case .aro:
            return "Actions written in ARO itself."
        }
    }
}

/// Validation of a plugin name, away from the view so it can be tested.
enum PluginNameCheck {
    /// Why a name will not do, or `nil` when it will.
    ///
    /// The name becomes a directory under `Plugins/` and a handle in
    /// `plugin.yaml`, so it has to survive both. Deliberately close to
    /// what the CLI accepts rather than stricter — the IDE should not
    /// refuse a plugin the command line would create.
    static func rejection(for raw: String, existing: Set<String>) -> String? {
        let name = raw.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return "Enter a name." }
        if existing.contains(name) {
            return "Plugins/\(name) already exists."
        }
        if name.hasPrefix(".") {
            return "A name starting with a dot would be hidden."
        }
        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "-_"))
        if name.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            return "Use letters, digits, hyphens and underscores."
        }
        return nil
    }
}

@MainActor
@Observable
final class NewPluginProcess {
    enum State: Equatable {
        case idle
        case running
        /// Carries where the scaffold landed, so the caller can open it.
        case success(URL)
        case failed(String)
    }

    var state: State = .idle
    var log: String = ""

    private var process: Process?

    func create(name rawName: String, language: PluginLanguage,
                project: Project, existing: Set<String>) {
        let name = rawName.trimmingCharacters(in: .whitespaces)
        if let rejection = PluginNameCheck.rejection(for: name,
                                                     existing: existing) {
            state = .failed(rejection)
            return
        }
        log = ""
        state = .running

        let aro = ConsoleProcess.resolveAroBinary(near: project)
        let subArgs = ["new", "plugin", name, "--lang", language.rawValue]

        let task = Process()
        if aro == "/usr/bin/env" {
            task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            task.arguments = ["aro"] + subArgs
        } else {
            task.executableURL = URL(fileURLWithPath: aro)
            task.arguments = subArgs
        }
        // `aro new plugin` scaffolds relative to the working directory,
        // which is how it lands in this project rather than wherever
        // the app was launched from.
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

        let manifest = project.rootPath
            .appendingPathComponent("Plugins", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent("plugin.yaml")

        task.terminationHandler = { [weak self] proc in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if proc.terminationStatus == 0 {
                    self.state = .success(manifest)
                } else {
                    self.state = .failed(
                        "aro new plugin exited with status \(proc.terminationStatus)")
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
}

struct NewPluginSheet: View {
    let project: Project
    /// Names already under `Plugins/`, so a clash is caught before the
    /// CLI runs rather than as an exit status.
    let existingNames: Set<String>
    @Bindable var process: NewPluginProcess
    let onCancel: () -> Void
    /// Called with the new `plugin.yaml` so the caller can open it.
    let onSuccess: (URL) -> Void

    @State private var name = ""
    @State private var language: PluginLanguage = .swift

    var body: some View {
        VStack(alignment: .leading, spacing: SolaroSpace.m) {
            HStack(spacing: SolaroSpace.s) {
                Image(systemName: "puzzlepiece.extension")
                    .foregroundStyle(SolaroColor.accent)
                Text("New plugin")
                    .font(SolaroFont.toolbarTitle)
                Spacer()
            }

            TextField("plugin-name", text: $name)
                .textFieldStyle(.roundedBorder)
                .disabled(isRunning)

            Picker("Language", selection: $language) {
                ForEach(PluginLanguage.allCases) { lang in
                    Text(lang.displayName).tag(lang)
                }
            }
            .disabled(isRunning)
            Text(language.detail)
                .font(SolaroFont.caption)
                .foregroundStyle(SolaroColor.textTertiary)

            Text("$ aro new plugin \(displayName) --lang \(language.rawValue)")
                .font(SolaroFont.monoCaption)
                .foregroundStyle(SolaroColor.textSecondary)
                .textSelection(.enabled)

            if !process.log.isEmpty {
                ScrollView {
                    Text(process.log)
                        .font(SolaroFont.monoCaption)
                        .foregroundStyle(SolaroColor.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 140)
            }
            if case .failed(let message) = process.state {
                Text(message)
                    .font(SolaroFont.caption)
                    .foregroundStyle(SolaroColor.stateError)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    process.cancel()
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                Button("Create") {
                    process.create(name: name, language: language,
                                   project: project,
                                   existing: existingNames)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isRunning || rejection != nil)
            }
        }
        .padding(SolaroSpace.l)
        .frame(width: 460)
        .background(SolaroColor.surface)
        .onChange(of: process.state) { _, state in
            if case .success(let manifest) = state { onSuccess(manifest) }
        }
    }

    private var isRunning: Bool { process.state == .running }

    private var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "<name>" : trimmed
    }

    private var rejection: String? {
        PluginNameCheck.rejection(for: name, existing: existingNames)
    }
}
