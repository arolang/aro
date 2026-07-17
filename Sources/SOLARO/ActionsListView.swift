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
import ARORuntime

struct ActionsListView: View {
    @Bindable var registry: ActionsRegistry
    /// Forwarded to each row so the hover hint can ask `aro ask`
    /// for a context-aware suggestion and read the currently-open
    /// file's bindings. Optional because the right pane can render
    /// before a workspace is fully loaded.
    var controller: WorkspaceController?
    @State private var searchQuery = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(SolaroColor.divider)
            if registry.lastError == nil && !registry.actions.isEmpty {
                searchField
                Divider().background(SolaroColor.divider)
            }
            content
        }
    }

    /// Actions matching the search query by verb or by the catalog
    /// description shown in the row tooltip. Empty query passes
    /// everything through untouched.
    private var filteredActions: [ActionInfo] {
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return registry.actions }
        return registry.actions.filter { action in
            if action.verb.localizedCaseInsensitiveContains(query) {
                return true
            }
            if let desc = AROCatalogDescriptions.action(named: action.verb),
               desc.localizedCaseInsensitiveContains(query) {
                return true
            }
            return false
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(SolaroColor.textTertiary)
                .font(.system(size: 11))
            TextField("Filter by name or description", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(SolaroFont.body)
            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(SolaroColor.textTertiary)
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("Clear filter")
            }
        }
        .padding(.horizontal, SolaroSpace.m)
        .padding(.vertical, 6)
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
        } else if filteredActions.isEmpty {
            VStack(alignment: .leading, spacing: SolaroSpace.xs) {
                Text("No actions match \u{201C}\(searchQuery)\u{201D}.")
                    .font(SolaroFont.caption)
                    .foregroundStyle(SolaroColor.textTertiary)
            }
            .padding(SolaroSpace.m)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: SolaroSpace.s, pinnedViews: [.sectionHeaders]) {
                    let grouped = Dictionary(grouping: filteredActions, by: { $0.role })
                    let roleOrder = grouped.keys.sorted { $0.sortKey < $1.sortKey }
                    ForEach(roleOrder, id: \.self) { role in
                        Section(header: roleHeader(role)) {
                            ForEach(grouped[role] ?? []) { action in
                                ActionRowView(
                                    action: action,
                                    controller: controller)
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
    let controller: WorkspaceController?
    @State private var hovering = false
    /// Latest `aro ask` reply for this verb against the currently-
    /// open file. Populated by a dwell-triggered fetch; surfaced
    /// in the system tooltip text below the generic template.
    @State private var aiSuggestion: String?
    /// Cancellable dwell timer. macOS fires `.onHover(true)` the
    /// moment the cursor enters; we wait ~500ms before spawning
    /// `aro ask` so a scroll-past doesn't kick a process per row.
    @State private var dwellTask: Task<Void, Never>?

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
        .onHover { isHovering in
            hovering = isHovering
            dwellTask?.cancel()
            if isHovering {
                dwellTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if !Task.isCancelled { fetchSuggestionIfNeeded() }
                }
            }
        }
        .help(tooltipText)
        // Drag payload: the statement template. NSTextView accepts
        // string drops natively, so dropping into the source editor
        // inserts it at the cursor.
        .onDrag {
            NSItemProvider(object: action.statementTemplate as NSString)
        }
    }

    /// Multi-line tooltip text: action description (from the
    /// runtime catalog), the generic template that gets dropped,
    /// and — once `aro ask` responds — a contextually-aware
    /// suggestion that uses bindings already in the open file.
    private var tooltipText: String {
        var parts: [String] = []
        if let desc = AROCatalogDescriptions.action(named: action.verb),
           !desc.isEmpty
        {
            parts.append("\(action.verb) — \(desc)")
            parts.append("")
        }
        parts.append("Drag into the editor or canvas to insert:")
        parts.append(action.statementTemplate)
        if let ai = aiSuggestion, !ai.isEmpty,
           ai.trimmingCharacters(in: .whitespaces) != action.statementTemplate
        {
            parts.append("")
            parts.append("Suggested for the open file:")
            parts.append(ai)
        }
        return parts.joined(separator: "\n")
    }

    /// Spawn `aro ask` for a tailored statement, but only when we
    /// have a project + open file + no cached answer yet. The
    /// suggester memoises by (verb, source-hash) so a re-hover
    /// after the model returns is free.
    private func fetchSuggestionIfNeeded() {
        guard aiSuggestion == nil,
              let controller,
              let url = controller.currentFile,
              let model = controller.model
        else { return }
        ActionSuggester.suggest(
            verb: action.verb,
            template: action.statementTemplate,
            sourceURL: url,
            project: model.root
        ) { suggestion in
            aiSuggestion = suggestion
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
