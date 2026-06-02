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
@MainActor
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

    /// 1-indexed source line under the editor caret, used to drive
    /// the bidirectional selection-sync between the editor and the
    /// canvas (the matching node card gets an accent border). Setter
    /// on this from either side is the single source of truth.
    var currentLine: Int?

    /// 1-indexed source line where the debugger is currently
    /// paused. Independent from `currentLine` (which follows the
    /// user's caret); both views can paint them differently.
    var pausedLine: Int?

    /// Live symbol bag captured at the most recent pause. Keyed by
    /// identifier name; populated from the `aro debug --record`
    /// JSONL stream. Used for hover-over-variable tooltips.
    var pauseSymbols: [String: ConsoleProcess.SymbolValue] = [:]

    /// Currently-selected node in the graphical OpenAPI editor (if
    /// the user is on an openapi.yaml file). Drives the inspector
    /// form that lets them edit route / schema fields directly.
    var openAPISelectedNodeID: String?

    /// Which view the right rail shows — the classic inspector
    /// (file metadata, AST, debugger variables, OpenAPI form, …)
    /// or the AI co-pilot.
    var rightPaneMode: RightPaneMode = .inspector

    /// Mutable OpenAPI document loaded when the current file is
    /// openapi.yaml — the inspector form mutates it, the Save
    /// button writes it back to disk.
    var openAPIDocument: OpenAPIDocument?

    /// Parsed programs keyed by source-file URL. Built once on load;
    /// re-parsing on edit lands in Phase 7. Used by the Sidebar
    /// Features tab, the Inspector AST tree, the Canvas, and the
    /// Map view.
    var programs: [URL: Program] = [:]

    /// Parse-failure messages keyed by source-file URL. Empty when
    /// every file parsed cleanly. Surfaced by the Inspector's
    /// diagnostics card.
    var parseErrors: [URL: String] = [:]

    /// LSP client driving `aro lsp` for richer diagnostics. The
    /// inspector reads `lsp.diagnostics[currentFile]` to render
    /// per-line problems alongside the local Lexer parse status.
    let lsp = AROLSPClient()

    /// Cached `aro actions` listing. Populated on project load
    /// and reused by the right-rail Actions tab.
    let actionsRegistry = ActionsRegistry()

    init(project: Project) {
        self.project = project
    }

    func load() {
        do {
            let loaded = try ProjectModel.load(project)
            self.model = loaded
            for url in loaded.sourceFiles {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                    parseErrors[url] = "Could not read file."
                    continue
                }
                do {
                    programs[url] = try Parser.parse(text)
                } catch {
                    parseErrors[url] = "\(error)"
                }
            }
            if let first = loaded.sourceFiles.first {
                openFile(first)
            }
            RecentProjects.remember(project)
            // Kick the LSP off in parallel — the handshake takes a
            // couple hundred ms but doesn't block project load.
            lsp.start()
            // Same for the actions registry — runs `aro actions`
            // off the main actor and feeds the right-rail tab.
            actionsRegistry.reload(for: project)
            for url in loaded.sourceFiles {
                if let text = try? String(contentsOf: url, encoding: .utf8) {
                    lsp.didOpen(url: url, text: text)
                }
            }
        } catch {
            loadError = "Failed to load project: \(error.localizedDescription)"
        }
    }

    /// Parsed program for the file currently shown in the center
    /// pane, if any.
    var currentProgram: Program? {
        guard let url = currentFile else { return nil }
        return programs[url]
    }

    /// Parse error string for the current file, if parsing failed.
    var currentParseError: String? {
        guard let url = currentFile else { return nil }
        return parseErrors[url]
    }

    /// Convenience for cross-file views (Map, OpenAPI palette).
    var allPrograms: [Program] {
        guard let model else { return [] }
        return model.sourceFiles.compactMap { programs[$0] }
    }

    func openFile(_ url: URL) {
        currentFile = url
        let sidecar = LayoutSidecar.load(for: url)
        paneMode = sidecar.paneMode
        // Refresh the OpenAPI document buffer when switching files;
        // tear down the previous file watcher first so we don't
        // leak an O_EVTONLY descriptor per file open.
        openAPIDocument?.tearDownWatcher()
        if url.lastPathComponent.lowercased() == "openapi.yaml"
            || url.lastPathComponent.lowercased() == "openapi.yml"
        {
            openAPIDocument = OpenAPIDocument.load(from: url)
        } else {
            openAPIDocument = nil
            openAPISelectedNodeID = nil
        }
    }

    func setPaneMode(_ mode: PaneMode) {
        paneMode = mode
        guard let url = currentFile else { return }
        var sidecar = LayoutSidecar.load(for: url)
        sidecar.paneMode = mode
        try? sidecar.save(for: url)
    }
}

