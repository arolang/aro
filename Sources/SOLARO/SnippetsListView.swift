// ============================================================
// SnippetsListView.swift
// SOLARO — Right-pane Snippets tab content (#242)
// ============================================================
//
// Sibling of ActionsListView. Where that tab drags one statement,
// this one drags whole patterns: a route triple, an emit + handler
// pair, an observer skeleton. Rows are drag sources carrying the
// expanded body (placeholder wrappers already stripped), so the
// editor's native string drop and the canvas's action-drop path
// both work without knowing anything about snippets.
//
// The project's own snippets come first — a team that defines
// `.solaro/snippets/house.yaml` means it, and one of the reasons
// to define one is to override a shipped pattern.

import SwiftUI
import AppKit

struct SnippetsListView: View {
    @Bindable var library: SnippetLibrary
    /// Root of the open project, used for the "create a snippets
    /// file" affordance. Nil before a project finishes loading.
    var projectRoot: URL?
    /// Inserts a snippet at the editor caret. Supplied by
    /// CenterPane, which owns the buffer + caret plumbing; nil when
    /// no file is open, which is why the row's button disables.
    var insertAtCaret: ((AROSnippet) -> Void)?

    @State private var searchQuery = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(SolaroColor.divider)
            searchField
            Divider().background(SolaroColor.divider)
            content
            if let error = library.loadError {
                Divider().background(SolaroColor.divider)
                errorFooter(error)
            }
            Divider().background(SolaroColor.divider)
            footer
        }
    }

    /// Snippets matching the query by name, summary, trigger, or
    /// body text. Body matches earn their keep: "how did we spell
    /// the observer's changeType extract again" is a body search.
    private var filtered: [AROSnippet] {
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return library.all }
        return library.all.filter { snippet in
            snippet.name.localizedCaseInsensitiveContains(query)
                || snippet.summary.localizedCaseInsensitiveContains(query)
                || snippet.trigger.localizedCaseInsensitiveContains(query)
                || snippet.body.localizedCaseInsensitiveContains(query)
        }
    }

    private var header: some View {
        HStack(spacing: SolaroSpace.xs) {
            Image(systemName: "curlybraces")
                .foregroundStyle(SolaroColor.accent)
            Text("SNIPPETS")
                .font(SolaroFont.sectionTitle)
                .foregroundStyle(SolaroColor.textSecondary)
                .tracking(2)
            Spacer()
            Button {
                library.reload(projectRoot: projectRoot)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10))
            }
            .buttonStyle(.borderless)
            .help("Re-read \(SnippetLibrary.customDirectory)")
        }
        .padding(.horizontal, SolaroSpace.m)
        .padding(.vertical, SolaroSpace.s)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(SolaroColor.textTertiary)
                .font(.system(size: 11))
            TextField("Filter by name, trigger, or body", text: $searchQuery)
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

    @ViewBuilder
    private var content: some View {
        if filtered.isEmpty {
            VStack(alignment: .leading, spacing: SolaroSpace.xs) {
                Text(searchQuery.isEmpty
                     ? "No snippets."
                     : "No snippets match \u{201C}\(searchQuery)\u{201D}.")
                    .font(SolaroFont.caption)
                    .foregroundStyle(SolaroColor.textTertiary)
            }
            .padding(SolaroSpace.m)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: SolaroSpace.s,
                           pinnedViews: [.sectionHeaders]) {
                    let custom = filtered.filter(\.origin.isCustom)
                    let builtIn = filtered.filter { !$0.origin.isCustom }
                    if !custom.isEmpty {
                        Section(header: sectionHeader("PROJECT")) {
                            ForEach(custom) { snippet in
                                SnippetRowView(snippet: snippet,
                                               insertAtCaret: insertAtCaret)
                            }
                        }
                    }
                    if !builtIn.isEmpty {
                        Section(header: sectionHeader("BUILT-IN")) {
                            ForEach(builtIn) { snippet in
                                SnippetRowView(snippet: snippet,
                                               insertAtCaret: insertAtCaret)
                            }
                        }
                    }
                }
                .padding(.bottom, SolaroSpace.m)
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(SolaroFont.sectionTitle)
                .foregroundStyle(SolaroColor.textSecondary)
                .tracking(2)
            Spacer()
        }
        .padding(.horizontal, SolaroSpace.m)
        .padding(.vertical, SolaroSpace.xs)
        .background(SolaroColor.surface.opacity(0.95))
    }

    private func errorFooter(_ error: String) -> some View {
        HStack(alignment: .top, spacing: SolaroSpace.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(SolaroColor.stateError)
                .font(.system(size: 10))
            Text(error)
                .font(SolaroFont.monoCaption)
                .foregroundStyle(SolaroColor.stateError)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, SolaroSpace.m)
        .padding(.vertical, SolaroSpace.xs)
    }

    private var footer: some View {
        HStack(spacing: SolaroSpace.s) {
            Button {
                createStarterFile()
            } label: {
                Label("New snippets file", systemImage: "plus")
                    .font(SolaroFont.caption)
            }
            .buttonStyle(.borderless)
            .disabled(projectRoot == nil)
            .help("Create \(SnippetLibrary.customDirectory)/team.yaml in this project")
            Spacer()
            Button {
                revealCustomDirectory()
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 10))
            }
            .buttonStyle(.borderless)
            .disabled(library.customDirectoryURL == nil)
            .help("Reveal \(SnippetLibrary.customDirectory) in Finder")
        }
        .padding(.horizontal, SolaroSpace.m)
        .padding(.vertical, SolaroSpace.xs)
    }

    /// Write a commented starter file so the format is discoverable
    /// without leaving the app. Never overwrites an existing file —
    /// it just reveals the one already there.
    private func createStarterFile() {
        guard let dir = library.customDirectoryURL else { return }
        let file = dir.appendingPathComponent("team.yaml")
        if !FileManager.default.fileExists(atPath: file.path) {
            try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
            let starter = """
            # SOLARO snippets for this project.
            # `${label}` marks a placeholder — inserting selects the first one.
            # `trigger` expands the snippet when typed in the editor followed by Tab.
            snippets:
              - name: Console log
                description: Write a message to the console
                trigger: log
                body: |
                  Log "${message}" to the <console>.

            """
            try? starter.write(to: file, atomically: true, encoding: .utf8)
        }
        library.reload(projectRoot: projectRoot)
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    private func revealCustomDirectory() {
        guard let dir = library.customDirectoryURL else { return }
        if FileManager.default.fileExists(atPath: dir.path) {
            NSWorkspace.shared.activateFileViewerSelecting([dir])
        } else if let root = projectRoot {
            NSWorkspace.shared.activateFileViewerSelecting([root])
        }
    }
}

