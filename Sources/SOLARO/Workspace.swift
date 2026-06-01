// ============================================================
// Workspace.swift
// SOLARO — workspace shell + toolbar (Phase 4)
// ============================================================
//
// Wireframe target: note 8467 figure 1 (whole-UI layout). A
// three-zone shell drawn with native macOS chrome:
//
//   ┌─────────────────────────────────────────────────────┐
//   │ ◉ MyProject  ⇨ users.aro    [ Canvas  Text  Split  │
//   │                              Map ]   ⌕  ▶  ●        │  ← toolbar
//   ├─────┬───────────────────────────────────┬───────────┤
//   │     │                                   │           │
//   │ ◫   │            (center pane)          │  AST      │  ← NavigationSplit
//   │     │                                   │  inspect. │     + .inspector
//   │     │                                   │           │
//   └─────┴───────────────────────────────────┴───────────┘
//
// The sidebar is a real NavigationSplitView sidebar (gets the
// native macOS sidebar effect view and translucency for free).
// The right inspector uses SwiftUI's `.inspector` modifier
// (macOS 14+) which gives us an Xcode-style toggleable rail.
//
// Phase 4 ships the shell; the content of each pane is a small
// placeholder. Phases 5–7 swap in the real File tree, Inspector,
// and Center-pane implementations.

import SwiftUI
import AppKit
import AROParser

/// Observable state for an open workspace. Holds the loaded project
/// model, the currently selected file, the pane mode, parsed
/// programs for cross-file views, and the search query.
///
/// Kept as an `@Observable` class (not a struct) so toolbar and
/// pane updates share one source of truth without prop-drilling
/// callbacks through every layer.
@Observable
final class WorkspaceController {
    let project: Project

    var model: ProjectModel?
    var currentFile: URL?
    var paneMode: PaneMode = .canvas
    var sidebarTab: SidebarTab = .files
    var inspectorShown: Bool = true
    var searchText: String = ""
    var loadError: String?

    /// Parsed programs across the project. Built once on load; will
    /// re-parse on Save in Phase 7. Used by the Map view + the
    /// OpenAPI palette.
    var programs: [Program] = []

    init(project: Project) {
        self.project = project
    }

    func load() {
        do {
            let loaded = try ProjectModel.load(project)
            self.model = loaded
            self.programs = loaded.sourceFiles.compactMap { url -> Program? in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                    return nil
                }
                return try? Parser.parse(text)
            }
            if let first = loaded.sourceFiles.first {
                openFile(first)
            }
            RecentProjects.remember(project)
        } catch {
            loadError = "Failed to load project: \(error.localizedDescription)"
        }
    }

    func openFile(_ url: URL) {
        currentFile = url
        let sidecar = LayoutSidecar.load(for: url)
        paneMode = sidecar.paneMode
    }

    func setPaneMode(_ mode: PaneMode) {
        paneMode = mode
        guard let url = currentFile else { return }
        var sidecar = LayoutSidecar.load(for: url)
        sidecar.paneMode = mode
        try? sidecar.save(for: url)
    }
}

enum SidebarTab: String, CaseIterable, Identifiable {
    case files, features, plugins
    var id: String { rawValue }
    var label: String {
        switch self {
        case .files: return "Files"
        case .features: return "Features"
        case .plugins: return "Plugins"
        }
    }
    var symbol: String {
        switch self {
        case .files: return "doc.text"
        case .features: return "square.grid.2x2"
        case .plugins: return "puzzlepiece.extension"
        }
    }
}

// MARK: - Workspace root view

struct WorkspaceView: View {
    let project: Project
    let onClose: () -> Void

    @State private var controller: WorkspaceController

