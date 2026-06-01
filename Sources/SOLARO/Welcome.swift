// ============================================================
// Welcome.swift
// SOLARO — first-launch welcome screen (ADR-008)
// ============================================================
//
// Per the ADR-008 decision the welcome screen is the most minimal
// possible panel: an "Open folder…" button and a "Create project…"
// button. No persona doors (ADR-009 dropped wedges). No tour
// project. Recent projects appear here once they exist, but Phase 0
// doesn't persist them yet.

import Foundation
import SwiftCrossUI

struct WelcomeView: View {
    let runtimeVersion: String
    let onOpen: (Project) -> Void

    /// Phase 0 reads recent projects from a small JSON file under the
    /// user's config dir. Empty until the user opens something.
    @State var recents: [Project] = RecentProjects.load()

    /// When the user clicks "Open folder…" we ask for a directory.
    /// SwiftCrossUI's file picker covers all backends; on macOS the
    /// AppKit backend uses NSOpenPanel under the hood. Phase 0 falls
    /// back to a manual TextField path entry if the picker is
    /// unavailable.
    @State var manualPath: String = ""
    @State var manualPathError: String?

    var body: some View {
        VStack(alignment: .center, spacing: 24) {
            Text("SOLARO")
                .font(.system(.title))
            Text("canvas-first IDE for ARO  ·  runtime \(runtimeVersion)")
                .foregroundColor(.gray)

            HStack(spacing: 16) {
                Button("Open folder…") {
                    presentOpenFolderDialog()
                }
                Button("Create project…") {
                    presentCreateProjectDialog()
                }
            }

            // Manual fallback for environments without a working
            // file picker (Linux GTK headless, CI).
            VStack(alignment: .leading, spacing: 4) {
                Text("…or paste a project path:")
                    .foregroundColor(.gray)
                HStack {
                    TextField("/path/to/MyApp", text: $manualPath)
                    Button("Open") {
                        openManualPath()
                    }
                }
                if let manualPathError {
                    Text(manualPathError).foregroundColor(.red)
                }
            }
            .padding(.top, 16)

            if !recents.isEmpty {
                Text("Recent projects")
                    .foregroundColor(.gray)
                    .padding(.top, 24)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(recents) { project in
                        Button(project.displayName) {
                            onOpen(project)
                        }
                    }
                }
            }
        }
        .padding(48)
    }

    // MARK: - Open / Create handlers

    private func presentOpenFolderDialog() {
        // Phase 0: native folder picker via SwiftCrossUI is backend-
        // dependent and not all backends expose it. For now we leave
        // the manual path entry as the primary path; Phase 1 wires
        // the native picker per backend.
        manualPathError = "Native folder picker lands in Phase 1 — paste a path below."
    }

    private func presentCreateProjectDialog() {
        // Phase 0: project creation needs a template scaffolder.
        // ADR-009 dropped the persona-templated scaffolds, so this is
        // just "make an empty directory + Application-Start" — but
        // the dialog UX still needs designing. Deferred to Phase 1.
        manualPathError = "Create-project dialog lands in Phase 1."
    }

    private func openManualPath() {
        manualPathError = nil
        let trimmed = manualPath.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let url = URL(fileURLWithPath: trimmed)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            manualPathError = "Not a directory: \(trimmed)"
            return
        }
        let project = Project(rootPath: url)
        RecentProjects.remember(project)
        onOpen(project)
    }
}
