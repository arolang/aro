// ============================================================
// SOLAROApp.swift
// SOLARO — canvas-first IDE for ARO  (issue #228 Phase 0)
// ============================================================
//
// Entry point for the SOLARO desktop app. Per ADR-001 SOLARO is a
// standalone product, sibling to the `aro` CLI. Per ADR-002 it embeds
// `AROParser` and `ARORuntime` in-process — there is no subprocess
// to `aro run` from inside SOLARO.
//
// This file is intentionally tiny: it wires SwiftCrossUI's `DefaultBackend`
// (AppKit on macOS, WinUI on Windows, GTK 4 on Linux, UIKit on iPad)
// to the root view in `SOLAROApp.body`. Real UI lives in
// `Welcome.swift` and `Workspace.swift`.

import Foundation
import SwiftCrossUI
import DefaultBackend
import AROVersion

@main
struct SOLAROApp: App {

    typealias Backend = DefaultBackend

    /// Per ADR-003 the embedded `ARORuntime` is pinned per release; the
    /// version shown in the About dialog comes from `AROVersion`.
    let runtimeVersion: String = AROVersion.shortVersion

    /// Phase 0 ships only the welcome screen — single Open / Create
    /// panel per ADR-008. Project model + canvas land in Phase 1+.
    ///
    /// If the app was launched with a directory path as the first
    /// CLI argument (typically via the `solaro` launcher CLI doing
    /// `open -a SOLARO.app /path/to/project`), start directly in
    /// the open state rather than at the welcome screen.
    @State var workspace: WorkspaceState = SOLAROApp.initialWorkspace()

    var body: some Scene {
        WindowGroup("SOLARO") {
            ContentView(workspace: $workspace, runtimeVersion: runtimeVersion)
        }
        .defaultSize(width: 1400, height: 900)
    }

    /// Inspect `CommandLine.arguments` for a project path. Accepts
    /// the project as the first positional argument; ignores flag-
    /// style args (anything starting with `-`). Returns `.welcome`
    /// when no usable path is given or when the path isn't a
    /// directory.
    static func initialWorkspace() -> WorkspaceState {
        // argv[0] is the executable path; skip it.
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

/// Top-level routing between the welcome screen (no project open) and
/// the full workspace (project open). Phase 0 only renders the welcome
/// state; the workspace placeholder exists so the routing path is
/// already in place when Phase 1 fills it in.
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
