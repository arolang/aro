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

import AppKit
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
        // AppKit calls `_crashOnException` for any NSException raised
        // during the display cycle (e.g. Auto Layout contradictions
        // inside NavigationSplitView when the window is dragged below
        // the columns' implicit minima). The exception is recoverable
        // for our purposes — the next layout pass succeeds — so we
        // keep the app alive instead of trapping. The exception still
        // logs to stderr so we can see it during development.
        UserDefaults.standard.set(false, forKey: "NSApplicationCrashOnExceptions")
    }

    var body: some Scene {
        Settings {
            SettingsView()
        }
        WindowGroup("Solaro") {
            RootView(runtimeVersion: runtimeVersion)
        }
        .defaultSize(width: 1400, height: 900)
        .commands {
            CommandGroup(after: .toolbar) {
                Divider()
                Button("Internal Logs…") {
                    InternalLogsWindow.show()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift, .option])
            }
            CommandGroup(after: .help) {
                Button("Language Guide…") {
                    LanguageGuideWindow.show()
                }
                .keyboardShortcut("?", modifiers: [.command])
                Divider()
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

    /// macOS Launch Services delivers `open -a Solaro.app <path>`
    /// invocations as an open-URL event rather than as argv. Two
    /// shapes land here now (#277):
    ///   * a directory URL — open it as the project root
    ///   * an .aro file URL — open the *containing* directory and
    ///     focus the file in the editor
    ///   * a solaro://… deep link — for future use, ignored for now
    private func openURL(_ url: URL) {
        // Deep links (solaro://foo) — keep a stub so they don't
        // crash. Real handlers can grow here later.
        if url.scheme == "solaro" { return }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return
        }
        if isDir.boolValue {
            workspace = .open(Project(rootPath: url))
            return
        }
        // File URL — open its enclosing directory as the project
        // and queue a deep link so the workspace can focus the
        // file once the project loads.
        let parent = url.deletingLastPathComponent()
        let project = Project(rootPath: parent)
        workspace = .open(project)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NotificationCenter.default.post(
                name: .solaroFocusFile, object: nil,
                userInfo: ["url": url]
            )
        }
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

/// Notification name used to ask a workspace to focus a file
/// after the project has finished loading (#277).
extension Notification.Name {
    static let solaroFocusFile = Notification.Name("solaroFocusFile")
}

/// Top-level routing between the welcome screen (no project open)
/// and the full workspace (project open).
///
/// Welcome is only shown when **no other window already has a project
/// open** — the canvas IDE is the meaningful entry point once you have
/// one running, and a second welcome window over it just gets in the
/// way. Per-window state still drives the actual switch; we only use
/// the global count to close redundant welcome windows.
struct ContentView: View {
    @Binding var workspace: WorkspaceState
    let runtimeVersion: String

    var body: some View {
        switch workspace {
        case .welcome:
            WelcomeView(runtimeVersion: runtimeVersion) { project in
                workspace = .open(project)
            }
            .onAppear { closeIfRedundantWelcome() }
        case .open(let project):
            WorkspaceView(project: project) {
                workspace = .welcome
            }
            .onAppear { OpenWorkspaceTracker.shared.increment() }
            .onDisappear { OpenWorkspaceTracker.shared.decrement() }
        }
    }

    /// If at least one other window already has a project workspace
    /// open, this window's welcome screen is a duplicate. Close it
    /// on next runloop tick so the user lands back on the live IDE
    /// rather than on the static welcome.
    private func closeIfRedundantWelcome() {
        guard OpenWorkspaceTracker.shared.count > 0 else { return }
        DispatchQueue.main.async {
            // Walk every window owned by the app and close the one
            // hosting *this* SwiftUI view. We can't grab `self`'s
            // hosting NSWindow directly from a struct View, but the
            // welcome screen is always the front-most window when it
            // just appeared.
            if let win = NSApp.windows.first(where: { $0.isVisible && $0.title == "Solaro" }) {
                win.close()
            } else {
                NSApp.keyWindow?.close()
            }
        }
    }
}

/// Process-wide count of windows whose `workspace` is `.open(...)`.
/// `ContentView` increments/decrements as project workspaces appear
/// and disappear; the welcome-screen routing checks this to decide
/// whether to render or auto-close.
@MainActor
final class OpenWorkspaceTracker {
    static let shared = OpenWorkspaceTracker()
    private init() {}
    private(set) var count: Int = 0
    func increment() { count += 1 }
    func decrement() { count = max(0, count - 1) }
}

// Per-window minimum size is enforced by `WorkspaceWindowSizer` in
// Workspace.swift — it adapts the floor to which panels are shown.