enum RightPaneMode: String, CaseIterable, Identifiable {
    case inspector
    case actions
    case coPilot

    var id: String { rawValue }

    var label: String {
        switch self {
        case .inspector: return "Inspector"
        case .actions:   return "Actions"
        case .coPilot:   return "Ask"
        }
    }

    var symbol: String {
        switch self {
        case .inspector: return "sidebar.right"
        case .actions:   return "puzzlepiece.fill"
        case .coPilot:   return "sparkles"
        }
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

    @State private var showOpenAPIPalette = false
    @State private var showTimeTravel = false
    /// Console process driving Play. Open whenever it's running OR
    /// the user has explicitly opened it.
    @State private var consoleProcess = ConsoleProcess()
    @State private var showConsole = false
    /// Co-pilot (`aro ask`) process.
    @State private var aiCoPilot = AICoPilotProcess()
    /// NavigationSplitView's column visibility — bound (not constant)
    /// so the sidebar toggle in the title bar actually hides + shows
    /// the left rail.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                SidebarPaneView(controller: controller)
                    .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
            } detail: {
                CenterPaneView(controller: controller)
                    .inspector(isPresented: $controller.inspectorShown) {
                        rightPane
                            .inspectorColumnWidth(min: 320, ideal: 360, max: 480)
                    }
            }
            if showConsole {
                ConsolePanelView(process: consoleProcess) {
                    showConsole = false
                }
                .frame(height: 220)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            StatusBarView(
                controller: controller,
                onShowOpenAPIPalette: { showOpenAPIPalette = true },
                onShowTimeTravel: { showTimeTravel = true }
            )
        }
        .animation(.easeInOut(duration: 0.25), value: showConsole)
        .onChange(of: consoleProcess.pausedLine) { _, newLine in
            // Debugger paused — jump the caret + canvas + paint
            // the pause line.
            controller.pausedLine = newLine
            if let newLine, controller.currentLine != newLine {
                controller.currentLine = newLine
            }
        }
        .onChange(of: consoleProcess.pauseSymbols) { _, newValue in
            controller.pauseSymbols = newValue
        }
        .navigationTitle(project.displayName)
        .navigationSubtitle(currentFileLabel)
        .toolbar { toolbarContent }
        .background(SolaroColor.backdrop)
        .sheet(isPresented: $showOpenAPIPalette) {
            OpenAPIPaletteView(
                endpoints: openAPIEndpoints,
                onClose: { showOpenAPIPalette = false },
                onSelect: { endpoint in
                    if let op = endpoint.operationId,
                       let url = sourceURL(forFeatureSet: op) {
                        controller.openFile(url)
                        controller.setPaneMode(.text)
                    }
                    showOpenAPIPalette = false
                }
            )
        }
        .sheet(isPresented: $showTimeTravel) {
            TimeTravelView(project: project) {
                showTimeTravel = false
            }
        }
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

    /// All endpoints discovered in the project's `openapi.yaml`,
    /// each marked used or not based on whether a matching
    /// operationId-named feature set exists.
    private var openAPIEndpoints: [OpenAPIEndpoint] {
        guard let model = controller.model else { return [] }
        return OpenAPIPalette.endpoints(in: model, programs: controller.allPrograms)
    }

