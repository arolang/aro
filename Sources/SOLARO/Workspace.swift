// ============================================================
// Workspace.swift
// SOLARO — workspace shell (post-pivot)
// ============================================================
//
// Phase 1 stub: shows the project name and a Close button.
// Phase 4 brings the full NavigationSplitView with toolbar.

import SwiftUI

struct WorkspaceView: View {
    let project: Project
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Text(project.displayName)
                .font(.system(size: 28, weight: .semibold))
            Text(project.rootPath.path)
                .foregroundStyle(.secondary)
                .font(.system(.body, design: .monospaced))
            Text("workspace shell — Phase 4")
                .foregroundStyle(.tertiary)
            Button("Close project", action: onClose)
                .keyboardShortcut("w", modifiers: [.command, .shift])
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.95))
    }
}
