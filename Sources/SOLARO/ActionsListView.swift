// ============================================================
// ActionsListView.swift
// SOLARO — Right-pane Actions tab content
// ============================================================
//
// Renders every action (built-in + plugin) reported by
// `aro actions`, grouped by semantic role. Each row is a drag
// source carrying a one-line ARO statement template — drop into
// the source editor and you get a placeholder statement at the
// cursor.

import SwiftUI

struct ActionsListView: View {
    @Bindable var registry: ActionsRegistry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(SolaroColor.divider)
            content
        }
    }

    private var header: some View {
        HStack(spacing: SolaroSpace.xs) {
            Image(systemName: "puzzlepiece.fill")
                .foregroundStyle(SolaroColor.accent)
            Text("ACTIONS")
                .font(SolaroFont.sectionTitle)
                .foregroundStyle(SolaroColor.textSecondary)
                .tracking(2)
            Spacer()
            if registry.isLoading {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.horizontal, SolaroSpace.m)
        .padding(.vertical, SolaroSpace.s)
    }

    @ViewBuilder
    private var content: some View {
        if let error = registry.lastError {
            VStack(alignment: .leading, spacing: SolaroSpace.s) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(SolaroColor.stateError)
                Text("Could not list actions:")
                    .font(SolaroFont.caption)
                    .foregroundStyle(SolaroColor.textSecondary)
                Text(error)
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(SolaroColor.stateError)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(SolaroSpace.m)
        } else if registry.actions.isEmpty {
            VStack(alignment: .leading, spacing: SolaroSpace.xs) {
                Text("No actions loaded.")
                    .font(SolaroFont.caption)
                    .foregroundStyle(SolaroColor.textTertiary)
            }
            .padding(SolaroSpace.m)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: SolaroSpace.s, pinnedViews: [.sectionHeaders]) {
                    let grouped = Dictionary(grouping: registry.actions, by: { $0.role })
                    let roleOrder = grouped.keys.sorted { $0.sortKey < $1.sortKey }
                    ForEach(roleOrder, id: \.self) { role in
                        Section(header: roleHeader(role)) {
                            ForEach(grouped[role] ?? []) { action in
                                ActionRowView(action: action)
                            }
                        }
                    }
                }
                .padding(.bottom, SolaroSpace.m)
            }
        }
    }

    private func roleHeader(_ role: ActionInfo.Role) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "circle.fill")
                .resizable()
                .frame(width: 6, height: 6)
                .foregroundStyle(roleColor(role))
            Text(role.label)
                .font(SolaroFont.sectionTitle)
                .foregroundStyle(SolaroColor.textSecondary)
                .tracking(2)
            Spacer()
        }
        .padding(.horizontal, SolaroSpace.m)
        .padding(.vertical, SolaroSpace.xs)
        .background(SolaroColor.surface.opacity(0.95))
    }

    private func roleColor(_ role: ActionInfo.Role) -> Color {
        switch role {
        case .request:  return SolaroColor.roleRequest
        case .own:      return SolaroColor.roleOwn
        case .response: return SolaroColor.roleResponse
        case .export:   return SolaroColor.roleExport
        case .server:   return SolaroColor.accent
        case .unknown:  return SolaroColor.textTertiary
        }
    }
}

private struct ActionRowView: View {
    let action: ActionInfo
    @State private var hovering = false

    var body: some View {
        HStack(spacing: SolaroSpace.s) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10))
                .foregroundStyle(SolaroColor.textTertiary)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(action.verb)
                        .font(SolaroFont.bodyBold)
                        .foregroundStyle(roleColor(action.role))
                    if action.isPlugin {
                        Text("plugin")
                            .font(SolaroFont.caption)
                            .foregroundStyle(SolaroColor.textTertiary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(SolaroColor.divider)
                            .clipShape(Capsule())
                    }
                    Spacer()
                }
                if !action.prepositions.isEmpty {
                    Text(action.prepositions.joined(separator: ", "))
                        .font(SolaroFont.monoCaption)
                        .foregroundStyle(SolaroColor.textTertiary)
                }
            }
        }
        .padding(.horizontal, SolaroSpace.m)
        .padding(.vertical, 4)
        .background(
            Rectangle()
                .fill(hovering ? SolaroColor.selection.opacity(0.35) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help("Drag into the editor or canvas to insert:\n\(action.statementTemplate)")
        // Drag payload: the statement template. NSTextView accepts
        // string drops natively, so dropping into the source editor
        // inserts it at the cursor.
        .onDrag {
            NSItemProvider(object: action.statementTemplate as NSString)
        }
    }

    private func roleColor(_ role: ActionInfo.Role) -> Color {
        switch role {
        case .request:  return SolaroColor.roleRequest
        case .own:      return SolaroColor.roleOwn
        case .response: return SolaroColor.roleResponse
        case .export:   return SolaroColor.roleExport
        case .server:   return SolaroColor.accent
        case .unknown:  return SolaroColor.textTertiary
        }
    }
}
