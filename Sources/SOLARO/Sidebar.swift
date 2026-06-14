// ============================================================
// Sidebar.swift
// SOLARO — left sidebar (Files / Features / Plugins) — Phase 5
// ============================================================
//
// Wireframe target: note 8467 figure 2.
//
// The sidebar lives inside NavigationSplitView's sidebar column,
// so it inherits macOS' translucent sidebar effect view + the
// native selection tint. The tab strip at the top switches between
// three views drawn over the same surface.

import SwiftUI
import AROParser
import Yams

/// View mode for the sidebar's Files tab. Toggled via the two
/// little icons at the top of the tab. `.project` keeps the
/// original ARO-aware view (sources, store files, openapi.yaml);
/// `.all` walks the project root and shows every file/directory
/// (minus the well-known noise dirs like `.build/`, `.git/`).
enum FilesViewMode: String, CaseIterable, Identifiable {
    case project
    case all

    var id: String { rawValue }

    /// SF Symbol drawn in the toggle. `.project` reads as "ARO docs
    /// only" via the bullet-list glyph; `.all` reads as "every file"
    /// via the folder glyph.
    var symbol: String {
        switch self {
        case .project: return "list.bullet.rectangle"
        case .all:     return "folder"
        }
    }

    var help: String {
        switch self {
        case .project: return "Show only ARO project files (.aro, .store, openapi.yaml)"
        case .all:     return "Show every file in the project directory"
        }
    }
}

struct SidebarPaneView: View {
    @Bindable var controller: WorkspaceController

