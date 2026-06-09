// ============================================================
// SelectedStatementSection.swift
// SOLARO — Inspector card mirroring the inline node editor
// ============================================================
//
// Single-click on a canvas node pushes that node onto
// `WorkspaceController.selectedNode` (see `CanvasView.onSelectNode`).
// This section reads it back, builds the same `NodeEditingSchema`
// the double-click expansion uses, and renders an editable form
// — the user can Apply changes here instead of having to expand
// the node first. Apply writes through the same path the canvas
// uses (see `WorkspaceController.nodeEditApply`).

import SwiftUI
import AROParser

struct SelectedStatementSection: View {
    @Bindable var controller: WorkspaceController

    var body: some View {
        if let node = controller.selectedNode {
            let schema = NodeEditingSchemaFactory.infer(
                node: node,
                statementSource: controller.selectedNodeSource ?? node.summary,
                availableIdentifiers: []
            )
            VStack(alignment: .leading, spacing: SolaroSpace.s) {
                HStack {
                    Text("SELECTED STATEMENT")
                        .font(SolaroFont.sectionTitle)
                        .foregroundStyle(SolaroColor.textSecondary)
                        .tracking(2)
                    Spacer()
                    Text("Line \(node.lineHint)")
                        .font(SolaroFont.monoCaption)
                        .foregroundStyle(SolaroColor.textTertiary)
                }
                // The form uses the same NodeEditorView the canvas
                // pops up on double-click, so Apply hits the same
                // save pipeline. Identity by `node.id` so SwiftUI
                // resets the editor's internal @State whenever the
                // user picks a different node.
                NodeEditorView(
                    schema: schema,
                    onApply: { newText in
                        controller.nodeEditApply?(node.id, newText)
                    },
                    onCancel: {
                        controller.selectedNode = nil
                        controller.selectedNodeSource = nil
                    }
                )
                .id(node.id)
            }
        }
    }
}
