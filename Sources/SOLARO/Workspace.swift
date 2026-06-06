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
    /// Files currently open in the center-pane tab bar. The active
    /// tab is `currentFile`; if a tab is closed and was the active
    /// one, the workspace falls back to the previous tab.
    var openTabs: [URL] = []
    var paneMode: PaneMode = .canvas
    var sidebarTab: SidebarTab = .files
    var sidebarShown: Bool = true
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

    /// Wall-clock time each source line was last executed during the
    /// currently-recording (or just-finished) run. Mirrored from
    /// `ConsoleProcess.lastExecutedAt` so views that only depend on
    /// the controller don't need to know about the console.
    var lastExecutedAt: [Int: Date] = [:]
    /// Same idea, but per feature-set name — drives the FS-container
    /// glow that disambiguates concurrent runs.
    var lastExecutedAtPerFeatureSet: [String: Date] = [:]
    /// Source line → runtime error message; mirrored from
    /// `ConsoleProcess.errorLines`. Painted as a red border on the
    /// corresponding canvas node.
    var errorLines: [Int: String] = [:]
    /// Tick counter incremented every time `lastExecutedAt` updates
    /// — TimelineView-based animations watch this to keep redrawing
    /// even when the same line fires twice in a row.
    var executionTick: UInt64 = 0
    /// Most recent value the runtime saw flowing into each
    /// repository, keyed by repository object name.
    var repositoryValues: [String: ConsoleProcess.SymbolValue] = [:]
    /// User-dragged node and repository positions, keyed by node /
    /// repo ID. Previously lived as `@State` on CanvasView, which
    /// made undo impossible (a captured closure can't mutate a
    /// view-struct's @State). Now owned here so the UndoManager
    /// handler can restore an old position by writing to this
    /// class property.
    var liveNodes: [String: CGPoint] = [:]
    /// Rolling history (newest first) of the last N payloads per
    /// repository — driven by the same live event stream that fills
    /// `repositoryValues`. Exposed via the repository card's hover
    /// popover.
    var repositoryHistory: [String: [ConsoleProcess.SymbolValue]] = [:]

    /// Outcome of the most recent `aro test` run, keyed by test
    /// feature-set name (e.g. `"length-of-hello"`). Drives the
    /// pass/fail badge on the canvas FS container header and on the
    /// Inspector's feature set list. Cleared whenever a new test
    /// run starts; populated by parsing the runner's PASS/FAIL
    /// stdout lines in `ConsoleProcess`.
    var testResults: [String: TestNodeResult] = [:]

    /// Multi-node selection on the canvas (#266). Plain click sets
    /// a single ID, ⌘-click toggles membership, the rubber-band on
    /// blank space replaces the set with everything inside the
    /// rect. Empty when nothing is selected. The single-node
    /// `selectedNode` mirror below stays in sync with the *most
    /// recently* added member so the Inspector form keeps showing
    /// one node at a time even when several are highlighted.
    var selectedNodeIDs: Set<String> = []

    /// Currently-selected canvas node. Populated on single-click in
    /// the node editor so the Inspector can mirror the same fields
    /// the double-click expansion shows (read-only summary). nil
    /// when nothing is selected.
    var selectedNode: CanvasNode? = nil
    /// Raw source text spanned by `selectedNode`. Captured at click
    /// time because the Inspector doesn't otherwise have access to
    /// `rawSourceText` (lives on CanvasView).
    var selectedNodeSource: String? = nil
    /// CenterPane installs this so the Inspector's editable
    /// "Selected Statement" form can hit the same write-back path
    /// the canvas's double-click editor uses. Stored as a closure
    /// (not a method on this class) because the rewrite logic
    /// needs CenterPane-private helpers like `saveAndReparse`.
    var nodeEditApply: (@MainActor (CanvasNode.ID, String) -> Void)? = nil

    /// Currently-selected node in the graphical OpenAPI editor (if
    /// the user is on an openapi.yaml file). Drives the inspector
    /// form that lets them edit route / schema fields directly.
    var openAPISelectedNodeID: String?

    /// 0-indexed caret column tracked by the code editor. Surfaced
    /// so LSP-backed features (go-to-definition, hover) can ship
    /// the actual user position instead of a heuristic guess.
    var currentColumn: Int?

    /// Bumped by callers that want the editor to forcibly reposition
    /// the caret to `(currentLine, currentColumn)` — used after the
    /// ghost popover splices a suggestion so the caret lands at the
    /// end of the inserted word + space instead of column 0 of the
    /// line (which is what the line-only moveCaret would do).
    var caretMoveTick: Int = 0

    func requestCaretMove(line: Int, column: Int) {
        currentLine = line
        currentColumn = column
        caretMoveTick &+= 1
    }

    /// Drives the Extract-as-Action sheet. The sheet's binding
    /// pulls from this state; setting it from a context-menu
    /// click pops the sheet open.
    var extractActionState = ExtractActionState()
    var showExtractActionSheet: Bool = false

    func requestExtractAction(node: CanvasNode) {
        extractActionState.node = node
        extractActionState.sourceURL = currentFile
        extractActionState.name = ""
        showExtractActionSheet = true
    }

    /// Which view the right rail shows — the classic inspector
    /// (file metadata, AST, debugger variables, OpenAPI form, …)
    /// or the AI co-pilot.
    var rightPaneMode: RightPaneMode = .inspector

    /// Mutable OpenAPI document loaded when the current file is
    /// openapi.yaml — the inspector form mutates it, the Save
    /// button writes it back to disk.
    var openAPIDocument: OpenAPIDocument?

    /// State for the OpenAPI Try-It-Out section in the inspector
    /// (#249). One model per workspace, reused across selected
    /// routes so the base URL + headers carry over between requests.
    let tryItOutModel = TryItOutModel()

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

    /// Git status of the project root. Populated on project load
    /// + after every file save. Feeds the sidebar file-tree
    /// indicators and the status bar's branch chip.
    let gitMonitor = GitStatusMonitor()

    /// Debugger watch expressions (#258). Persists across launches
    /// via UserDefaults.
    let watches = WatchesStore()

    /// AI co-pilot subprocess. Moved here from the view's @State so
    /// non-view callers (e.g. canvas right-click "Explain with
    /// aro ask") can fire prompts directly.
    let aiCoPilot = AICoPilotProcess()

    /// Test runner state (#271) — shared across the workspace so
    /// the bottom-panel Tests tab and the Run-tests palette
    /// command see the same in-flight run.
    let tests = TestRunModel()

    /// Right-pane visibility flag for the Ask panel — the canvas
    /// context menu nudges this on when it dispatches an Explain
    /// request so the user sees the streaming response.
    var askPanelRequested: Bool = false

    /// Build a Conventional "Explain this" prompt from a canvas
    /// statement and ship it to `aro ask` (#273). The Ask panel
    /// flips into view via askPanelRequested so the user sees the
    /// streaming reply.
    func askToExplain(node: CanvasNode, in project: Project) {
        let prompt = """
        Explain in 2-4 plain-English sentences what this ARO statement does, focusing on its effect on the surrounding feature set:

        \(node.summary)
        """
        aiCoPilot.send(prompt: prompt, in: project)
        askPanelRequested = true
    }

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
            lsp.start(project: project)
            // Same for the actions registry — runs `aro actions`
            // off the main actor and feeds the right-rail tab.
            actionsRegistry.reload(for: project)
            // Git status — populates file-tree decorations + branch
            // chip. Refreshed on file save and via the command palette.
            gitMonitor.refresh(for: project)
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
        if !openTabs.contains(url) {
            openTabs.append(url)
        }
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

    /// Close one of the open tabs. When closing the active tab the
    /// workspace falls back to the tab that was open just before
    /// it, or the previous neighbour if there is no history.
    func closeTab(_ url: URL) {
        guard let idx = openTabs.firstIndex(of: url) else { return }
        openTabs.remove(at: idx)
        if currentFile == url {
            if openTabs.isEmpty {
                currentFile = nil
                openAPIDocument?.tearDownWatcher()
                openAPIDocument = nil
                openAPISelectedNodeID = nil
            } else {
                let next = openTabs[max(idx - 1, 0)]
                openFile(next)
            }
        }
    }

    /// Cycle to the previous / next tab in the open-tab list.
    func cycleTab(by delta: Int) {
        guard !openTabs.isEmpty, let current = currentFile,
              let idx = openTabs.firstIndex(of: current) else { return }
        let nextIdx = (idx + delta + openTabs.count) % openTabs.count
        openFile(openTabs[nextIdx])
    }

    func setPaneMode(_ mode: PaneMode) {
        paneMode = mode
        guard let url = currentFile else { return }
        var sidecar = LayoutSidecar.load(for: url)
        sidecar.paneMode = mode
        try? sidecar.save(for: url)
    }
}