    init(project: Project, onClose: @escaping () -> Void) {
        self.project = project
        self.onClose = onClose
        _controller = State(initialValue: WorkspaceController(project: project))
    }

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            SidebarPaneView(controller: controller)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            CenterPaneView(controller: controller)
                .inspector(isPresented: $controller.inspectorShown) {
                    InspectorPaneView(controller: controller)
                        .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
                }
        }
        .navigationTitle(project.displayName)
        .navigationSubtitle(currentFileLabel)
        .toolbar { toolbarContent }
        .background(SolaroColor.backdrop)
        .onAppear { controller.load() }
        .alert(
            "Failed to load",
            isPresented: Binding(
                get: { controller.loadError != nil },
                set: { if !$0 { controller.loadError = nil } }
            ),
            actions: {
                Button("OK") { controller.loadError = nil }
            },
            message: {
                Text(controller.loadError ?? "")
            }
        )
    }

    private var currentFileLabel: String {
        guard let url = controller.currentFile, let model = controller.model else {
            return ""
        }
        let rootPath = model.root.rootPath.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        if filePath.hasPrefix(rootPath + "/") {
            return String(filePath.dropFirst(rootPath.count + 1))
        }
        return url.lastPathComponent
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            paneModePicker
        }
        ToolbarItemGroup(placement: .primaryAction) {
            searchField
            runButton
            statusPip
            inspectorToggle
            closeProjectButton
        }
    }

    private var paneModePicker: some View {
        Picker("Pane mode", selection: paneModeBinding) {
            ForEach(PaneMode.allCases) { mode in
                Label(mode.label, systemImage: mode.symbol)
                    .tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .help("Center-pane projection (Canvas / Text / Split / Map)")
    }

    private var paneModeBinding: Binding<PaneMode> {
        Binding(
            get: { controller.paneMode },
            set: { controller.setPaneMode($0) }
        )
    }

    private var searchField: some View {
        TextField("Search", text: $controller.searchText)
            .textFieldStyle(.roundedBorder)
            .frame(width: 220)
    }

    private var runButton: some View {
        Button {
            // Phase 11+: trigger an `aro run` of the current project.
        } label: {
            Label("Run", systemImage: "play.fill")
        }
        .help("Run this project (Phase 11)")
    }

    private var statusPip: some View {
        Circle()
            .fill(SolaroColor.stateOK)
            .frame(width: 10, height: 10)
            .help("Project parses successfully")
    }

    private var inspectorToggle: some View {
        Button {
            controller.inspectorShown.toggle()
        } label: {
            Label(
                controller.inspectorShown ? "Hide inspector" : "Show inspector",
                systemImage: "sidebar.right"
            )
        }
        .help("Toggle the right inspector pane")
    }

    private var closeProjectButton: some View {
        Button {
            onClose()
        } label: {
            Label("Close project", systemImage: "xmark.circle")
        }
        .help("Return to the welcome screen")
        .keyboardShortcut("w", modifiers: [.command, .shift])
    }
}

// Real SidebarPaneView lives in Sidebar.swift (Phase 5).

// MARK: - Center placeholder (Phases 7–8 fill it in)

private struct CenterPaneView: View {
    @Bindable var controller: WorkspaceController

    var body: some View {
        VStack(spacing: SolaroSpace.l) {
            Spacer()
            Image(systemName: controller.paneMode.symbol)
                .font(.system(size: 64, weight: .ultraLight))
                .foregroundStyle(SolaroColor.textTertiary)
            Text(controller.paneMode.label)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(SolaroColor.textSecondary)
            Text("Center pane · Phases 7–8")
                .font(SolaroFont.caption)
                .foregroundStyle(SolaroColor.textTertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SolaroColor.backdrop)
    }
}

// MARK: - Inspector placeholder (Phase 6 fills it in)

private struct InspectorPaneView: View {
    @Bindable var controller: WorkspaceController

    var body: some View {
        VStack(alignment: .leading, spacing: SolaroSpace.s) {
            Text("INSPECTOR")
                .font(SolaroFont.sectionTitle)
                .foregroundStyle(SolaroColor.textSecondary)
                .tracking(2)
                .padding(.top, SolaroSpace.m)
                .padding(.horizontal, SolaroSpace.m)

            Text("Inspector pane · Phase 6")
                .font(SolaroFont.caption)
                .foregroundStyle(SolaroColor.textTertiary)
                .padding(.horizontal, SolaroSpace.m)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SolaroColor.surface)
    }
}
