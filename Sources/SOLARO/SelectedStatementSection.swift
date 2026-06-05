// ============================================================
// SelectedStatementSection.swift
// SOLARO — Inspector card mirroring the inline node editor
// ============================================================
//
// Single-click on a canvas node pushes that node onto
// `WorkspaceController.selectedNode` (see `CanvasView.onSelectNode`).
// This section reads it back, builds the same `NodeEditingSchema`
// the double-click expansion uses, and renders the fields as a
// read-only summary so the Inspector previews what an Apply-time
// edit would touch — without having to expand the node first.
//
// The schema reuses `NodeEditingSchemaFactory.infer`. Suggestions
// are irrelevant here (no pickers), so the section passes an empty
// `availableIdentifiers` list.

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
                Text("SELECTED STATEMENT")
                    .font(SolaroFont.sectionTitle)
                    .foregroundStyle(SolaroColor.textSecondary)
                    .tracking(2)
                card(schema: schema, node: node)
            }
        }
    }

    private func card(schema: any NodeEditingSchema, node: CanvasNode)
    -> some View {
        VStack(alignment: .leading, spacing: SolaroSpace.s) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(schema.title)
                    .font(SolaroFont.bodyBold)
                    .foregroundStyle(SolaroColor.textPrimary)
                Spacer(minLength: 0)
                Text("Line \(node.lineHint)")
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(SolaroColor.textTertiary)
            }
            if let subtitle = schema.subtitle {
                Text(subtitle)
                    .font(SolaroFont.caption)
                    .foregroundStyle(SolaroColor.textTertiary)
            }
            ForEach(schema.fields) { field in
                fieldRow(field)
            }
        }
        .padding(SolaroSpace.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .solaroCard()
    }

    @ViewBuilder
    private func fieldRow(_ field: EditableField) -> some View {
        switch field {
        case let .stringLiteral(_, label, value, placeholder):
            row(label: label,
                value: value.isEmpty ? placeholder : "\"\(value)\"",
                isPlaceholder: value.isEmpty)

        case let .identifier(_, label, value, _):
            row(label: label,
                value: value.isEmpty ? "—" : "<\(value)>",
                isPlaceholder: value.isEmpty)

        case let .expression(_, label, value, placeholder):
            row(label: label,
                value: value.isEmpty ? placeholder : value,
                isPlaceholder: value.isEmpty,
                monospaced: true)

        case let .picker(_, label, value, _):
            row(label: label,
                value: value.isEmpty ? "—" : value,
                isPlaceholder: value.isEmpty)

        case let .record(_, label, rows):
            VStack(alignment: .leading, spacing: 4) {
                Text(label.uppercased())
                    .font(SolaroFont.caption)
                    .tracking(1)
                    .foregroundStyle(SolaroColor.textTertiary)
                if rows.isEmpty {
                    Text("—")
                        .font(SolaroFont.monoCaption)
                        .foregroundStyle(SolaroColor.textTertiary)
                } else {
                    ForEach(rows) { r in
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(r.key + ":")
                                .font(SolaroFont.monoCaption)
                                .foregroundStyle(SolaroColor.textSecondary)
                            Text(r.value)
                                .font(SolaroFont.monoCaption)
                                .foregroundStyle(SolaroColor.textPrimary)
                                .textSelection(.enabled)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
    }

    private func row(
        label: String,
        value: String,
        isPlaceholder: Bool = false,
        monospaced: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(SolaroFont.caption)
                .tracking(1)
                .foregroundStyle(SolaroColor.textTertiary)
            Text(value)
                .font(monospaced ? SolaroFont.monoCaption : SolaroFont.body)
                .foregroundStyle(
                    isPlaceholder
                        ? SolaroColor.textTertiary
                        : SolaroColor.textPrimary
                )
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.tail)
        }
    }
}