/// Adapter so a `String?` can drive a `sheet(item:)` modifier.
struct SymbolNameWrapper: Identifiable {
    let name: String
    var id: String { name }
}

/// Renders a 1×1 transparent button with a keyboard shortcut so
/// the parent view can wire a global accelerator without exposing
/// any visible chrome.
struct HiddenShortcutButton: View {
    let key: KeyEquivalent
    let modifiers: EventModifiers
    let action: () -> Void

    init(key: Character, modifiers: EventModifiers,
         action: @escaping () -> Void) {
        self.key = KeyEquivalent(key)
        self.modifiers = modifiers
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            EmptyView()
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
        .keyboardShortcut(key, modifiers: modifiers)
    }
}

enum BottomTab: String, CaseIterable, Identifiable {
    case console
    case terminal
    case tests

    var id: String { rawValue }
    var label: String {
        switch self {
        case .console:  return "Console"
        case .terminal: return "Terminal"
        case .tests:    return "Tests"
        }
    }
    var symbol: String {
        switch self {
        case .console:  return "rectangle.fill.on.rectangle.fill"
        case .terminal: return "terminal.fill"
        case .tests:    return "checkmark.diamond"
        }
    }
}

enum RightPaneMode: String, CaseIterable, Identifiable {
    case inspector
    case actions
    case metrics
    case coPilot

    var id: String { rawValue }

    var label: String {
        switch self {
        case .inspector: return "Inspector"
        case .actions:   return "Actions"
        case .metrics:   return "Metrics"
        case .coPilot:   return "Ask"
        }
    }

    var symbol: String {
        switch self {
        case .inspector: return "sidebar.right"
        case .actions:   return "puzzlepiece.fill"
        case .metrics:   return "chart.line.uptrend.xyaxis"
        case .coPilot:   return "sparkles"
        }
    }
}

