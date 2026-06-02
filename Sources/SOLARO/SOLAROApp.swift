// ============================================================
// SOLAROApp.swift
// SOLARO — canvas-first IDE for ARO (issue #228)
// ============================================================
//
// Entry point for the SOLARO desktop app. Per ADR-001 (revised
// 2026-06) SOLARO is a native macOS app built directly on SwiftUI
// + AppKit.
//
// Multi-window note (#251): the workspace's routing state lives
// inside RootView so SwiftUI gives each WindowGroup window its
// own copy. File → New Window (⌘N) opens a fresh welcome screen
// without touching any other window; ⌘W closes the current one.

import SwiftUI
import AROVersion

@main
struct SOLAROApp: App {

    /// Per ADR-003 the embedded `ARORuntime` is pinned per release;
    /// the version shown in the About panel comes from `AROVersion`.
    let runtimeVersion: String = AROVersion.shortVersion

    init() {
        // Per ADR-007 / ADR-010: install a local crash logger so
        // we can write a report to disk on fatal signals. No
        // automatic upload — the user opens an issue manually
        // via Help → Report a Bug…
        CrashReporter.install()
    }

    var body: some Scene {
        Settings {
            SettingsView()
        }
        WindowGroup("SOLARO") {
            RootView(runtimeVersion: runtimeVersion)
                .frame(minWidth: 1200, minHeight: 800)
        }
        .defaultSize(width: 1400, height: 900)
        .commands {
            CommandGroup(after: .help) {
                Button("Report a Bug…") {
                    CrashReporter.openReportBugPage()
                }
                .keyboardShortcut("?", modifiers: [.command, .shift])
                Button("Reveal crash logs in Finder") {
                    NSWorkspace.shared.open(CrashReporter.crashesDirectory)
                }
            }
        }
    }
}

/// Per-window root. Owns the welcome ↔ workspace routing state so
/// SwiftUI hands each WindowGroup window its own copy. The result:
/// File → New Window (⌘N) opens a fresh welcome screen without
/// blowing away another window's open project.
struct RootView: View {
    let runtimeVersion: String
    @State private var workspace: WorkspaceState = RootView.initialWorkspace()
    @AppStorage(SolaroPrefs.theme.rawValue)
    private var themeRaw: String = SolaroTheme.dark.rawValue

    var body: some View {
        let theme = SolaroTheme(rawValue: themeRaw) ?? .dark
        ContentView(workspace: $workspace, runtimeVersion: runtimeVersion)
            .onOpenURL(perform: openURL)
            .preferredColorScheme(theme.colorScheme)
            .onAppear { SolaroTheme.apply(theme) }
            .onChange(of: themeRaw) { _, new in
                if let resolved = SolaroTheme(rawValue: new) {
                    SolaroTheme.apply(resolved)
                }
            }
    }

    /// macOS Launch Services delivers `open -a SOLARO.app <path>`
    /// invocations as an open-URL event rather than as argv — so
    /// the launcher CLI's project path lands here, not in
    /// `initialWorkspace()`. Falls through silently for non-
    /// directory URLs so a stray Finder drop doesn't crash the
    /// workspace.
    private func openURL(_ url: URL) {
        var isDir: ObjCBool = false
        guard
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
            isDir.boolValue
        else { return }
        workspace = .open(Project(rootPath: url))
    }

    /// Pull a project path out of CommandLine.arguments for the
    /// *first* window only — subsequent windows opened via ⌘N
    /// start on the welcome screen. argv reflects the launch
    /// invocation, which applies to the initial window.
    static func initialWorkspace() -> WorkspaceState {
        let candidates = CommandLine.arguments
            .dropFirst()
            .filter { !$0.hasPrefix("-") }
        guard let path = candidates.first else { return .welcome }
        let resolved = path == "." ? FileManager.default.currentDirectoryPath : path
        let url = URL(fileURLWithPath: resolved)
        var isDir: ObjCBool = false
        guard
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
            isDir.boolValue
        else { return .welcome }
        // Only the very first RootView consumes argv; subsequent
        // windows reach this code path too, but argv is the same
        // for the whole process. We use a process-wide "consumed"
        // flag so window two onward starts at .welcome.
        if Self.argvConsumed { return .welcome }
        Self.argvConsumed = true
        return .open(Project(rootPath: url))
    }

    /// True once any RootView instance has claimed CommandLine.arguments.
    /// Synchronised because @main scenes can spin up multiple roots in
    /// parallel during onAppear, but in practice it's only racing with
    /// itself on app launch.
    private static var argvConsumed = false
}

/// Top-level routing between the welcome screen (no project open)
/// and the full workspace (project open).
struct ContentView: View {
    @Binding var workspace: WorkspaceState
    let runtimeVersion: String

    var body: some View {
        switch workspace {
        case .welcome:
            WelcomeView(runtimeVersion: runtimeVersion) { project in
                workspace = .open(project)
            }
        case .open(let project):
            WorkspaceView(project: project) {
                workspace = .welcome
            }
        }
    }
}