    @State private var showAddPlugin = false
    @State private var showMarketplace = false
    @State private var addPluginProcess = AddPluginProcess()
    /// Bump this to force the Plugins tab to re-scan after an
    /// install. `PluginScanner.scan` reads from disk on every
    /// view eval so changing the integer is enough.
    @State private var pluginsRefreshToken: Int = 0
    /// Files-tab view mode. `.project` shows only ARO sources / store
    /// files / openapi.yaml (the original behavior); `.all` walks
    /// the project root on disk and shows every file/directory the
    /// noise filter doesn't drop. Persisted via `@AppStorage` so the
    /// user's choice survives across sessions.
    @AppStorage(SolaroPrefs.filesTabMode.rawValue)
    private var filesTabMode: FilesViewMode = .project
    /// Directory the file tree currently has highlighted as a
    /// drop / focus target — used as the destination folder for
    /// the new file. `nil` means "use the project root".
    @State private var selectedDirectory: URL? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            tabStrip
            Divider().background(SolaroColor.divider)
            switch controller.sidebarTab {
            case .files:    filesPane
            case .features: featuresPane
            case .outline:  outlinePane
            case .plugins:  pluginsPane
            }
        }
        // Frosted-glass sidebar. `.ultraThinMaterial` carries the
        // bulk of the blur; the thin tint on top is just enough to
        // stop text from disappearing under bright wallpapers,
        // without flattening the wallpaper itself.
        .background(SolaroColor.surface.opacity(0.08))
        .background(.ultraThinMaterial)
        .sheet(isPresented: $showAddPlugin) {
            if let project = controller.model?.root {
                AddPluginSheet(
                    project: project,
                    process: addPluginProcess,
                    onCancel: { showAddPlugin = false },
                    onSuccess: {
                        pluginsRefreshToken += 1
                        showAddPlugin = false
                        addPluginProcess.reset()
                    }
                )
            }
        }
        .sheet(isPresented: $showMarketplace) {
            if let project = controller.model?.root {
                PluginMarketplaceSheet(
                    project: project,
                    onClose: { showMarketplace = false },
                    onInstalled: { pluginsRefreshToken += 1 }
                )
            }
        }
    }

    /// Where the next "New file…" lands. Honors the file tree's
    /// current directory selection when there is one; otherwise
    /// drops the file at the project root next to `main.aro`.
    private func destinationDirectory(in model: ProjectModel) -> URL {
        if let dir = selectedDirectory {
            return dir
        }
        // Use the currently open file's parent when nothing is
        // explicitly selected in the tree — keeps the new file
        // near whatever the user was just editing.
        if let current = controller.currentFile {
            return current.deletingLastPathComponent()
        }
        return model.root.rootPath
    }

    // MARK: - Tab strip

    private var tabStrip: some View {
        HStack(spacing: 0) {
            ForEach(SidebarTab.allCases) { tab in
                tabButton(tab)
            }
        }
        // Tab strip stays transparent so the sidebar's frosted
        // material reads as one continuous surface.
        .background(Color.clear)
    }

    private func tabButton(_ tab: SidebarTab) -> some View {
        let active = controller.sidebarTab == tab
        return Button {
            controller.sidebarTab = tab
        } label: {
            VStack(spacing: 2) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 12, weight: .medium))
                Text(tab.label)
                    .font(SolaroFont.caption)
            }
            .frame(maxWidth: .infinity, minHeight: 40)
            .foregroundStyle(active ? SolaroColor.textPrimary : SolaroColor.textTertiary)
            .background(
                VStack {
                    Spacer()
                    Rectangle()
                        .fill(active ? SolaroColor.accent : Color.clear)
                        .frame(height: 2)
                }
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Files tab

    private var filesPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            filesModeToggle
            Divider().background(SolaroColor.divider.opacity(0.5))
            filesPaneBody
        }
    }

    @ViewBuilder
    private var filesPaneBody: some View {
        if let model = controller.model {
            let nodes = filesTabMode == .all
                ? FileTreeBuilder.buildAll(model: model)
                : FileTreeBuilder.build(model: model)
            if nodes.isEmpty {
                emptyMessage(filesTabMode == .project
                    ? "No .aro files in this project."
                    : "No files in this directory.")
            } else {
                FileTreeList(
                    nodes: nodes,
                    selection: selectionBinding,
                    directorySelection: $selectedDirectory,
                    gitStatus: controller.gitMonitor.status,
                    project: model.root,
                    monitor: controller.gitMonitor,
                    onRename: { url, newName in renameFile(url, to: newName) },
                    onFocusChanged: { controller.treeFocus = $0 }
                )
            }
        } else {
            emptyMessage("Loading…")
        }
    }

    /// Two-icon switch at the top of the Files tab. `.project` is
    /// the ARO-aware view (sources + stores + openapi only),
    /// `.all` walks the project root from disk so the user sees
    /// every file the noise filter doesn't drop.
    private var filesModeToggle: some View {
        HStack(spacing: 4) {
            // "New file" — opens a sheet asking for the file type
            // (.aro / openapi.yaml) and a name. When the user has
            // a directory row selected in the tree the new file
            // lands inside it; otherwise it lands at the project
            // root.
            Button {
                // Post a notification so the workspace root
                // hosts the sheet, not the sidebar — see
                // `solaroRequestNewFile` for the rationale.
                let model = controller.model
                let dir = model.map { destinationDirectory(in: $0).path }
                NotificationCenter.default.post(
                    name: .solaroRequestNewFile,
                    object: nil,
                    userInfo: dir.map { ["dir": $0] } ?? [:]
                )
            } label: {
                Image(systemName: "doc.badge.plus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(SolaroColor.textTertiary)
                    .frame(width: 22, height: 18)
            }
            .buttonStyle(.plain)
            .help("New file…")
            .disabled(controller.model == nil)
            Spacer()
            ForEach(FilesViewMode.allCases) { mode in
                filesModeButton(mode)
            }
        }
        .padding(.horizontal, SolaroSpace.s)
        .padding(.vertical, 4)
    }

    private func filesModeButton(_ mode: FilesViewMode) -> some View {
        let active = filesTabMode == mode
        return Button {
            filesTabMode = mode
        } label: {
            Image(systemName: mode.symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(active
                    ? SolaroColor.textPrimary
                    : SolaroColor.textTertiary)
                .frame(width: 22, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(active
                            ? SolaroColor.selection.opacity(0.6)
                            : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(mode.help)
    }

    private var selectionBinding: Binding<URL?> {
        Binding(
            get: { controller.currentFile },
            set: { newValue in
                if let url = newValue { controller.openFile(url) }
            }
        )
    }

    // MARK: - Features tab

    private var featuresPane: some View {
        Group {
            if let model = controller.model, !controller.programs.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: SolaroSpace.m) {
                        ForEach(model.sourceFiles, id: \.self) { url in
                            if let program = controller.programs[url] {
                                featureGroup(url: url, program: program, model: model)
                            }
                        }
                    }
                    .padding(.vertical, SolaroSpace.s)
                }
            } else if controller.model != nil {
                emptyMessage("No feature sets parsed.")
            } else {
                emptyMessage("Loading…")
            }
        }
    }

    private func featureGroup(
        url: URL,
        program: Program,
        model: ProjectModel
    ) -> some View {
        VStack(alignment: .leading, spacing: SolaroSpace.xs) {
            Text(relativeName(of: url, in: model))
                .font(SolaroFont.sectionTitle)
                .foregroundStyle(SolaroColor.textSecondary)
                .tracking(1)
                .padding(.horizontal, SolaroSpace.m)
            ForEach(program.featureSets, id: \.name) { fs in
                FeatureRow(fs: fs) {
                    controller.openFile(url)
                }
            }
        }
    }

    // MARK: - Outline tab

    private var outlinePane: some View {
        Group {
            if let url = controller.currentFile,
               let program = controller.programs[url] {
                ScrollView {
                    VStack(alignment: .leading, spacing: SolaroSpace.s) {
                        ForEach(program.featureSets, id: \.name) { fs in
                            OutlineFeatureSet(
                                fs: fs,
                                onJump: { line in
                                    controller.currentLine = line
                                }
                            )
                        }
                    }
                    .padding(.vertical, SolaroSpace.s)
                }
            } else {
                emptyMessage("Open a file to see its outline.")
            }
        }
    }

    // MARK: - Plugins tab

    private var pluginsPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: SolaroSpace.xs) {
                Text("Installed")
                    .font(SolaroFont.caption)
                    .foregroundStyle(SolaroColor.textTertiary)
                Spacer()
                Button {
                    showMarketplace = true
                } label: {
                    Label("Browse", systemImage: "shippingbox")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .disabled(controller.model == nil)
                .help("Browse the plugin marketplace")
                Button {
                    showAddPlugin = true
                } label: {
                    Label("Add", systemImage: "plus")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .disabled(controller.model == nil)
                .help("Install a plugin from a Git repository (`aro add`)")
            }
            .padding(.horizontal, SolaroSpace.m)
            .padding(.top, SolaroSpace.s)
            .padding(.bottom, 2)

            let _ = pluginsRefreshToken
            let plugins = controller.model.map(PluginScanner.scan) ?? []
            if !plugins.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: SolaroSpace.s) {
                        ForEach(plugins) { plugin in
                            PluginRow(plugin: plugin)
                                .contextMenu {
                                    if let dir = pluginPath(for: plugin) {
                                        Button("Reveal plugin.yaml") {
                                            let yaml = dir.appendingPathComponent("plugin.yaml")
                                            NSWorkspace.shared.activateFileViewerSelecting([yaml])
                                        }
                                        Button("Reveal in Finder") {
                                            NSWorkspace.shared.activateFileViewerSelecting([dir])
                                        }
                                        Divider()
                                        Button(role: .destructive) {
                                            uninstall(plugin, at: dir)
                                        } label: {
                                            Label("Uninstall…", systemImage: "trash")
                                        }
                                    }
                                }
                        }
                    }
                    .padding(.vertical, SolaroSpace.s)
                    .padding(.horizontal, SolaroSpace.m)
                }
            } else {
                emptyMessage("No plugins installed.\nClick + above to add one from a Git URL.")
            }
        }
    }

    /// Resolve the on-disk directory for a plugin entry.
    private func pluginPath(for plugin: SidebarPluginInfo) -> URL? {
        guard let model = controller.model else { return nil }
        return model.root.rootPath
            .appendingPathComponent("Plugins")
            .appendingPathComponent(plugin.name)
    }

    /// Confirm-then-remove a plugin directory.
    private func uninstall(_ plugin: SidebarPluginInfo, at dir: URL) {
        let alert = NSAlert()
        alert.messageText = "Uninstall \(plugin.name)?"
        alert.informativeText = "Removes Plugins/\(plugin.name) from disk. This cannot be undone."
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        try? FileManager.default.removeItem(at: dir)
        pluginsRefreshToken += 1
    }

    // MARK: - Helpers

    private func emptyMessage(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(SolaroFont.caption)
                .foregroundStyle(SolaroColor.textTertiary)
                .padding(SolaroSpace.l)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    /// Prompt the user for a new filename and rename the on-disk
    /// file. Keeps the file in its current directory; the new name
    /// is taken as a leaf (no `/` allowed). Rename failures surface
    /// via a follow-up alert so the user can copy the path/message.
    private func renameFile(_ url: URL, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") else { return }
        let dest = url.deletingLastPathComponent()
            .appendingPathComponent(trimmed)
        guard dest.path != url.path else { return }
        do {
            try FileManager.default.moveItem(at: url, to: dest)
            // If the renamed file was the open tab, follow it.
            if controller.currentFile == url {
                controller.openFile(dest)
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't rename \(url.lastPathComponent)"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    private func relativeName(of url: URL, in model: ProjectModel) -> String {
        let rootPath = model.root.rootPath.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        if filePath.hasPrefix(rootPath + "/") {
            return String(filePath.dropFirst(rootPath.count + 1))
        }
        return url.lastPathComponent
    }
}

// MARK: - File tree list

private struct FileTreeList: View {
    let nodes: [FileTreeNode]
    @Binding var selection: URL?
    /// Highlighted directory (if any). Click a folder row to set
    /// this; SidebarPaneView reads it when placing "New file…"
    /// so the file lands inside the picked folder.
    @Binding var directorySelection: URL?
    let gitStatus: GitStatus
    let project: Project
    let monitor: GitStatusMonitor
    let onRename: (URL, String) -> Void
    /// Bubbled out so the workspace's menu-bar handlers (delete,
    /// reveal, copy path) can act on the tree's actual selection
    /// instead of falling back to `controller.currentFile`. Set
    /// every time the user clicks a row, regardless of whether
    /// it's a file or a directory.
    let onFocusChanged: (URL?) -> Void
    @State private var renameTarget: URL?
    @State private var renameDraft: String = ""

    var body: some View {
        List(selection: selectionBinding) {
            OutlineGroup(nodes, id: \.id, children: \.outlineChildren) { node in
                FileRow(node: node, gitStatus: gitStatus.files[node.url.path])
                    .tag(node.id)
                    .listRowBackground(Color.clear)
                    .contextMenu { menuItems(for: node) }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        // Transparent list bg so the sidebar's frosted material
        // shows through; rows still get their own selection tint.
        .background(Color.clear)
        .alert("Rename file", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("Filename", text: $renameDraft)
            Button("Rename") {
                if let url = renameTarget {
                    onRename(url, renameDraft)
                }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) {
                renameTarget = nil
            }
        } message: {
            if let url = renameTarget {
                Text("Rename \(url.lastPathComponent) in \(url.deletingLastPathComponent().lastPathComponent)/")
            }
        }
    }

    @ViewBuilder
    private func menuItems(for node: FileTreeNode) -> some View {
        let url = node.url
        let status = gitStatus.files[url.path]
        Button("Open") {
            selection = url
        }
        Divider()
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        Button("Copy File Path") {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(url.path, forType: .string)
        }
        Button("Copy Filename") {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(url.lastPathComponent, forType: .string)
        }
        if node.kind != .directory {
            Divider()
            Button("Rename…") {
                renameDraft = url.lastPathComponent
                renameTarget = url
            }
        }
        if let status, status != .ignored {
            Divider()
            Button("Git: Revert Local Changes", role: .destructive) {
                Task {
                    _ = await monitor.revertLocalChanges(
                        in: project, path: url.path, status: status
                    )
                }
            }
        }
    }

    private var selectionBinding: Binding<String?> {
        Binding(
            get: {
                directorySelection?.standardizedFileURL.path
                    ?? selection?.standardizedFileURL.path
            },
            set: { newPath in
                guard let newPath else {
                    selection = nil
                    directorySelection = nil
                    onFocusChanged(nil)
                    return
                }
                let url = URL(fileURLWithPath: newPath)
                var isDir: ObjCBool = false
                FileManager.default.fileExists(
                    atPath: url.path, isDirectory: &isDir
                )
                if isDir.boolValue {
                    // Folder rows just set the new-file
                    // destination — they don't open in the editor.
                    directorySelection = url
                } else {
                    // File rows take over selection and clear any
                    // folder highlight.
                    directorySelection = nil
                    selection = url
                }
                onFocusChanged(url)
            }
        )
    }
}

private struct FileRow: View {
    let node: FileTreeNode
    let gitStatus: GitStatus.FileStatus?

    var body: some View {
        HStack(spacing: SolaroSpace.s) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(tint)
                .frame(width: 14)
            Text(node.name)
                .font(node.kind == .directory ? SolaroFont.bodyBold : SolaroFont.body)
                .foregroundStyle(SolaroColor.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if let gitStatus {
                Text(gitTag(gitStatus))
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(gitColor(gitStatus))
                    .help(gitTitle(gitStatus))
            }
        }
        .padding(.vertical, 2)
    }

    private func gitTag(_ status: GitStatus.FileStatus) -> String {
        switch status {
        case .modified:   return "M"
        case .added:      return "A"
        case .deleted:    return "D"
        case .renamed:    return "R"
        case .untracked:  return "U"
        case .ignored:    return ""
        case .conflicted: return "‼"
        }
    }

    private func gitColor(_ status: GitStatus.FileStatus) -> Color {
        switch status {
        case .modified:   return SolaroColor.stateWarn
        case .added:      return SolaroColor.stateOK
        case .deleted:    return SolaroColor.stateError
        case .renamed:    return SolaroColor.accent
        case .untracked:  return SolaroColor.stateOK
        case .ignored:    return SolaroColor.textTertiary
        case .conflicted: return SolaroColor.stateError
        }
    }

    private func gitTitle(_ status: GitStatus.FileStatus) -> String {
        switch status {
        case .modified:   return "Modified"
        case .added:      return "Added"
        case .deleted:    return "Deleted"
        case .renamed:    return "Renamed"
        case .untracked:  return "Untracked"
        case .ignored:    return "Ignored"
        case .conflicted: return "Conflicted — resolve before committing"
        }
    }

    private var icon: String {
        switch node.kind {
        case .directory:       return "folder.fill"
        case .aroSource:       return "doc.text.fill"
        case .storeFile:       return "tray.full"
        case .openapi:         return "rectangle.connected.to.line.below"
        case .projectManifest: return "gearshape.fill"
        case .other:           return "doc"
        }
    }

    private var tint: Color {
        switch node.kind {
        case .directory:       return SolaroColor.accent.opacity(0.85)
        case .aroSource:       return SolaroColor.accent
        case .storeFile:       return SolaroColor.roleExport
        case .openapi:         return SolaroColor.roleRequest
        case .projectManifest: return SolaroColor.stateOK
        case .other:           return SolaroColor.textTertiary
        }
    }
}

// MARK: - Feature row

private struct FeatureRow: View {
    let fs: FeatureSet
    let onSelect: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: SolaroSpace.s) {
                Image(systemName: "circle.fill")
                    .resizable()
                    .frame(width: 6, height: 6)
                    .foregroundStyle(activityTint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(fs.name)
                        .font(SolaroFont.body)
                        .foregroundStyle(SolaroColor.textPrimary)
                        .lineLimit(1)
                    Text(fs.businessActivity.isEmpty ? "—" : fs.businessActivity)
                        .font(SolaroFont.caption)
                        .foregroundStyle(SolaroColor.textTertiary)
                        .lineLimit(1)
                }
                Spacer()
                Text("\(fs.statements.count)")
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(SolaroColor.textTertiary)
            }
            .padding(.vertical, SolaroSpace.xs)
            .padding(.horizontal, SolaroSpace.m)
            .background(
                Rectangle()
                    .fill(hovering ? SolaroColor.selection.opacity(0.4) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    /// Color hint based on the feature set's business activity name:
    /// API endpoints get the request tint, handlers get the export
    /// tint, everything else gets the secondary text color.
    private var activityTint: Color {
        let activity = fs.businessActivity.lowercased()
        if fs.name == "Application-Start" || fs.name.hasPrefix("Application-") {
            return SolaroColor.stateOK
        }
        if activity.contains("api") { return SolaroColor.roleRequest }
        if activity.contains("handler") || activity.contains("observer") {
            return SolaroColor.roleExport
        }
        if activity.contains("action") { return SolaroColor.roleOwn }
        return SolaroColor.textSecondary
    }
}

// MARK: - Outline rows

private struct OutlineFeatureSet: View {
    let fs: FeatureSet
    let onJump: (Int) -> Void
    @State private var expanded: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9))
                        .foregroundStyle(SolaroColor.textTertiary)
                        .frame(width: 12)
                    Text(fs.name)
                        .font(SolaroFont.body)
                        .foregroundStyle(SolaroColor.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    Text(fs.businessActivity)
                        .font(SolaroFont.monoCaption)
                        .foregroundStyle(SolaroColor.textTertiary)
                        .lineLimit(1)
                }
                .padding(.horizontal, SolaroSpace.m)
            }
            .buttonStyle(.plain)
            if expanded {
                ForEach(Array(fs.statements.enumerated()), id: \.offset) { _, stmt in
                    OutlineStatement(statement: stmt, onJump: onJump)
                }
            }
        }
    }
}