enum SidebarTab: String, CaseIterable, Identifiable {
    case files, features, outline, plugins
    var id: String { rawValue }
    var label: String {
        switch self {
        case .files: return "Files"
        case .features: return "Features"
        case .outline: return "Outline"
        case .plugins: return "Plugins"
        }
    }
    var symbol: String {
        switch self {
        case .files: return "doc.text"
        case .features: return "square.grid.2x2"
        case .outline: return "list.bullet.indent"
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
    /// Per-workspace undo manager. SwiftUI doesn't supply a
    /// non-document UndoManager on its own; we create one, push it
    /// into the environment, and every canvas mutation (drag,
    /// auto-layout reset, node-edit apply) registers an undo
    /// operation against it. AppKit picks the standard Edit-menu
    /// "Undo …" / "Redo …" titles from this manager automatically.
    @State private var undoManager = UndoManager()
    @State private var bottomTab: BottomTab = .console
    /// Palette sheets: command (⌘⇧P), quick open (⌘P),
    /// find-in-project (⌘⇧F).
    @State private var showCommandPalette = false
    @State private var showQuickOpen = false
    @State private var showCommitOverlay = false
    @State private var commitModel = GitCommitModel()
    @State private var showHoverSheet = false
    @State private var hoverState = HoverSheetState()
    @State private var showCompletionSheet = false
    @State private var completionState = CompletionSheetState()
    @State private var showRenameSheet = false
    @State private var renameNewName: String = ""
    @State private var renameError: String? = nil
    @State private var showBlameSheet = false
    @State private var blameContent: String = ""
    @State private var showFindInProject = false
    @State private var findInProjectModel = FindInProjectModel()
    @State private var showSymbolPalette = false
    @State private var referencesSymbol: String? = nil
    /// Pre-run parameter dialog state. Populated by `playButton`
    /// when the project references `<parameter: NAME>`; the sheet
    /// renders, the user fills it, and Execute calls back into
    /// `startRun(project:parameters:)`.
    @State private var showRunParameters: Bool = false
    @State private var pendingRunParameters: [String] = []
    /// Probes `aro --version` once per workspace open and surfaces
    /// a banner when the version disagrees with SOLARO's build
    /// stamp (#287). Lives on the view so it's torn down with the
    /// window — the result isn't useful across workspaces.
    @StateObject private var aroProbe = AroBinaryProbe()
    /// Co-pilot (`aro ask`) process.
    // aiCoPilot moved onto WorkspaceController (#273) so canvas
    // context menus can dispatch prompts directly. Access as
    // `controller.aiCoPilot` everywhere.
    /// NavigationSplitView's column visibility, derived from
    /// `controller.sidebarShown` so the toggle in the title bar and
    /// SwiftUI's own auto-collapse both write to the same single
    /// source of truth. When the user toggles the sidebar away,
    /// we drop the window's minimum width accordingly; while the
    /// sidebar is shown, the window is held wide enough that
    /// NavigationSplitView never auto-collapses it.
    private var columnVisibilityBinding: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { controller.sidebarShown ? .all : .detailOnly },
            set: { new in
                controller.sidebarShown = (new != .detailOnly)
            }
        )
    }

    var body: some View {
        // Expose the workspace's UndoManager via a custom env key
        // so canvas-side code can register against it, and install
        // it on the hosting NSWindow via an NSViewRepresentable so
        // AppKit's responder chain (Edit menu ⌘Z) finds it when
        // the user isn't inside a text-editor first responder.
        workspaceBody
            .environment(\.solaroUndoManager, undoManager)
            .background(WorkspaceWindowUndoBinder(manager: undoManager))
            .task(id: ObjectIdentifier(undoManager)) {
                WorkspaceUndoRegistry.shared.push(undoManager)
                defer { WorkspaceUndoRegistry.shared.pop(undoManager) }
                try? await Task.sleep(nanoseconds: .max)
            }
    }

