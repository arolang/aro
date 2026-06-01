// ============================================================
// Workspace.swift
// SOLARO — workspace shell (Phase 1 placeholder)
// ============================================================
//
// Phase 0 just confirms the shell can switch back to the welcome
// screen. Phase 1 fills this with the four-zone layout: file tree
// (left), center pane (Canvas / Text / Split / Map), inspector
// (right top), deploy rail (right bottom). See ADR-008 and the
// existing wireframes on issue #228.

import SwiftCrossUI

struct WorkspaceView: View {
    let project: Project
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("SOLARO  ·  \(project.displayName)")
                    .font(.system(.title))
                Spacer()
                Button("Close project") {
                    onClose()
                }
            }
            Text(project.rootPath.path)
                .foregroundColor(.gray)

            Text("Phase 0 placeholder")
                .foregroundColor(.gray)
                .padding(.top, 24)
            Text("The four-zone workspace shell lands in Phase 1 — file tree, text editor, inspector, deploy rail. See note 8488 ADRs on issue #228 for the architecture.")
                .foregroundColor(.gray)
        }
        .padding(32)
    }
}
