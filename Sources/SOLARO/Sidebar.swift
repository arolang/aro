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

struct SidebarPaneView: View {
    @Bindable var controller: WorkspaceController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            tabStrip
            Divider().background(SolaroColor.divider)
            switch controller.sidebarTab {
            case .files:    filesPane
            case .features: featuresPane
            case .plugins:  pluginsPane
            }
        }
        .background(SolaroColor.surface)
    }

    // MARK: - Tab strip

    private var tabStrip: some View {
        HStack(spacing: 0) {
            ForEach(SidebarTab.allCases) { tab in
                tabButton(tab)
            }
        }
        .background(SolaroColor.surface)
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
        Group {
            if let model = controller.model {
                let nodes = FileTreeBuilder.build(model: model)
                if nodes.isEmpty {
                    emptyMessage("No .aro files in this project.")
                } else {
                    FileTreeList(
                        nodes: nodes,
                        selection: selectionBinding
                    )
                }
            } else {
                emptyMessage("Loading…")
            }
        }
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
                        ForEach(Array(zip(model.sourceFiles, controller.programs)),
                                id: \.0) { url, program in
                            featureGroup(url: url, program: program, model: model)
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

    // MARK: - Plugins tab

    private var pluginsPane: some View {
        Group {
            let plugins = controller.model.map(PluginScanner.scan) ?? []
            if !plugins.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: SolaroSpace.s) {
                        ForEach(plugins) { plugin in
                            PluginRow(plugin: plugin)
                        }
                    }
                    .padding(.vertical, SolaroSpace.s)
                    .padding(.horizontal, SolaroSpace.m)
                }
            } else {
                emptyMessage("No Plugins/ directory in this project.")
            }
        }
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

    var body: some View {
        List(selection: selectionBinding) {
            OutlineGroup(nodes, id: \.id, children: \.outlineChildren) { node in
                FileRow(node: node)
                    .tag(node.id)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(SolaroColor.surface)
    }

    private var selectionBinding: Binding<String?> {
        Binding(
            get: { selection?.standardizedFileURL.path },
            set: { newPath in
                guard let newPath else { selection = nil; return }
                selection = URL(fileURLWithPath: newPath)
            }
        )
    }
}

private struct FileRow: View {
    let node: FileTreeNode

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
        }
        .padding(.vertical, 2)
    }

    private var icon: String {
        switch node.kind {
        case .directory: return "folder.fill"
        case .aroSource: return "doc.text.fill"
        case .storeFile: return "tray.full"
        case .openapi:   return "rectangle.connected.to.line.below"
        case .other:     return "doc"
        }
    }

    private var tint: Color {
        switch node.kind {
        case .directory: return SolaroColor.accent.opacity(0.85)
        case .aroSource: return SolaroColor.accent
        case .storeFile: return SolaroColor.roleExport
        case .openapi:   return SolaroColor.roleRequest
        case .other:     return SolaroColor.textTertiary
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
                Circle()
                    .fill(activityTint)
                    .frame(width: 6, height: 6)
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