    @ViewBuilder
    private var workspaceBody: some View {
        VStack(spacing: 0) {
            if aroProbe.shouldShowBanner,
               let r = aroProbe.result {
                AroBinaryMismatchBanner(
                    binaryPath: r.binaryPath,
                    binaryVersion: r.binaryVersion ?? "unknown",
                    solaroVersion: r.solaroVersion,
                    onDismiss: { aroProbe.dismissCurrent() }
                )
            }
            NavigationSplitView(columnVisibility: columnVisibilityBinding) {
                SidebarPaneView(controller: controller)
                    .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
            } detail: {
                VStack(spacing: 0) {
                    if !controller.openTabs.isEmpty {
                        FileTabBar(controller: controller)
                        Divider().background(SolaroColor.divider)
                    }
                    if controller.currentFile != nil {
                        BreadcrumbView(controller: controller)
                        Divider().background(SolaroColor.divider)
                    }
                    CenterPaneView(controller: controller)
                }
                .inspector(isPresented: $controller.inspectorShown) {
                    rightPane
                        .inspectorColumnWidth(min: 260, ideal: 360, max: 480)
                }
            }
            .background(WorkspaceWindowSizer(
                sidebarShown: controller.sidebarShown,
                inspectorShown: controller.inspectorShown
            ))
            if showConsole {
                bottomPanel
                    .frame(height: 260)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            StatusBarView(
                controller: controller,
                onShowOpenAPIPalette: { showOpenAPIPalette = true },
                onShowTimeTravel: { showTimeTravel = true },
                onShowCommitOverlay: { openCommitOverlay() }
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
        .onChange(of: consoleProcess.executionTick) { _, _ in
            controller.lastExecutedAt = consoleProcess.lastExecutedAt
            controller.lastExecutedAtPerFeatureSet =
                consoleProcess.lastExecutedAtPerFeatureSet
            controller.errorLines = consoleProcess.errorLines
            controller.testResults = consoleProcess.testResults
            controller.repositoryValues = consoleProcess.repositoryValues
            controller.repositoryHistory = consoleProcess.repositoryHistory
            controller.pauseSymbols = consoleProcess.pauseSymbols
            controller.executionTick &+= 1
        }
        // When the canvas dispatches an Explain request, flip the
        // right pane to the Ask panel so the streaming response is
        // visible immediately (#273).
        .onChange(of: controller.askPanelRequested) { _, requested in
            guard requested else { return }
            controller.rightPaneMode = .coPilot
            controller.inspectorShown = true
            controller.askPanelRequested = false
        }
        // View-menu commands ("Show Console" / "Show Terminal" /
        // "Show Tests") post this notification. Open the bottom
        // panel and switch to the requested tab. Posted to every
        // workspace window — each one's onReceive runs, but the
        // user only sees the key window respond visually.
        .onReceive(
            NotificationCenter.default.publisher(for: .solaroShowBottomPanel)
        ) { note in
            guard
                let raw = note.userInfo?["tab"] as? String,
                let tab = BottomTab(rawValue: raw)
            else { return }
            bottomTab = tab
            showConsole = true
        }
        // Bounce back to the welcome screen the moment the last
        // editor tab closes. We compare oldValue → newValue so the
        // initial mount (which lands with openTabs empty before the
        // user opens anything) doesn't immediately dismiss the
        // workspace.
        .onChange(of: controller.openTabs.isEmpty) { wasEmpty, isEmpty in
            if isEmpty && !wasEmpty {
                onClose()
            }
        }
        // After a recorded run finishes, slurp the last-seen value
        // for every binding from .solaro/events.jsonl and merge it
        // into pauseSymbols. The canvas's existing hover popover
        // surfaces them as "live wire values" with no extra plumbing.
        .onChange(of: consoleProcess.state) { _, newState in
            if case .exited = newState {
                let live = LiveValueIndex.load(for: project)
                guard !live.isEmpty else { return }
                var merged = controller.pauseSymbols
                for (name, value) in live where merged[name] == nil {
                    merged[name] = value
                }
                controller.pauseSymbols = merged
            }
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
        .sheet(isPresented: $showRunParameters) {
            RunParametersSheet(
                parameters: pendingRunParameters,
                project: project,
                onCancel: { showRunParameters = false },
                onExecute: { values in
                    showRunParameters = false
                    showConsole = true
                    consoleProcess.startRun(
                        project: project, parameters: values
                    )
                }
            )
        }
        .sheet(isPresented: $showTimeTravel) {
            TimeTravelView(
                project: project,
                onClose: { showTimeTravel = false },
                onFrameChange: { record in
                    // Drive the canvas's "executing now" pulse and
                    // the symbol bag from the replayed frame so the
                    // canvas animates identically to a live run.
                    if let line = record.line, line > 0 {
                        controller.lastExecutedAt[line] = Date()
                    }
                    if let fs = record.featureSet, !fs.isEmpty {
                        controller.lastExecutedAtPerFeatureSet[fs] = Date()
                    }
                    for sym in record.symbols {
                        let v = ConsoleProcess.SymbolValue(
                            name: sym.name,
                            typeName: sym.typeName,
                            value: sym.value
                        )
                        controller.pauseSymbols[sym.name] = v
                    }
                    controller.executionTick &+= 1
                }
            )
        }
        .sheet(isPresented: $showCommandPalette) {
            PaletteView(
                title: "COMMANDS",
                placeholder: "Type a command…",
                items: CommandPaletteBuilder.items(
                    controller: controller,
                    project: project,
                    consoleProcess: consoleProcess,
                    onSwitchPaneMode: { controller.setPaneMode($0); showConsole = false },
                    onCloseProject: { onClose() },
                    onOpenQuickOpen: { showQuickOpen = true },
                    onOpenFindReplace: { showFindInProject = true },
                    onOpenOpenAPIPalette: { showOpenAPIPalette = true },
                    onOpenTimeTravel: { showTimeTravel = true },
                    onOpenAddPlugin: { controller.sidebarTab = .plugins },
                    onGoToDefinition: { goToDefinition() },
                    onHoverAtCaret: { hoverAtCaret() }
                ),
                onClose: { showCommandPalette = false }
            )
        }
        .sheet(isPresented: $showQuickOpen) {
            PaletteView(
                title: "QUICK OPEN",
                placeholder: "Type a filename…",
                items: QuickOpenBuilder.items(
                    controller: controller,
                    onOpen: { url in controller.openFile(url) }
                ),
                onClose: { showQuickOpen = false }
            )
        }
        .sheet(isPresented: $showCommitOverlay) {
            GitCommitSheet(
                project: project,
                model: commitModel,
                monitor: controller.gitMonitor,
                onClose: { showCommitOverlay = false }
            )
        }
        .sheet(isPresented: $showHoverSheet) {
            HoverSheet(state: hoverState, onClose: { showHoverSheet = false })
        }
        .sheet(isPresented: $showCompletionSheet) {
            CompletionSheet(
                state: completionState,
                onPick: { item in acceptCompletion(item) },
                onClose: { showCompletionSheet = false }
            )
        }
        .sheet(isPresented: $showRenameSheet) {
            RenameSheet(
                newName: $renameNewName,
                error: $renameError,
                onCancel: { showRenameSheet = false },
                onConfirm: { applyRename() }
            )
        }
        .sheet(isPresented: $showBlameSheet) {
            BlameSheet(
                content: blameContent,
                onClose: { showBlameSheet = false }
            )
        }
        .sheet(isPresented: $controller.showExtractActionSheet) {
            ExtractActionSheet(
                state: controller.extractActionState,
                onCancel: { controller.showExtractActionSheet = false },
                onConfirm: { node, url, name in
                    applyExtractAction(node: node, url: url, name: name)
                    controller.showExtractActionSheet = false
                }
            )
        }
        .sheet(isPresented: $showFindInProject) {
            FindInProjectSheet(
                model: findInProjectModel,
                project: project,
                projectModel: controller.model,
                onClose: { showFindInProject = false },
                onJump: { url, line in
                    controller.openFile(url)
                    controller.currentLine = line
                    showFindInProject = false
                }
            )
        }
        .sheet(isPresented: $showSymbolPalette) {
            PaletteView(
                title: "SYMBOLS",
                placeholder: "Jump to identifier…",
                items: SymbolPaletteBuilder.items(
                    controller: controller,
                    onJump: { url, line in
                        controller.openFile(url)
                        controller.currentLine = line
                    }
                ),
                onClose: { showSymbolPalette = false }
            )
        }
        .sheet(item: Binding(
            get: { referencesSymbol.map { SymbolNameWrapper(name: $0) } },
            set: { referencesSymbol = $0?.name }
        )) { wrapper in
            FindReferencesSheet(
                controller: controller,
                symbolName: wrapper.name,
                onClose: { referencesSymbol = nil },
                onJump: { url, line in
                    controller.openFile(url)
                    controller.currentLine = line
                    referencesSymbol = nil
                }
            )
        }
        .background {
            // Hidden buttons hold the three palette shortcuts. SwiftUI
            // keyboard shortcuts only fire from views in the hierarchy,
            // and we want them active regardless of focus — invisible
            // buttons accomplish that without leaking visual clutter.
            HiddenShortcutButton(key: "p", modifiers: [.command, .shift]) {
                showCommandPalette = true
            }
            HiddenShortcutButton(key: "p", modifiers: [.command]) {
                showQuickOpen = true
            }
            HiddenShortcutButton(key: "f", modifiers: [.command, .shift]) {
                showFindInProject = true
            }
            HiddenShortcutButton(key: "w", modifiers: [.command]) {
                if let url = controller.currentFile {
                    controller.closeTab(url)
                }
            }
            HiddenShortcutButton(key: "]", modifiers: [.command, .shift]) {
                controller.cycleTab(by: 1)
            }
            HiddenShortcutButton(key: "[", modifiers: [.command, .shift]) {
                controller.cycleTab(by: -1)
            }
            HiddenShortcutButton(key: "o", modifiers: [.command, .shift]) {
                showSymbolPalette = true
            }
            HiddenShortcutButton(key: "`", modifiers: [.control]) {
                bottomTab = .terminal
                showConsole = true
            }
            // Go to Definition — ⌃⌘D mirrors Xcode and most LSP UIs.
            HiddenShortcutButton(key: "d", modifiers: [.control, .command]) {
                goToDefinition()
            }
            HiddenShortcutButton(key: "h", modifiers: [.control, .command]) {
                hoverAtCaret()
            }
            // ⌃Space — LSP autocompletion (#254)
            HiddenShortcutButton(key: " ", modifiers: [.control]) {
                triggerCompletion()
            }
            // ⌃⌘R — rename refactor (#256)
            HiddenShortcutButton(key: "r", modifiers: [.control, .command]) {
                beginRename()
            }
            // ⇧⌥F — format document (#257)
            HiddenShortcutButton(key: "f", modifiers: [.option, .shift]) {
                formatDocument()
            }
            // ⌃⌘B — git blame for current file (#260)
            HiddenShortcutButton(key: "b", modifiers: [.control, .command]) {
                showBlame()
            }
        }
        .onAppear {
            controller.load()
            aroProbe.probe(binaryPath: ConsoleProcess.resolveAroBinary(near: project))
        }
        .onReceive(NotificationCenter.default
                    .publisher(for: .solaroFocusFile)) { note in
            // A double-click on an .aro in Finder routes through
            // RootView.onOpenURL and arrives here after the
            // project has loaded — focus the file in this window.
            if let url = note.userInfo?["url"] as? URL,
               url.path.hasPrefix(project.rootPath.path) {
                controller.openFile(url)
            }
        }
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

    /// Send `textDocument/definition` for the symbol at the current
    /// caret. We use the editor-reported column if we have one;
    /// otherwise we fall back to the first `<` on the line (which
    /// is where ARO identifier references start) or the first
    /// non-whitespace character.
    private func goToDefinition() {
        guard
            let url = controller.currentFile,
            let lineNumber = controller.currentLine,
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return }
        let lines = text.components(separatedBy: "\n")
        guard lineNumber - 1 < lines.count else { return }
        let line = lines[lineNumber - 1]
        let column = resolvedColumn(for: line)
        controller.lsp.definition(
            url: url,
            line0: lineNumber - 1,
            character0: column
        ) { location in
            guard let location else { return }
            controller.openFile(location.url)
            controller.currentLine = location.line
        }
    }

    /// Pop the Hover sheet for the current caret position. Same
    /// column heuristic as goToDefinition: use the editor-reported
    /// column when we have one, otherwise the first `<` or first
    /// non-whitespace character on the line.
    private func hoverAtCaret() {
        guard
            let url = controller.currentFile,
            let lineNumber = controller.currentLine,
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return }
        let lines = text.components(separatedBy: "\n")
        guard lineNumber - 1 < lines.count else { return }
        let line = lines[lineNumber - 1]
        let column = resolvedColumn(for: line)
        hoverState.content = ""
        hoverState.hasResult = false
        hoverState.isLoading = true
        hoverState.symbol = identifierAround(line: line, column: column)
        showHoverSheet = true
        controller.lsp.hover(
            url: url,
            line0: lineNumber - 1,
            character0: column
        ) { content in
            hoverState.isLoading = false
            hoverState.hasResult = true
            hoverState.content = content ?? ""
        }
    }

    /// Best-effort: pluck the identifier surrounding the column for
    /// the sheet's title bar. Doesn't influence the actual LSP
    /// request — that uses the column directly.
    private func identifierAround(line: String, column: Int) -> String? {
        guard column >= 0, column <= line.count else { return nil }
        let chars = Array(line)
        let i = min(column, chars.count - 1)
        let isIdent: (Character) -> Bool = { c in
            c.isLetter || c.isNumber || c == "-" || c == "_"
        }
        guard i >= 0, i < chars.count, isIdent(chars[i]) else { return nil }
        var start = i
        while start > 0, isIdent(chars[start - 1]) { start -= 1 }
        var end = i
        while end < chars.count - 1, isIdent(chars[end + 1]) { end += 1 }
        return String(chars[start...end])
    }

    // MARK: - LSP autocompletion (#254)

    private func triggerCompletion() {
        guard
            let url = controller.currentFile,
            let lineNumber = controller.currentLine,
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return }
        let lines = text.components(separatedBy: "\n")
        guard lineNumber - 1 < lines.count else { return }
        let column = resolvedColumn(for: lines[lineNumber - 1])

        completionState.items = []
        completionState.isLoading = true
        completionState.hasResult = false
        completionState.selection = nil
        showCompletionSheet = true

        controller.lsp.completion(
            url: url, line0: lineNumber - 1, character0: column
        ) { items in
            completionState.items = items
            completionState.isLoading = false
            completionState.hasResult = true
            completionState.selection = items.first?.id
        }
    }

    private func acceptCompletion(_ item: AROLSPClient.CompletionItem) {
        showCompletionSheet = false
        guard
            let url = controller.currentFile,
            let lineNumber = controller.currentLine,
            var text = try? String(contentsOf: url, encoding: .utf8)
        else { return }
        // Insert the chosen text at the current caret position.
        // Simplification: insert at the end of the current line
        // followed by a space if no caret column tracked.
        let lines = text.components(separatedBy: "\n")
        guard lineNumber - 1 < lines.count else { return }
        let column = resolvedColumn(for: lines[lineNumber - 1])
        var lineStarts: [Int] = [0]
        let ns = text as NSString
        for i in 0..<ns.length {
            if ns.character(at: i) == 0x0A { lineStarts.append(i + 1) }
        }
        let insertOffset = lineStarts[lineNumber - 1] + column
        guard insertOffset <= ns.length else { return }
        text = ns.replacingCharacters(
            in: NSRange(location: insertOffset, length: 0),
            with: item.insertText
        )
        try? text.write(to: url, atomically: true, encoding: .utf8)
        controller.lsp.didChange(url: url, text: text)
        controller.openFile(url)
    }

    // MARK: - LSP rename (#256)

    private func beginRename() {
        renameNewName = ""
        renameError = nil
        showRenameSheet = true
    }

    private func applyRename() {
        guard
            let url = controller.currentFile,
            let lineNumber = controller.currentLine,
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return }
        let lines = text.components(separatedBy: "\n")
        guard lineNumber - 1 < lines.count else { return }
        let column = resolvedColumn(for: lines[lineNumber - 1])
        let newName = renameNewName.trimmingCharacters(in: .whitespaces)
        guard !newName.isEmpty else {
            renameError = "Enter a new name."
            return
        }
        controller.lsp.rename(
            url: url, line0: lineNumber - 1, character0: column,
            newName: newName
        ) { edits, error in
            if let edits {
                _ = LSPEditApplier.apply(edits: edits, through: controller)
                showRenameSheet = false
            } else {
                renameError = error ?? "Rename failed."
            }
        }
    }

    // MARK: - LSP formatting (#257)

    private func formatDocument() {
        guard let url = controller.currentFile else { return }
        controller.lsp.format(url: url) { edits in
            guard !edits.isEmpty else { return }
            _ = LSPEditApplier.apply(edits: edits, through: controller)
        }
    }

    // MARK: - Git blame (#260)

    private func showBlame() {
        guard let url = controller.currentFile else { return }
        let projectURL = project.rootPath
        blameContent = "Loading…"
        showBlameSheet = true
        Task.detached(priority: .utility) {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            task.arguments = ["git", "blame", "--date=short", url.path]
            task.currentDirectoryURL = projectURL
            let out = Pipe(), err = Pipe()
            task.standardOutput = out
            task.standardError = err
            do {
                try task.run()
                task.waitUntilExit()
                let data = out.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8) ?? ""
                let result = task.terminationStatus == 0
                    ? text
                    : "git blame failed (exit \(task.terminationStatus))"
                await MainActor.run { blameContent = result }
            } catch {
                await MainActor.run {
                    blameContent = "Could not run git blame: \(error.localizedDescription)"
                }
            }
        }
    }

