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
    /// Active pane mode. `private(set)` so every mutation goes
    /// through `setPaneMode(_:)`, which persists to disk. This
    /// keeps in-memory state, the per-file `LayoutSidecar`, and
    /// the view all reading from one direction (memory → disk on
    /// mutation) — call sites that wrote here directly used to
    /// drift the sidecar (#300).
    private(set) var paneMode: PaneMode = .canvas
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

    /// SwiftUI-subscription mirror of the active console
    /// session's debugger snapshot. The session
    /// (`ConsoleProcess.debuggerState`) is the source of truth;
    /// `WorkspaceView`'s onChange handlers copy it here so views
    /// observing the controller still see updates without a
    /// direct dependency on the session. Forwarding accessors
    /// below preserve existing call sites (#306).
    var debuggerState = DebuggerState()

    var pausedLine: Int? {
        get { debuggerState.pausedLine }
        set { debuggerState.pausedLine = newValue }
    }
    var pauseSymbols: [String: ConsoleProcess.SymbolValue] {
        get { debuggerState.pauseSymbols }
        set { debuggerState.pauseSymbols = newValue }
    }
    var lastExecutedAt: [Int: Date] {
        get { debuggerState.lastExecutedAt }
        set { debuggerState.lastExecutedAt = newValue }
    }
    var lastExecutedAtPerFeatureSet: [String: Date] {
        get { debuggerState.lastExecutedAtPerFeatureSet }
        set { debuggerState.lastExecutedAtPerFeatureSet = newValue }
    }
    var errorLines: [Int: String] {
        get { debuggerState.errorLines }
        set { debuggerState.errorLines = newValue }
    }
    var executionTick: UInt64 {
        get { debuggerState.executionTick }
        set { debuggerState.executionTick = newValue }
    }
    /// Most recent value the runtime saw flowing into each
    /// repository, keyed by repository object name.
    /// Repository payloads (values + rolling history + flattened
    /// records) extracted from the controller in #299 step 1.
    /// Old flat properties forward to this struct so existing
    /// call sites compile unchanged.
    var repositoryState = RepositoryState()
    var repositoryValues: [String: ConsoleProcess.SymbolValue] {
        get { repositoryState.values }
        set { repositoryState.values = newValue }
    }
    var repositoryHistory: [String: [ConsoleProcess.SymbolValue]] {
        get { repositoryState.history }
        set { repositoryState.history = newValue }
    }
    var repositoryRecords: [String: [[String: String]]] {
        get { repositoryState.records }
        set { repositoryState.records = newValue }
    }

    /// Outcome of the most recent `aro test` run, keyed by test
    /// feature-set name (e.g. `"length-of-hello"`). Forwards to
    /// the session-owned snapshot — same lifecycle as the other
    /// debugger/execution state above (#306).
    var testResults: [String: TestNodeResult] {
        get { debuggerState.testResults }
        set { debuggerState.testResults = newValue }
    }

    /// Multi-node selection on the canvas (#266). Plain click sets
    /// a single ID, ⌘-click toggles membership, the rubber-band on
    /// blank space replaces the set with everything inside the
    /// rect. Empty when nothing is selected. The single-node
    /// `selectedNode` mirror below stays in sync with the *most
    /// recently* added member so the Inspector form keeps showing
    /// one node at a time even when several are highlighted.
    /// Canvas selection + drag bundle (#299). Old flat fields
    /// forward through.
    var canvasSelection = CanvasSelectionState()
    var selectedNodeIDs: Set<String> {
        get { canvasSelection.selectedIDs }
        set { canvasSelection.selectedIDs = newValue }
    }
    var selectedNode: CanvasNode? {
        get { canvasSelection.selectedNode }
        set { canvasSelection.selectedNode = newValue }
    }
    var selectedNodeSource: String? {
        get { canvasSelection.selectedNodeSource }
        set { canvasSelection.selectedNodeSource = newValue }
    }
    /// Mirror for the repository-entity selection. Mutually
    /// exclusive with `selectedNode` — set one to nil before
    /// pushing the other so the inspector only ever paints one
    /// editor form at a time.
    var selectedRepository: RepositoryNode? {
        get { canvasSelection.selectedRepository }
        set { canvasSelection.selectedRepository = newValue }
    }

    /// Wipe the rendered records + the most-recent value + the
    /// rolling history for one repository. Used by the trash
    /// icon on `RepoCard` and the "Clear all" button in the
    /// inspector. Purely UI-local: the next runtime run will
    /// repopulate from observed events / `.store` seeds.
    func clearRepositoryEntries(named name: String) {
        repositoryRecords[name] = []
        repositoryValues.removeValue(forKey: name)
        repositoryHistory.removeValue(forKey: name)
    }

    /// Remove a single row from a repository's in-memory record
    /// list. Same caveat as `clearRepositoryEntries` — the next
    /// run rebuilds the table from observed events.
    func removeRepositoryEntry(repository name: String, at index: Int) {
        guard var rows = repositoryRecords[name],
              rows.indices.contains(index) else { return }
        rows.remove(at: index)
        repositoryRecords[name] = rows
    }

    /// Replace one field in a repository row. The record table is
    /// flat `[field: rendered]`, so editing replaces the rendered
    /// string verbatim — no type coercion. Outside callers should
    /// trim whitespace before passing the value through.
    func updateRepositoryEntry(
        repository name: String,
        at index: Int,
        field: String,
        value: String
    ) {
        guard var rows = repositoryRecords[name],
              rows.indices.contains(index) else { return }
        rows[index][field] = value
        repositoryRecords[name] = rows
    }
    var liveNodes: [String: CGPoint] {
        get { canvasSelection.liveNodes }
        set { canvasSelection.liveNodes = newValue }
    }
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

    /// Whichever item in the Files panel sidebar is highlighted —
    /// file OR directory. Distinct from `currentFile`, which only
    /// updates when the user opens an editable file. Without this
    /// the Move-to-Trash / Reveal / Copy-Path commands defaulted
    /// to `currentFile` and silently acted on the last-opened file
    /// instead of the folder the user had just clicked on (#?).
    var treeFocus: URL?

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
    /// Find-in-file (⌘F) state bundle (#299).
    var editorFind = EditorFindState()
    var editorFindActive: Bool {
        get { editorFind.active }
        set { editorFind.active = newValue }
    }
    var editorFindQuery: String {
        get { editorFind.query }
        set { editorFind.query = newValue }
    }
    var editorFindSelection: NSRange? {
        get { editorFind.selection }
        set { editorFind.selection = newValue }
    }
    var editorFindSelectionTick: UInt64 {
        get { editorFind.selectionTick }
        set { editorFind.selectionTick = newValue }
    }

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
    /// Toolbar global-search results-panel state (#299).
    var globalSearch = GlobalSearchPanelState()
    var globalSearchHits: [GlobalSearchHit] {
        get { globalSearch.hits }
        set { globalSearch.hits = newValue }
    }
    var globalSearchSelectedIndex: Int {
        get { globalSearch.selectedIndex }
        set { globalSearch.selectedIndex = newValue }
    }
    var globalSearchPanelVisible: Bool {
        get { globalSearch.panelVisible }
        set { globalSearch.panelVisible = newValue }
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
    // `@ObservationIgnored` + `nonisolated` so the deinit (also
    // non-isolated) can cancel the in-flight task without an actor
    // hop. `Task` is already `Sendable`; the only other writer is
    // the MainActor-isolated `load()`. @Observable's macro expansion
    // would otherwise reject `nonisolated` on the tracked storage.
    @ObservationIgnored
    private nonisolated(unsafe) var loadTask: Task<Void, Never>?

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

    deinit {
        // Issue #311: cancel any in-flight load on workspace
        // teardown so the detached parse task can't fire its
        // MainActor.run completion handler after the controller
        // (and the views that observe it) are gone.
        // `Task.cancel()` is nonisolated and thread-safe to call
        // from a non-isolated deinit; the parse closure checks
        // `Task.isCancelled` between files and exits promptly.
        loadTask?.cancel()
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
        // One-shot migration of legacy per-file `*.layout.json`
        // files into the consolidated `<root>/.layout.json`. Idle
        // after the first project open since later passes find no
        // legacy files to fold in.
        ProjectLayoutStore.migrateLegacySidecars(
            at: loaded.root.rootPath
        )
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

    /// Bumped whenever an external actor (the AI co-pilot's file
    /// tools) changes a file on disk. The center pane's text cache
    /// keys its load task on this so the editor reloads even though
    /// `currentFile` didn't change.
    var fileReloadTick: Int = 0

    // MARK: - AI co-pilot live editing (#…)

    /// A single co-pilot edit to apply into the OPEN editor's STTextView,
    /// undoably and on the fly — instead of the destructive disk-reload path
    /// that wipes the undo stack. `oldString` empty ⇒ replace the whole file.
    struct AIEditCommand: Equatable {
        let id: UInt64
        let url: URL
        let oldString: String
        let newString: String
    }

    /// The pending live edit for the active editor. `AROCodeEditor` observes
    /// it (keyed on `id`) and applies it via `STTextView.replaceCharacters`.
    var pendingAIEdit: AIEditCommand?
    private var aiEditSeq: UInt64 = 0

    /// Live editor text per open file, mirrored from the editor's binding so
    /// the co-pilot's context sees the user's current (even mid-edit) buffer
    /// rather than depending on the keystroke-autosave side effect. Seeded on
    /// file load, updated on every keystroke.
    var liveEditorText: [URL: String] = [:]

    /// Current live text for `url`: the editor buffer when known, else disk.
    func liveText(for url: URL) -> String? {
        let std = url.standardizedFileURL
        return liveEditorText[std] ?? (try? String(contentsOf: std, encoding: .utf8))
    }

    /// Route a co-pilot edit into the OPEN editor buffer. Returns true when
    /// this file is the active editor and the edit can be placed (so the file
    /// tool skips its disk write); false to fall back to a disk write + reload.
    /// Mirrors `edit_file`'s exact-unique-match rule against the live buffer.
    func applyAIEditToOpenBuffer(url: URL, oldString: String, newString: String) -> Bool {
        let std = url.standardizedFileURL
        guard currentFile?.standardizedFileURL == std else { return false }
        let buffer = liveEditorText[std] ?? (try? String(contentsOf: std, encoding: .utf8)) ?? ""
        if !oldString.isEmpty {
            // Exactly one occurrence, matching the disk-path semantics.
            guard buffer.components(separatedBy: oldString).count == 2 else { return false }
        }
        aiEditSeq &+= 1
        pendingAIEdit = AIEditCommand(id: aiEditSeq, url: std,
                                      oldString: oldString, newString: newString)
        return true
    }

    /// A file was modified on disk behind the editor's back (AI
    /// co-pilot tool call): reparse it, resync the LSP, refresh git
    /// status, and force the text cache to reload when it's showing.
    func noteExternalFileChange(_ url: URL) {
        let std = url.standardizedFileURL
        if let text = try? String(contentsOf: std, encoding: .utf8) {
            do {
                programs[std] = try Parser.parse(text)
                parseErrors.removeValue(forKey: std)
            } catch {
                parseErrors[std] = "\(error)"
            }
            lsp.didChange(url: std, text: text)
            // Skip the destructive whole-file reload when the open buffer
            // already matches disk — i.e. the co-pilot applied this edit LIVE
            // into the editor (which preserves undo and the caret). Only a
            // genuine behind-the-back write (buffer ≠ disk) forces a reload.
            if currentFile?.standardizedFileURL == std, liveEditorText[std] != text {
                fileReloadTick += 1
            }
        }
        gitMonitor.refresh(for: project)
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

