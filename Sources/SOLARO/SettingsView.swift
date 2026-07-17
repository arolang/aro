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
    @AppStorage(SolaroPrefs.editorGhostText.rawValue)
    private var editorGhostText: Bool = false
    @AppStorage(SolaroPrefs.editorGhostDelay.rawValue)
    private var editorGhostDelay: Double = 0.75
    @AppStorage(SolaroPrefs.editorAIFallback.rawValue)
    private var editorAIFallback: Bool = false
    @AppStorage(SolaroPrefs.aroOverride.rawValue)
    private var aroOverride: String = ""
    @AppStorage(SolaroPrefs.runtimeBackend.rawValue)
    private var runtimeBackend: String = RuntimeBackend.embedded.rawValue
    @AppStorage(SolaroPrefs.askEndpoint.rawValue)
    private var askEndpoint: String = ""
    /// Optional GitHub Personal Access Token used by the plugin
    /// marketplace fetcher (#263). When set, the rate limit on
    /// `api.github.com/search/repositories` rises from 60 to
    /// 5000 requests/hour — useful when several developers
    /// share an IP.
    @AppStorage(GitHubMarketplaceFetcher.patDefaultsKey)
    private var githubPAT: String = ""
    @AppStorage(SolaroPrefs.theme.rawValue)
    private var theme: String = SolaroTheme.dark.rawValue
    @AppStorage(SolaroPrefs.metricsHistoryDepth.rawValue)
    private var metricsHistoryDepth: Int = MetricsRunHistory.defaultDepth

    var body: some View {
        TabView {
            editorTab
                .tabItem { Label("Editor", systemImage: "text.alignleft") }
            backendsTab
                .tabItem { Label("Backends", systemImage: "shippingbox") }
            KeybindingsSettingsTab()
                .tabItem { Label("Keybindings", systemImage: "keyboard") }
            BooksSettingsTab()
                .tabItem { Label("Books", systemImage: "books.vertical") }
            privacyTab
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
        }
        .padding(SolaroSpace.l)
        .frame(width: 560, height: 520)
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
                Toggle("Inline suggestions — show LSP completions as you type (⇥ to enter)",
                       isOn: $editorGhostText)
                HStack {
                    Text("Suggestion delay")
                    Spacer()
                    Slider(value: $editorGhostDelay, in: 0.2...3.0, step: 0.05)
                        .frame(width: 200)
                        .disabled(!editorGhostText)
                    Text(String(format: "%.2f s", editorGhostDelay))
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 56, alignment: .trailing)
                        .foregroundStyle(editorGhostText ? .primary : .secondary)
                }
                Toggle("AI fallback — after the popover sits open, also ask `aro ask` for a prediction (slower)",
                       isOn: $editorAIFallback)
                    .disabled(!editorGhostText)
            } header: {
                Text("Defaults")
            }
        }
        .formStyle(.grouped)
    }

    private var backendsTab: some View {
        Form {
            Section {
                Picker("Runtime", selection: $runtimeBackend) {
                    ForEach(RuntimeBackend.allCases) { backend in
                        Text(backend.label).tag(backend.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)
                if let resolved = RuntimeBackend(rawValue: runtimeBackend) {
                    Text(resolved.blurb)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Applies to the next Run. Already-running processes keep their current backend.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } header: {
                Text("Runtime backend")
            }
            Section {
                TextField("SOLARO_ARO", text: $aroOverride,
                          prompt: Text("/path/to/aro (overrides resolution)"))
                    .textFieldStyle(.roundedBorder)
                Text("Empty = autoresolve via repo build → /usr/local → Homebrew → $PATH.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("External `aro` binary")
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
            Section {
                SecureField("GitHub PAT", text: $githubPAT,
                            prompt: Text("ghp_… (optional)"))
                    .textFieldStyle(.roundedBorder)
                Text("Optional token used by the plugin marketplace to query `topic:aro topic:plugin` on api.github.com. Raises the rate limit from 60 to 5000 requests / hour. Stored in this user's defaults — leave empty for unauthenticated requests.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Plugin marketplace")
            }
            Section {
                Stepper(value: $metricsHistoryDepth, in: 1...100) {
                    HStack {
                        Text("Run history depth")
                        Spacer()
                        Text("\(metricsHistoryDepth) runs")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                Text("How many past runs the Metrics panel keeps for ◂ ▸ navigation. Older runs fall off the back. Applies from the next Run.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Metrics")
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
    case editorGhostText  = "solaro.editor.ghostText"
    case editorGhostDelay = "solaro.editor.ghostDelay"
    case editorAIFallback = "solaro.editor.aiFallback"
    case runtimeBackend   = "solaro.runtimeBackend"
    case filesTabMode     = "solaro.filesTabMode"
    case metricsHistoryDepth = "solaro.metrics.historyDepth"
}

/// Which runtime drives the green Play button. The embedded path
/// links ARORuntime in-process and gives the canvas live pulses +
/// inline values for free; the external path shells out to a
/// standalone `aro` and is what every prior release shipped.
enum RuntimeBackend: String, CaseIterable, Identifiable {
    case embedded
    case xpc
    case external

    var id: String { rawValue }

    var label: String {
        switch self {
        case .embedded: return "Embedded (in-process)"
        case .xpc:      return "Isolated (XPC service)"
        case .external: return "External `aro` subprocess"
        }
    }

    var blurb: String {
        switch self {
        case .embedded:
            return "Runs the project inside SOLARO. Statement-level events feed the canvas pulse and inline values directly; no subprocess, no JSONL round-trip."
        case .xpc:
            return "Runs the project in the AROXPCService child process. A crash in user code or a plugin terminates the service — SOLARO keeps every buffer and offers to re-launch. Adds ~50 µs per checkpoint over the embedded path."
        case .external:
            return "Spawns the configured `aro` binary. Matches every previous release. Statement-level pulses only fire under `aro debug`; plain `aro run` produces no live events."
        }
    }

    /// Resolution order:
    /// 1. The explicit user preference (Settings → Backends).
    /// 2. `SOLARO_EMBEDDED_RUNTIME=1` env var (legacy override).
    /// 3. Default: embedded.
    static var current: RuntimeBackend {
        let raw = UserDefaults.standard
            .string(forKey: SolaroPrefs.runtimeBackend.rawValue)
        if let raw, let parsed = RuntimeBackend(rawValue: raw) {
            return parsed
        }
        if ProcessInfo.processInfo.environment["SOLARO_EMBEDDED_RUNTIME"] == "1" {
            return .embedded
        }
        return .embedded
    }
}