    private func resolvedColumn(for line: String) -> Int {
        if let tracked = controller.currentColumn,
           tracked >= 0,
           tracked <= line.count
        { return tracked }
        if let bracket = line.firstIndex(of: "<") {
            return line.distance(from: line.startIndex,
                                 to: line.index(after: bracket))
        }
        if let nonSpace = line.firstIndex(where: { !$0.isWhitespace }) {
            return line.distance(from: line.startIndex, to: nonSpace)
        }
        return 0
    }

    /// Apply the Extract-as-Action refactor: rewrite the call site
    /// to `Application.<Name>` and append a new `(<Name>: Action)`
    /// feature set at the end of the file. The file is then re-
    /// parsed so the canvas + breadcrumbs catch up.
    private func applyExtractAction(node: CanvasNode, url: URL, name: String) {
        guard let source = try? String(contentsOf: url, encoding: .utf8) else { return }
        guard let result = ExtractActionRefactor.apply(
            source: source, node: node, actionName: name
        ) else { return }
        try? result.newSource.write(to: url, atomically: true, encoding: .utf8)
        controller.openFile(url)  // reparses + refreshes graph
        controller.currentLine = result.newCallSiteLine
    }

    /// Pop the commit overlay open. Reset the model's transient
    /// state (last error, last message) so each invocation starts
    /// fresh — the AI suggestion task itself runs from inside the
    /// sheet's `.task` modifier.
    private func openCommitOverlay() {
        commitModel.commitError = nil
        commitModel.message = ""
        commitModel.suggestion = ""
        commitModel.suggestionFailed = false
        commitModel.suggestionError = nil
        showCommitOverlay = true
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

    /// Bottom panel hosting Console + Terminal as switchable tabs.
    @ViewBuilder
    private var bottomPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(BottomTab.allCases) { tab in
                    Button {
                        bottomTab = tab
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: tab.symbol)
                                .font(.system(size: 10))
                            Text(tab.label)
                                .font(SolaroFont.caption)
                        }
                        .padding(.horizontal, SolaroSpace.s)
                        .padding(.vertical, 4)
                        .foregroundStyle(bottomTab == tab
                                         ? SolaroColor.textPrimary
                                         : SolaroColor.textTertiary)
                        .background(
                            VStack {
                                Spacer()
                                Rectangle()
                                    .fill(bottomTab == tab
                                          ? SolaroColor.accent
                                          : Color.clear)
                                    .frame(height: 2)
                            }
                        )
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Button {
                    showConsole = false
                } label: {
                    Label("Hide", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .padding(.trailing, SolaroSpace.s)
            }
            .padding(.leading, SolaroSpace.s)
            .background(SolaroColor.surface)
            Divider().background(SolaroColor.divider)
            switch bottomTab {
            case .console:
                ConsolePanelView(process: consoleProcess) {
                    showConsole = false
                }
            case .terminal:
                TerminalView(workingDirectory: project.rootPath)
                    .background(SolaroColor.backdrop)
            case .tests:
                TestsPanel(project: project, model: controller.tests)
            }
        }
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
            case .metrics:
                // Raw AppKit panel — the SwiftUI version crashes on
                // macOS 26 because each snapshot re-renders the
                // NSHostingView subtree, calls
                // `NSHostingView.setNeedsUpdate()` inside an
                // in-flight constraint pass, and the inspector
                // column's SplitViewChildController hard-asserts.
                // The AppKit panel updates text-field stringValues
                // only, so no setNeedsUpdate chain ever fires.
                MetricsAppKitPanel(process: consoleProcess)
            case .coPilot:
                AICoPilotPanel(
                    project: project,
                    process: controller.aiCoPilot,
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
            testButton
            statusPip
            foldToggle
            minimapToggle
            inspectorToggle
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

    /// Run-button click handler. If the project's source references
    /// any `<parameter: NAME>`, opens the run-parameters sheet so the
    /// user can fill them in (pre-filled from the last successful
    /// run); otherwise starts the run immediately. The sheet's
    /// Execute button calls `consoleProcess.startRun(project:parameters:)`.
    private func requestRun() {
        // Prefer the cached programs dict (cheap, in-memory) but
        // fall back to a fresh disk scan when it's still empty —
        // happens on a fresh project the very first time the user
        // clicks Run before SwiftUI has finished its post-mount
        // `controller.load()` pass (#?). Without the fallback the
        // dialog would render with zero fields and the user
        // would press Execute against an empty parameter set.
        var needed = RunParameterScanner.scan(programs: controller.programs)
        if needed.isEmpty, controller.programs.isEmpty {
            needed = RunParameterScanner.scanFromDisk(
                projectRoot: project.rootPath
            )
        }
        if needed.isEmpty {
            showConsole = true
            consoleProcess.startRun(project: project)
        } else {
            pendingRunParameters = needed
            showRunParameters = true
        }
    }

    private var playButton: some View {
        Button {
            if isRunning {
                consoleProcess.stop()
            } else {
                requestRun()
            }
        } label: {
            Label(
                isRunning ? "Stop" : "Run",
                systemImage: isRunning ? "stop.fill" : "play.fill"
            )
        }
        .help(isRunning
              ? "Stop the running `aro run` process"
              : "Run `aro run` and stream its output to the console")
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

    private var testButton: some View {
        Button {
            showConsole = true
            consoleProcess.startTests(project: project)
        } label: {
            Label("Test", systemImage: "checkmark.diamond")
        }
        .disabled(isRunning)
        .help("Run `aro test` and stream output to the console (⌃⌘U)")
        .keyboardShortcut("u", modifiers: [.control, .command])
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

    @AppStorage(SolaroPrefs.editorFolded.rawValue)
    private var editorFolded: Bool = false
    @AppStorage(SolaroPrefs.editorMinimap.rawValue)
    private var editorMinimap: Bool = false

    private var foldToggle: some View {
        Button {
            editorFolded.toggle()
        } label: {
            Label(
                editorFolded ? "Expand bodies" : "Fold bodies",
                systemImage: editorFolded
                    ? "chevron.down.square.fill"
                    : "chevron.right.square"
            )
        }
        .help("Show feature-set bodies as `{ … N statements }` (read-only)")
    }

    private var minimapToggle: some View {
        Button {
            editorMinimap.toggle()
        } label: {
            Label(
                editorMinimap ? "Hide minimap" : "Show minimap",
                systemImage: editorMinimap
                    ? "rectangle.portrait.righthalf.inset.filled.arrow.right"
                    : "rectangle.portrait.righthalf.inset.filled"
            )
        }
        .help("Toggle the minimap overview on the right edge of the editor")
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

}

// Real SidebarPaneView lives in Sidebar.swift (Phase 5).

// Real CenterPaneView lives in CenterPane.swift (Phase 7 onwards).

// Real InspectorPaneView lives in Inspector.swift (Phase 6).

/// Reaches up to the hosting NSWindow and pins its `contentMinSize`
/// to a value that always fits the *currently shown* panels plus a
/// reasonable center pane. This keeps two invariants:
///   1. The user can never drag the window narrower than what the
///      visible columns need, so the center always grows/shrinks
///      while the side rails stay put at their declared widths.
///   2. The floor is large enough that NavigationSplitView never
///      auto-collapses a column SwiftUI thinks doesn't fit. The
///      thresholds were measured empirically on macOS 26 — above
///      these floors the split view leaves columns alone; below
///      them it silently zeros the sidebar / overflows the inspector.
private struct WorkspaceWindowSizer: NSViewRepresentable {
    let sidebarShown: Bool
    let inspectorShown: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { apply(to: view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { apply(to: nsView.window) }
    }

    private func apply(to window: NSWindow?) {
        guard let window else { return }
        let width: CGFloat = {
            switch (sidebarShown, inspectorShown) {
            case (true,  true):  return 1200  // sidebar + center + inspector
            case (true,  false): return 800   // sidebar + center
            case (false, true):  return 900   // center + inspector
            case (false, false): return 700   // center only
            }
        }()
        let target = NSSize(width: width, height: 800)
        guard window.contentMinSize != target else { return }
        window.contentMinSize = target
        // If the window is currently below the new floor, snap it up
        // so layout never lands in the auto-collapse band.
        var frame = window.frame
        let extraH = frame.height - window.contentLayoutRect.height
        let needW = max(frame.width, target.width)
        let needH = max(frame.height, target.height + extraH)
        if needW != frame.width || needH != frame.height {
            frame.size = NSSize(width: needW, height: needH)
            window.setFrame(frame, display: true, animate: false)
        }
    }
}

/// Walks up from a SwiftUI background view to the hosting NSWindow
/// and installs `manager` as the window delegate's "return undo
/// manager" so AppKit's standard responder chain — the one Edit →
/// Undo and ⌘Z route through — finds it whenever no first
/// responder in the chain has its own (e.g. when the canvas is
/// focused). STTextView still gets character-level undo via its
/// own first-responder undoManager because the chain consults the
/// responder before the window delegate.
struct WorkspaceWindowUndoBinder: NSViewRepresentable {
    let manager: UndoManager

    func makeNSView(context: Context) -> NSView {
        // No-op placeholder. We don't actually install the
        // UndoManager via the window delegate any more — SwiftUI
        // races us for that slot and overwriting it breaks SwiftUI's
        // own window plumbing. Instead `SolaroUndoCommand` picks
        // the right manager at click time by walking the responder
        // chain itself. Leaving this view in place so the call
        // site stays unchanged.
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(manager: manager)
    }

    final class Coordinator: NSObject, NSWindowDelegate {
        let manager: UndoManager
        init(manager: UndoManager) { self.manager = manager }
        func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
            manager
        }
    }
}

/// Custom Environment key for the workspace's UndoManager. SwiftUI
/// 6 made the built-in `\.undoManager` read-only, so canvas code
/// pulls the manager from this key instead.
private struct SolaroUndoManagerKey: EnvironmentKey {
    static let defaultValue: UndoManager? = nil
}
extension EnvironmentValues {
    var solaroUndoManager: UndoManager? {
        get { self[SolaroUndoManagerKey.self] }
        set { self[SolaroUndoManagerKey.self] = newValue }
    }
}

/// Process-wide registry that knows which workspace's UndoManager
/// the app-level Edit-menu commands should act on. We use this
/// instead of `@FocusedValue` because that route was returning nil
/// inside `CommandGroup` closures — the menu items stayed disabled
/// even after a successful registerUndo, because the focused-scene
/// value wasn't propagating into the CommandGroup builder.
///
/// `WorkspaceView` pushes its manager on appear and pops it on
/// disappear. The most-recently-pushed manager is treated as the
/// "current" one — close enough for single-window flows, and a
/// reasonable approximation for multi-window (the front window
/// generally pushed most recently).
@Observable
@MainActor
final class WorkspaceUndoRegistry {
    static let shared = WorkspaceUndoRegistry()
    private init() {}
    /// LIFO stack of managers. `current` is the last one pushed.
    /// Stored as a tuple of (instance pointer, manager) so a
    /// pop matches by identity even after the manager mutates.
    private var stack: [UndoManager] = []
    /// Bumped on every push / pop / undo-stack notification so
    /// SwiftUI command bodies that read this registry re-render.
    private(set) var tick: UInt64 = 0
    var current: UndoManager? { stack.last }

    func push(_ mgr: UndoManager) {
        stack.append(mgr)
        tick &+= 1
    }
    func pop(_ mgr: UndoManager) {
        if let idx = stack.lastIndex(where: { $0 === mgr }) {
            stack.remove(at: idx)
        }
        tick &+= 1
    }
    /// Called when an UndoManager fires its change notification so
    /// the menu items re-evaluate `canUndo` / `canRedo`.
    func noteUndoChange() { tick &+= 1 }
}

