// ============================================================
// Workspace.swift
// SOLARO — four-zone workspace shell (Phase 1)
// ============================================================
//
// The four-zone layout from the wireframes (note 8467 on issue #228):
//
//   ┌──────────────────────────────────────────────┐
//   │ titlebar · breadcrumb · pane mode toggle     │
//   ├────────────┬───────────────────────┬─────────┤
//   │ file tree  │ center pane           │ inspect │
//   │            │  (Text / Canvas /     │         │
//   │            │   Split / Map)        │ ───────│
//   │            │                       │ deploy │
//   │            │                       │ rail   │
//   └────────────┴───────────────────────┴─────────┘
//
// Phase 1 puts a plain text editor in the center pane and the
// AST inspector in the right rail. Canvas / Split / Map come in
// Phase 2+.

import Foundation
import SwiftCrossUI
import AROVersion

struct WorkspaceView: View {
    let project: Project
    let onClose: () -> Void

    @State var model: ProjectModel?
    @State var currentFile: SourceFileState?
    @State var paneMode: PaneMode = .text
    @State var loadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Top bar — breadcrumb + pane mode toggle + close
            HStack {
                Text("SOLARO  ·  \(project.displayName)")
                    .font(.system(.title))
                Spacer()
                paneModeToggle
                Spacer()
                Button("Close project") {
                    onClose()
                }
            }
            .padding(.bottom, 8)

            // Three columns: file tree | center pane | inspector
            HStack(alignment: .top, spacing: 12) {
                FileTreePane(
                    model: model,
                    currentFile: currentFile,
                    onSelect: openFile(_:)
                )
                CenterPane(
                    file: currentFile,
                    paneMode: paneMode
                )
                InspectorPane(
                    file: currentFile,
                    runtimeVersion: AROVersion.shortVersion
                )
            }

            if let loadError {
                Text(loadError).foregroundColor(.red).padding(.top, 8)
            }
        }
        .padding(16)
        .onAppear {
            loadProject()
        }
    }

    // MARK: - Pane-mode toggle

    @ViewBuilder
    private var paneModeToggle: some View {
        HStack(spacing: 4) {
            ForEach(PaneMode.allCases, id: \.self) { mode in
                Button(mode.label) {
                    setPaneMode(mode)
                }
            }
        }
    }

    private func setPaneMode(_ mode: PaneMode) {
        paneMode = mode
        if let f = currentFile {
            var layout = f.layout
            layout.paneMode = mode
            f.layout = layout
            try? layout.save(for: f.url)
        }
    }

    // MARK: - Actions

    private func loadProject() {
        do {
            let loaded = try ProjectModel.load(project)
            self.model = loaded
            if let first = loaded.sourceFiles.first {
                openFile(first)
            }
            RecentProjects.remember(project)
        } catch {
            loadError = "Failed to load project: \(error.localizedDescription)"
        }
    }

    private func openFile(_ url: URL) {
        let state = SourceFileState(url: url)
        self.currentFile = state
        self.paneMode = state.layout.paneMode
    }
}
