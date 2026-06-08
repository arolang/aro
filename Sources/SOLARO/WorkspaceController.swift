// ============================================================
// WorkspaceController.swift
// SOLARO — @Observable state for an open workspace
// ============================================================
//
// Extracted from Workspace.swift (#289 step 1). Holds every
// piece of state the workspace view + its children share: the
// loaded project, parsed programs, pane mode, sidebar state,
// test results mirror, canvas selection, async load task, and
// the various UI state slots toolbar buttons / sheets read.

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
    /// Current rows held by each repository (#284 step 3). Mirrored
    /// from `ConsoleProcess.repositoryRecords` and consumed by
    /// `RepoCard` to render the inline table.
    var repositoryRecords: [String: [[String: String]]] = [:]

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

    // MARK: - Find in current file (⌘F)

    /// True when the in-editor find bar is visible. Toggled by
    /// the ⌘F shortcut and the bar's close button. Lives on the
    /// controller so the shortcut can flip it from outside the
    /// CenterPane subtree.
    var editorFindActive: Bool = false

    /// Live query typed into the find bar. The bar binds to this
    /// directly; the workspace recomputes match ranges on change.
    var editorFindQuery: String = ""

    /// Match selection the editor should apply on the next
    /// `updateNSView` pass — UTF-16 offsets into the editor's
    /// document. Cleared after the editor consumes it (the
    /// editor watches `editorFindSelectionTick` to know when to
    /// re-apply).
    var editorFindSelection: NSRange?

    /// Bumped each time a new selection is pushed. The editor
    /// stores the last tick it consumed and only applies when
    /// the tick advances; that way re-entering the same range
    /// (e.g. wrapping around to match 0) still works.
    var editorFindSelectionTick: UInt64 = 0

    func requestEditorFindSelection(_ range: NSRange) {
        editorFindSelection = range
        editorFindSelectionTick &+= 1
    }

    // MARK: - Global search (toolbar field)

    /// Live result list for the toolbar search. Recomputed on
    /// every keystroke into the search field; consumed by the
    /// results panel rendered as a workspace-body overlay (not
    /// a popover — SwiftUI popovers anchored to a toolbar item
    /// don't reliably display on macOS, which is why the panel
    /// has to live outside the toolbar tree).
    var globalSearchHits: [GlobalSearchHit] = []

    /// 0-indexed position of the keyboard-/hover-highlighted
    /// row in `globalSearchHits`. Up / Down move it; Return
    /// opens the hit at this index; hover sets it.
    var globalSearchSelectedIndex: Int = 0

    /// True when the results panel should be visible — set to
    /// true when search text becomes non-empty, false on Esc,
    /// on focus loss, or after a hit is opened.
    var globalSearchPanelVisible: Bool = false

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
    /// True while `load()` is parsing the project's `.aro` files
    /// in the background (#286). The Run / Debug / Test buttons
    /// gate on this so the user can't fire a launch with a
    /// half-populated programs cache. Defaults to false because
    /// the very first load() is kicked off from `.onAppear`.
    var isLoading: Bool = false
    /// In-flight load task — cancelled when the user reloads or
    /// switches projects (latter not reachable today; same window
    /// stays bound to one project), so an old slow parse can't
    /// land on top of a fresh one.
    private var loadTask: Task<Void, Never>?

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
        // Cancel any in-flight load — happens when the user picks
        // "Reload" from a future menu, or when SwiftUI re-fires
        // .onAppear during a window transition.
        loadTask?.cancel()
        isLoading = true
        parseErrors.removeAll()
        let projectRoot = project
        loadTask = Task { [weak self] in
            // File discovery + parse off the main actor (#286). A
            // small project finishes in single-digit ms; a large
            // one with dozens of files no longer blocks the first
            // body render. Cancellation checks happen between
            // files so a re-load shuts a long parse down promptly.
            let parsed: ParseResult? = await Task.detached(priority: .userInitiated) {
                do {
                    let loaded = try ProjectModel.load(projectRoot)
                    var programs: [URL: Program] = [:]
                    var errors: [URL: String] = [:]
                    for url in loaded.sourceFiles {
                        if Task.isCancelled { return nil }
                        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                            errors[url] = "Could not read file."
                            continue
                        }
                        do {
                            programs[url] = try Parser.parse(text)
                        } catch {
                            errors[url] = "\(error)"
                        }
                    }
                    return ParseResult(model: loaded,
                                       programs: programs,
                                       errors: errors)
                } catch {
                    return ParseResult(error: error)
                }
            }.value

            guard let self else { return }
            await MainActor.run {
                self.applyParse(parsed)
                self.isLoading = false
                self.loadTask = nil
            }
        }
    }

    private struct ParseResult: Sendable {
        var model: ProjectModel?
        var programs: [URL: Program]
        var errors: [URL: String]
        var error: Error?

        init(model: ProjectModel,
             programs: [URL: Program],
             errors: [URL: String]) {
            self.model = model
            self.programs = programs
            self.errors = errors
            self.error = nil
        }

        init(error: Error) {
            self.model = nil
            self.programs = [:]
            self.errors = [:]
            self.error = error
        }
    }

    private func applyParse(_ result: ParseResult?) {
        guard let result else { return }   // cancelled
        if let error = result.error {
            loadError = "Failed to load project: \(error.localizedDescription)"
            return
        }
        guard let loaded = result.model else { return }
        self.model = loaded
        self.programs = result.programs
        for (url, msg) in result.errors {
            parseErrors[url] = msg
        }
        if let first = loaded.sourceFiles.first, currentFile == nil {
            openFile(first)
        }
        RecentProjects.remember(project)
        // Side-effect services (LSP, actions registry, git
        // monitor) keep their original onAppear-time fire order
        // so behaviour outside of programs is unchanged.
        lsp.start(project: project)
        actionsRegistry.reload(for: project)
        gitMonitor.refresh(for: project)
        for url in loaded.sourceFiles {
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                lsp.didOpen(url: url, text: text)
            }
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