// MARK: - Row

private struct SnippetRowView: View {
    let snippet: AROSnippet
    let insertAtCaret: ((AROSnippet) -> Void)?
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: SolaroSpace.s) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10))
                .foregroundStyle(SolaroColor.textTertiary)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(snippet.name)
                        .font(SolaroFont.bodyBold)
                        .foregroundStyle(SolaroColor.textPrimary)
                    if !snippet.trigger.isEmpty {
                        Text(snippet.trigger + "⇥")
                            .font(SolaroFont.monoCaption)
                            .foregroundStyle(SolaroColor.textTertiary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(SolaroColor.divider)
                            .clipShape(Capsule())
                    }
                    Spacer(minLength: 0)
                    if hovering, insertAtCaret != nil {
                        Button {
                            insertAtCaret?(snippet)
                        } label: {
                            Image(systemName: "text.insert")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.borderless)
                        .help("Insert at the cursor")
                    }
                }
                if !snippet.summary.isEmpty {
                    Text(snippet.summary)
                        .font(SolaroFont.caption)
                        .foregroundStyle(SolaroColor.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if case .custom(let file) = snippet.origin {
                    Text(file)
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
        .help(tooltipText)
        // Payload is the expanded body: NSTextView takes string
        // drops natively, and the canvas's onActionDrop path treats
        // it exactly like a dragged action template.
        .onDrag {
            NSItemProvider(
                object: SnippetExpander.expand(snippet.body).text as NSString)
        }
    }

    private var tooltipText: String {
        var parts: [String] = []
        if !snippet.summary.isEmpty {
            parts.append(snippet.summary)
            parts.append("")
        }
        parts.append("Drag into the editor or canvas to insert:")
        parts.append(SnippetExpander.expand(snippet.body).text)
        if !snippet.trigger.isEmpty {
            parts.append("")
            parts.append("Or type \u{201C}\(snippet.trigger)\u{201D} in the editor and press Tab.")
        }
        return parts.joined(separator: "\n")
    }
}