    /// Find the URL of the source file declaring a feature set with
    /// the given name. Used by the OpenAPI palette to jump to the
    /// matching handler.
    private func sourceURL(forFeatureSet name: String) -> URL? {
        guard let model = controller.model else { return nil }
        for url in model.sourceFiles {
            if let program = controller.programs[url],
               program.featureSets.contains(where: { $0.name == name }) {
                return url
            }
        }
        return nil
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

    /// Right pane content. The header strip lets the user flip
    /// between the classic Inspector and the AI co-pilot in place,
    /// instead of opening the co-pilot in a sheet.
    @ViewBuilder
    private var rightPane: some View {
        VStack(spacing: 0) {
            rightPaneTabStrip
            Divider().background(SolaroColor.divider)
            switch controller.rightPaneMode {
            case .inspector:
                InspectorPaneView(controller: controller)
            case .actions:
                ActionsListView(registry: controller.actionsRegistry)
            case .coPilot:
                AICoPilotPanel(
                    project: project,
                    process: aiCoPilot,
                    onClose: { controller.rightPaneMode = .inspector }
                )
            }
        }
    }

    private var rightPaneTabStrip: some View {
        HStack(spacing: 0) {
            ForEach(RightPaneMode.allCases) { mode in
                rightPaneTab(mode)
            }
        }
        .background(SolaroColor.surface)
    }

    private func rightPaneTab(_ mode: RightPaneMode) -> some View {
        let active = controller.rightPaneMode == mode
        return Button {
            controller.rightPaneMode = mode
        } label: {
            VStack(spacing: 2) {
                Image(systemName: mode.symbol)
                    .font(.system(size: 12, weight: .medium))
                Text(mode.label)
                    .font(SolaroFont.caption)
            }
            .frame(maxWidth: .infinity, minHeight: 40)
            .foregroundStyle(active
                             ? SolaroColor.textPrimary
                             : SolaroColor.textTertiary)
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

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            paneModePicker
        }
        ToolbarItemGroup(placement: .primaryAction) {
            searchField
            playButton
            debugButton
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

    private var playButton: some View {
        Button {
            showConsole = true
            consoleProcess.startRun(project: project)
        } label: {
            Label("Run", systemImage: "play.fill")
        }
        .disabled(isRunning)
        .help("Run `aro run` and stream its output to the console")
    }

    private var debugButton: some View {
        Button {
            showConsole = true
            consoleProcess.startDebug(
                project: project,
                breakpointsByFile: collectBreakpoints()
            )
        } label: {
            Label("Debug", systemImage: "ant.fill")
        }
        .disabled(isRunning)
        .help(debugButtonHelp)
    }

    /// Scan every project source file's sidecar for breakpoints
    /// and collect them by file. Empty result → `aro debug` will
    /// pause on every statement (its default behavior).
    private func collectBreakpoints() -> [URL: Set<Int>] {
        guard let model = controller.model else { return [:] }
        var out: [URL: Set<Int>] = [:]
        for url in model.sourceFiles {
            let sidecar = LayoutSidecar.load(for: url)
            if !sidecar.breakpoints.isEmpty {
                out[url] = sidecar.breakpoints
            }
        }
        return out
    }

    private var debugButtonHelp: String {
        let total = collectBreakpoints().values.reduce(0) { $0 + $1.count }
        if total == 0 {
            return "Run `aro debug` — pauses on every statement (no breakpoints set)"
        }
        return "Run `aro debug` and pause at \(total) breakpoint\(total == 1 ? "" : "s")"
    }

    private var isRunning: Bool {
        if case .running = consoleProcess.state { return true }
        return false
    }

    private var statusPip: some View {
        Image(systemName: "circle.fill")
            .resizable()
            .frame(width: 10, height: 10)
            .foregroundStyle(statusPipColor)
            .help(statusPipHelp)
    }

    private var statusPipColor: Color {
        switch consoleProcess.state {
        case .idle:    return SolaroColor.stateOK
        case .running: return SolaroColor.accent
        case .exited(let code): return code == 0 ? SolaroColor.stateOK
                                                 : SolaroColor.stateError
        case .failed:  return SolaroColor.stateError
        }
    }

    private var statusPipHelp: String {
        switch consoleProcess.state {
        case .idle:    return "Idle — click Run to execute"
        case .running: return "Running…"
        case .exited(let code): return code == 0 ? "Last run succeeded"
                                                 : "Last run exited \(code)"
        case .failed(let msg): return "Failed: \(msg)"
        }
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

// Real CenterPaneView lives in CenterPane.swift (Phase 7 onwards).

// Real InspectorPaneView lives in Inspector.swift (Phase 6).
