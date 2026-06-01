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
        VStack(spacing: SolaroSpace.xl) {
            Text(project.displayName)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(SolaroColor.textPrimary)
            Text(project.rootPath.path)
                .font(SolaroFont.mono)
                .foregroundStyle(SolaroColor.textSecondary)
            Text("workspace shell — Phase 4")
                .font(SolaroFont.caption)
                .foregroundStyle(SolaroColor.textTertiary)
            Button("Close project", action: onClose)
                .keyboardShortcut("w", modifiers: [.command, .shift])
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .solaroBackdrop()
    }
}