private struct OutlineStatement: View {
    let statement: any Statement
    let onJump: (Int) -> Void

    var body: some View {
        Button {
            onJump(statement.span.start.line)
        } label: {
            HStack(spacing: 4) {
                if let aro = statement as? AROStatement {
                    Image(systemName: "circle.fill")
                        .resizable()
                        .frame(width: 4, height: 4)
                        .foregroundStyle(SolaroColor.roleColor(forVerb: aro.action.verb))
                    Text(aro.action.verb)
                        .font(SolaroFont.monoCaption)
                        .foregroundStyle(SolaroColor.roleColor(forVerb: aro.action.verb))
                    Text("<\(aro.result.base)>")
                        .font(SolaroFont.monoCaption)
                        .foregroundStyle(SolaroColor.textSecondary)
                        .lineLimit(1)
                } else if let pub = statement as? PublishStatement {
                    Image(systemName: "circle.fill")
                        .resizable()
                        .frame(width: 4, height: 4)
                        .foregroundStyle(SolaroColor.roleExport)
                    Text("Publish")
                        .font(SolaroFont.monoCaption)
                        .foregroundStyle(SolaroColor.roleExport)
                    Text(pub.internalVariable)
                        .font(SolaroFont.monoCaption)
                        .foregroundStyle(SolaroColor.textSecondary)
                }
                Spacer()
                Text(":\(statement.span.start.line)")
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(SolaroColor.textTertiary)
            }
            .padding(.leading, SolaroSpace.l + 8)
            .padding(.trailing, SolaroSpace.m)
            .padding(.vertical, 1)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Plugin discovery + row

struct SidebarPluginInfo: Identifiable, Hashable {
    let id: String     // Plugins/<name>
    let name: String
    let version: String?
    let kind: String?  // "swift-plugin", "rust-plugin", "c-plugin", "python-plugin"
}

enum PluginScanner {
    /// Discover every `Plugins/<name>/plugin.yaml` under the project
    /// root. Returns `[]` on missing directory — the UI handles the
    /// empty case honestly.
    static func scan(model: ProjectModel) -> [SidebarPluginInfo] {
        let pluginsDir = model.root.rootPath.appendingPathComponent("Plugins")
        let fm = FileManager.default
        guard fm.fileExists(atPath: pluginsDir.path) else { return [] }

        var out: [SidebarPluginInfo] = []
        let children = (try? fm.contentsOfDirectory(at: pluginsDir,
                                                   includingPropertiesForKeys: nil)) ?? []
        for dir in children where (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let manifest = dir.appendingPathComponent("plugin.yaml")
            guard
                let text = try? String(contentsOf: manifest, encoding: .utf8),
                let parsed = try? Yams.load(yaml: text) as? [String: Any]
            else { continue }

            let name = parsed["name"] as? String ?? dir.lastPathComponent
            let version = parsed["version"] as? String
            let provides = parsed["provides"] as? [[String: Any]]
            let kind = provides?.first?["type"] as? String

            out.append(SidebarPluginInfo(
                id: dir.standardizedFileURL.path,
                name: name,
                version: version,
                kind: kind
            ))
        }
        return out.sorted { $0.name < $1.name }
    }
}

private struct PluginRow: View {
    let plugin: SidebarPluginInfo

    var body: some View {
        HStack(spacing: SolaroSpace.s) {
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.system(size: 12))
                .foregroundStyle(SolaroColor.accent.opacity(0.8))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(plugin.name)
                    .font(SolaroFont.body)
                    .foregroundStyle(SolaroColor.textPrimary)
                HStack(spacing: 4) {
                    if let kind = plugin.kind {
                        Text(kind)
                            .font(SolaroFont.caption)
                            .foregroundStyle(SolaroColor.textTertiary)
                    }
                    if let version = plugin.version {
                        Text("·  v\(version)")
                            .font(SolaroFont.caption)
                            .foregroundStyle(SolaroColor.textTertiary)
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, SolaroSpace.xs)
    }
}

// MARK: - New file sheet

/// "New file…" picker — choose a file type and a name. The
/// destination directory is decided by the caller (typically the
/// selected tree row, with the project root as fallback) and
/// shown read-only at the top so the user knows where the file
/// will land.
struct NewFileSheet: View {
    enum Kind: String, CaseIterable, Identifiable {
        case aro
        case openapi
        case empty

        var id: String { rawValue }

        var label: String {
            switch self {
            case .aro:     return "ARO Source (.aro)"
            case .openapi: return "OpenAPI Contract (openapi.yaml)"
            case .empty:   return "Empty File"
            }
        }

        var symbol: String {
            switch self {
            case .aro:     return "doc.text"
            case .openapi: return "rectangle.connected.to.line.below"
            case .empty:   return "doc"
            }
        }

        var blurb: String {
            switch self {
            case .aro:
                return "A new `.aro` source file with a stub feature set ready to fill in."
            case .openapi:
                return "An `openapi.yaml` skeleton. The runtime needs this for the HTTP server to start."
            case .empty:
                return "A blank file. Pick the extension yourself — useful for READMEs, notes, JSON fixtures, etc."
            }
        }
    }

    let destinationDirectory: URL
    let onCancel: () -> Void
    let onCreate: (Kind, String) -> Void

    @State private var selectedKind: Kind = .aro
    @State private var filename: String = "untitled.aro"

    var body: some View {
        VStack(alignment: .leading, spacing: SolaroSpace.m) {
            Text("New File")
                .font(SolaroFont.toolbarTitle)
            Text("In \(destinationDirectory.lastPathComponent)/")
                .font(SolaroFont.monoCaption)
                .foregroundStyle(SolaroColor.textTertiary)
                .textSelection(.enabled)
            Divider()
            VStack(alignment: .leading, spacing: SolaroSpace.s) {
                ForEach(Kind.allCases) { kind in
                    kindRow(kind)
                }
            }
            // We always render this block — even for openapi where
            // the field is disabled — so the sheet's layout shape
            // stays constant. Showing/hiding it on selectedKind
            // change made SwiftUI animate the sheet's height, which
            // fed `NSHostingView.updateAnimatedWindowSize` →
            // `NSWindow._persistFrame` → an NSUserDefaults
            // notification → a re-entrant `setNeedsUpdate` during
            // the very layout cycle that started it. macOS 26
            // catches that re-entry and aborts the app.
            VStack(alignment: .leading, spacing: 4) {
                Text("FILENAME")
                    .font(SolaroFont.caption)
                    .tracking(1)
                    .foregroundStyle(SolaroColor.textTertiary)
                TextField(
                    selectedKind == .aro ? "untitled.aro" : "README.md",
                    text: filenameBinding
                )
                .textFieldStyle(.roundedBorder)
                .disabled(selectedKind == .openapi)
                .opacity(selectedKind == .openapi ? 0.5 : 1)
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    onCreate(selectedKind, effectiveName)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
        }
        .padding(SolaroSpace.l)
        .frame(width: 480, height: 360)
    }

    private func kindRow(_ kind: Kind) -> some View {
        Button {
            // Mutate the state with animations disabled — see the
            // comment on the FILENAME block above for why an
            // animated sheet height change here aborts the app on
            // macOS 26.
            var tx = Transaction()
            tx.disablesAnimations = true
            withTransaction(tx) {
                selectedKind = kind
                // Snap the filename field to the kind's default so
                // the user can hit Return without re-typing for the
                // common case. Only override when the field still
                // holds a stale default from another kind — never
                // clobber a name the user has hand-typed.
                let stale: Set<String> = [
                    "openapi.yaml", "untitled.aro", "README.md", ""
                ]
                switch kind {
                case .openapi:
                    // Don't overwrite `filename` here — the
                    // openapi-mode field is bound to a read-only
                    // binding that reports "openapi.yaml" without
                    // touching the stored draft.
                    break
                case .aro:
                    if stale.contains(filename) { filename = "untitled.aro" }
                case .empty:
                    if stale.contains(filename) { filename = "README.md" }
                }
            }
        } label: {
            HStack(alignment: .top, spacing: SolaroSpace.s) {
                Image(systemName: kind.symbol)
                    .font(.system(size: 18))
                    .foregroundStyle(SolaroColor.accent)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.label)
                        .font(SolaroFont.bodyBold)
                    Text(kind.blurb)
                        .font(SolaroFont.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                // Keep the slot reserved with `.opacity` rather
                // than `if` — same reason as the FILENAME field
                // above. We don't want any geometry change here.
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(SolaroColor.accent)
                    .opacity(selectedKind == kind ? 1 : 0)
            }
            .padding(SolaroSpace.s)
            .background(
                RoundedRectangle(cornerRadius: SolaroRadius.s)
                    .fill(selectedKind == kind
                        ? SolaroColor.selection.opacity(0.4)
                        : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SolaroRadius.s)
                    .stroke(SolaroColor.divider.opacity(0.5), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var effectiveName: String {
        // openapi.yaml is the only valid name for that kind, so
        // ignore whatever the user typed.
        selectedKind == .openapi ? "openapi.yaml" : filename
    }

    /// For openapi the field shows "openapi.yaml" but doesn't
    /// touch `filename`, so flipping back to .aro restores the
    /// user's previous draft.
    private var filenameBinding: Binding<String> {
        Binding(
            get: { selectedKind == .openapi ? "openapi.yaml" : filename },
            set: { newValue in
                if selectedKind != .openapi { filename = newValue }
            }
        )
    }

    private var isValid: Bool {
        let name = effectiveName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && !name.contains("/")
    }
}
