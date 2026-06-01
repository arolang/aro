// ============================================================
// SOLAROApp.swift
// SOLARO — canvas-first IDE for ARO (issue #228)
// ============================================================
//
// Entry point for the SOLARO desktop app. Per ADR-001 (revised
// 2026-06) SOLARO is a native macOS app built directly on SwiftUI
// + AppKit. The earlier SwiftCrossUI cross-platform approach was
// dropped because SwiftCrossUI v0.6's widget set couldn't render
// the wireframes' visual style — no theming primitives, no
// segmented controls, no real splitters, no asset catalog.
//
// Linux and Windows SOLARO builds may return later (the design
// is still portable in spirit) but for now this is macOS-only.
//
// Per ADR-002 the embedded `ARORuntime` runs in-process — there
// is no subprocess to `aro run`.

import SwiftUI
import AROVersion

@main
struct SOLAROApp: App {

    /// Per ADR-003 the embedded `ARORuntime` is pinned per release;
    /// the version shown in the About panel comes from `AROVersion`.
    let runtimeVersion: String = AROVersion.shortVersion

    /// If the app was launched with a directory path as the first
    /// CLI argument (typically via the `solaro` launcher CLI doing
    /// `open -a SOLARO.app /path/to/project`), start directly in
    /// the open workspace; otherwise show the welcome screen.
    @State private var workspace: WorkspaceState = SOLAROApp.initialWorkspace()

    var body: some Scene {
        WindowGroup("SOLARO") {
            ContentView(workspace: $workspace, runtimeVersion: runtimeVersion)
                .frame(minWidth: 1200, minHeight: 800)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1400, height: 900)
    }

    /// Inspect `CommandLine.arguments` for a project path. Accepts
    /// the project as the first positional argument; ignores flag-
    /// style args (anything starting with `-`). Returns `.welcome`
    /// when no usable path is given or when the path isn't a
    /// directory.
    static func initialWorkspace() -> WorkspaceState {
        let candidates = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        guard let path = candidates.first else { return .welcome }
        let resolved = path == "." ? FileManager.default.currentDirectoryPath : path
        let url = URL(fileURLWithPath: resolved)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              isDir.boolValue else {
            return .welcome
        }
        return .open(Project(rootPath: url))
    }
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
