// ============================================================
// SettingsView.swift
// SOLARO — preferences (#241) — surfaced via the Settings scene
// ============================================================
//
// First-class settings panel reachable via ⌘, (the macOS-standard
// shortcut). Persists through UserDefaults via @AppStorage.

import SwiftUI
import AppKit

struct SettingsView: View {
    @AppStorage(SolaroPrefs.editorFontSize.rawValue)
    private var editorFontSize: Double = 13
    @AppStorage(SolaroPrefs.editorLineHeight.rawValue)
    private var editorLineHeight: Double = 1.25
    @AppStorage(SolaroPrefs.defaultPaneMode.rawValue)
    private var defaultPaneMode: String = PaneMode.text.rawValue
    @AppStorage(SolaroPrefs.inspectorVisible.rawValue)
    private var inspectorVisible: Bool = true
    @AppStorage(SolaroPrefs.formatOnSave.rawValue)
    private var formatOnSave: Bool = false
    @AppStorage(SolaroPrefs.aroOverride.rawValue)
    private var aroOverride: String = ""
    @AppStorage(SolaroPrefs.askEndpoint.rawValue)
    private var askEndpoint: String = ""
    @AppStorage(SolaroPrefs.theme.rawValue)
    private var theme: String = SolaroTheme.dark.rawValue

    var body: some View {
        TabView {
            editorTab
                .tabItem { Label("Editor", systemImage: "text.alignleft") }
            backendsTab
                .tabItem { Label("Backends", systemImage: "shippingbox") }
            privacyTab
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
        }
        .padding(SolaroSpace.l)
        .frame(width: 520, height: 380)
    }

    private var editorTab: some View {
        Form {
            Section {
                Picker("Theme", selection: $theme) {
                    ForEach(SolaroTheme.allCases) { t in
                        Text(t.label).tag(t.rawValue)
                    }
                }
                .onChange(of: theme) { _, new in
                    if let resolved = SolaroTheme(rawValue: new) {
                        SolaroTheme.apply(resolved)
                    }
                }
                Text("Switches the entire app between light and dark — windows, sidebars, syntax colours.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Appearance")
            }
            Section {
                HStack {
                    Text("Font size")
                    Spacer()
                    Slider(value: $editorFontSize, in: 10...22, step: 1) {
                        Text("Font size")
                    }
                    .frame(width: 220)
                    Text("\(Int(editorFontSize))pt")
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 36, alignment: .trailing)
                }
                HStack {
                    Text("Line height")
                    Spacer()
                    Slider(value: $editorLineHeight, in: 1.0...2.0, step: 0.05)
                        .frame(width: 220)
                    Text(String(format: "%.2f×", editorLineHeight))
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 50, alignment: .trailing)
                }
            } header: {
                Text("Type")
            }
            Section {
                Picker("Default pane mode", selection: $defaultPaneMode) {
                    ForEach(PaneMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                Toggle("Inspector visible by default", isOn: $inspectorVisible)
                Toggle("Format on save — strip trailing whitespace + tidy final newline",
                       isOn: $formatOnSave)
            } header: {
                Text("Defaults")
            }
        }
        .formStyle(.grouped)
    }

    private var backendsTab: some View {
        Form {
            Section {
                TextField("SOLARO_ARO", text: $aroOverride,
                          prompt: Text("/path/to/aro (overrides resolution)"))
                    .textFieldStyle(.roundedBorder)
                Text("Empty = autoresolve via repo build → /usr/local → Homebrew → $PATH.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("`aro` binary")
            }
            Section {
                TextField("ARO_ASK_ENDPOINT", text: $askEndpoint,
                          prompt: Text("https://example.com/v1 (OpenAI-compatible URL)"))
                    .textFieldStyle(.roundedBorder)
                Text("Empty = let `aro ask` pick a backend (MLX → llama-server → mlx_lm.server).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("AI · `aro ask`")
            }
        }
        .formStyle(.grouped)
    }

    private var privacyTab: some View {
        Form {
            Section {
                Label(
                    "SOLARO collects no telemetry per ADR-007 / ADR-010.",
                    systemImage: "checkmark.seal"
                )
                .foregroundStyle(.green)
                Text("Crash logs stay on disk; you decide what (if anything) to share via Help → Report a Bug.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("What SOLARO doesn't do")
            }
            Section {
                HStack {
                    Button("Reveal crash logs in Finder") {
                        NSWorkspace.shared.open(CrashReporter.crashesDirectory)
                    }
                    Spacer()
                    Button("Clear all crash logs", role: .destructive) {
                        clearCrashLogs()
                    }
                }
            } header: {
                Text("Crash logs")
            }
        }
        .formStyle(.grouped)
    }

    private func clearCrashLogs() {
        let fm = FileManager.default
        let dir = CrashReporter.crashesDirectory
        if let files = try? fm.contentsOfDirectory(at: dir,
                                                   includingPropertiesForKeys: nil) {
            for url in files {
                try? fm.removeItem(at: url)
            }
        }
    }
}

/// Centralised UserDefaults keys so callers (CenterPane,
/// AICoPilot, ConsoleProcess, …) stay in sync with the
/// SettingsView's @AppStorage names.
enum SolaroPrefs: String {
    case editorFontSize   = "solaro.editor.fontSize"
    case editorLineHeight = "solaro.editor.lineHeight"
    case defaultPaneMode  = "solaro.defaultPaneMode"
    case inspectorVisible = "solaro.inspectorVisible"
    case formatOnSave     = "solaro.formatOnSave"
    case aroOverride      = "solaro.aroOverride"
    case askEndpoint      = "solaro.askEndpoint"
    case theme            = "solaro.theme"
    case editorFolded     = "solaro.editor.folded"
    case editorMinimap    = "solaro.editor.minimap"
    case diffStyle        = "solaro.diff.style"
}
