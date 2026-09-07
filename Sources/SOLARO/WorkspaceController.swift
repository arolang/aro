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

    /// Built-in + project-defined ARO patterns for the right-rail
    /// Snippets tab (#242). Custom entries come from
    /// `.solaro/snippets/*.yaml` and are re-read on project load.
    let snippets = SnippetLibrary()

    /// Splices a snippet in at the editor caret. Owned by
    /// CenterPane (it has the buffer, the caret, and the reparse
    /// path); set on appear, the same way `nodeEditApply` is. Nil
    /// until a file is open, which is what disables the row button.
    var insertSnippetAtCaret: ((AROSnippet) -> Void)?

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

    /// `willTerminateNotification` token — removed in deinit.
    @ObservationIgnored
    private nonisolated(unsafe) var terminationObserver: NSObjectProtocol?

    init(project: Project) {
        self.project = project
        // Mirror ConsoleProcess: tear the workspace's subprocesses
        // down on ⌘Q (GitLab #529). Without this, `aro lsp` and
        // every open notebook's `aro repl --json` were simply
        // abandoned on app exit — a kernel mid-cell doesn't read
        // stdin, so pipe EOF never reached it and it outlived
        // SOLARO, keeping its metrics socket and any bound ports.
        // This also flushes each notebook's debounced 800ms
        // autosave, which `onDisappear` doesn't reliably do during
        // app termination.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.teardown()
            }
        }
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
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }

    /// Stop everything that owns a subprocess and flush unsaved
    /// notebook state: the `aro lsp` server, and every open
    /// notebook (autosave flush + kernel shutdown with SIGKILL
    /// escalation). Idempotent. Called when the workspace unmounts
    /// (Close Project / window close) and on app termination
    /// (GitLab #529).
    func teardown() {
        lsp.stop()
        fileWatcher.stop()
        for notebook in replNotebooks.values {
            notebook.teardown()
        }
        replNotebooks.removeAll()
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
        snippets.reload(projectRoot: project.rootPath)
        gitMonitor.refresh(for: project)
        for url in loaded.sourceFiles {
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                lsp.didOpen(url: url, text: text)
                // Baseline for external-change detection: what the
                // file held when we read it (GitLab #536).
                lastSavedText[url.standardizedFileURL] = text
            }
        }
        refreshWatchedFiles()
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

    /// Bumped when a markdown file's rendered/raw mode is toggled
    /// (#488). The flag itself lives in the file's `LayoutSidecar`
    /// on disk — this makes the center pane re-read it.
    var markdownModeTick: Int = 0

    /// Flip the current markdown file between the rendered inline
    /// editor and raw source in the code editor. The choice is
    /// remembered per file.
    func toggleMarkdownRawSource() {
        guard let url = currentFile, MarkdownFile.isMarkdown(url) else { return }
        var sidecar = LayoutSidecar.load(for: url)
        sidecar.markdownRawSource.toggle()
        try? sidecar.save(for: url)
        markdownModeTick &+= 1
    }

    /// Whether the current file is markdown currently showing raw
    /// source. Drives the toolbar / menu item's label.
    var currentMarkdownShowsRawSource: Bool {
        guard let url = currentFile, MarkdownFile.isMarkdown(url) else { return false }
        _ = markdownModeTick
        return LayoutSidecar.load(for: url).markdownRawSource
    }

    /// Whether a "Toggle rendered markdown" affordance applies right
    /// now — i.e. the open file is a `.md` / `.markdown`.
    var currentFileIsMarkdown: Bool {
        guard let url = currentFile else { return false }
        return MarkdownFile.isMarkdown(url)
    }

    // MARK: - Live buffer editing (#…, GitLab #535)

    /// A single edit to apply into the OPEN editor's STTextView,
    /// undoably and on the fly — instead of the destructive
    /// write-disk-and-reload path, which trips `updateNSView`'s
    /// external-swap branch and calls `undoManager.removeAllActions()`.
    ///
    /// Built for the AI co-pilot first; completion acceptance uses the
    /// same pipeline now (GitLab #535), which is why the edit can be
    /// located either by matching `oldString` (empty ⇒ whole file) or
    /// by an explicit UTF-16 `range`.
    struct BufferEditCommand: Equatable {
        let id: UInt64
        let url: URL
        /// Explicit UTF-16 range to replace. When nil, the editor
        /// locates the edit by searching for `oldString`.
        var range: NSRange? = nil
        var oldString: String = ""
        let newString: String
        /// Label for the Edit menu's Undo item.
        var actionName: String = "Edit"
        /// UTF-16 offset to park the caret at once the edit lands.
        /// Nil leaves the caret wherever the replacement put it.
        var caretOffset: Int? = nil
    }

    /// The pending live edit for the active editor. `AROCodeEditor` observes
    /// it (keyed on `id`) and applies it via `STTextView.replaceCharacters`.
    var pendingBufferEdit: BufferEditCommand?
    private var bufferEditSeq: UInt64 = 0

    /// Live editor text per open file, mirrored from the editor's binding so
    /// the co-pilot's context sees the user's current (even mid-edit) buffer
    /// rather than depending on the keystroke-autosave side effect. Seeded on
    /// file load, updated on every keystroke.
    var liveEditorText: [URL: String] = [:]

    /// One live notebook per open `.repl` file, created on first
    /// open and kept while the tab stays open — the kernel session
    /// (variables, feature sets) must survive the user switching to
    /// another file and back. `closeTab` tears the entry down.
    var replNotebooks: [URL: ReplNotebookController] = [:]

    /// Resolve (or create) the notebook controller for `url`.
    func replNotebook(for url: URL) -> ReplNotebookController {
        let std = url.standardizedFileURL
        if let existing = replNotebooks[std] { return existing }
        let notebook = ReplNotebookController(url: std, project: project)
        replNotebooks[std] = notebook
        return notebook
    }

    /// Current live text for `url`: the editor buffer when known, else disk.
    func liveText(for url: URL) -> String? {
        let std = url.standardizedFileURL
        return liveEditorText[std] ?? (try? String(contentsOf: std, encoding: .utf8))
    }

    // MARK: - Editor writes (GitLab #532)

    /// Disk-write health of the open buffers. Non-empty while some
    /// file's last save failed; the center pane renders a banner off
    /// it and the state clears itself on the next successful write.
    var saveState = EditorSaveState()

    /// THE editor write path. Every keystroke-autosave, node edit,
    /// snippet splice, ghost accept and completion insert goes
    /// through here.
    ///
    /// Returns whether the bytes reached disk. Callers keep updating
    /// their in-memory caches either way — dropping the user's
    /// keystrokes on a failed write would be a second bug — but a
    /// failure is now recorded, logged once, and shown, instead of
    /// swallowed by a `try?` (GitLab #532). The next change retries
    /// automatically, which is the whole retry story: autosave fires
    /// again, and a write that lands clears the banner.
    @discardableResult
    func writeToDisk(_ text: String, to url: URL) -> Bool {
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            // Baseline for external-change detection (GitLab #536):
            // this is now what SOLARO believes is on disk, so a later
            // difference is somebody else's write.
            lastSavedText[url.standardizedFileURL] = text
            if saveState.recordSuccess(for: url) {
                // Only log the recovery when there was something to
                // recover from.
                FileHandle.standardError.write(Data(
                    "[SOLARO] Save recovered: \(url.path)\n".utf8))
            }
            return true
        } catch {
            let message = (error as NSError).localizedDescription
            if saveState.recordFailure(for: url, message: message) {
                FileHandle.standardError.write(Data(
                    "[SOLARO] Warning: could not save \(url.path): \(message)\n".utf8))
            }
            return false
        }
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
        bufferEditSeq &+= 1
        pendingBufferEdit = BufferEditCommand(
            id: bufferEditSeq, url: std,
            oldString: oldString, newString: newString,
            actionName: "AI Edit")
        return true
    }

    /// Replace an explicit UTF-16 range of the OPEN editor buffer,
    /// undoably. Returns false when `url` isn't the active editor, so
    /// the caller can fall back to a disk write.
    ///
    /// This is what accepting a completion uses (GitLab #535). It used
    /// to splice the text into a disk snapshot, write the file, and
    /// call `openFile` — which pushed the whole document back through
    /// the editor's external-swap branch and wiped the file's entire
    /// undo history for one accepted suggestion.
    @discardableResult
    func replaceInOpenBuffer(url: URL,
                             range: NSRange,
                             with text: String,
                             actionName: String,
                             caretOffset: Int? = nil) -> Bool {
        let std = url.standardizedFileURL
        guard currentFile?.standardizedFileURL == std else { return false }
        bufferEditSeq &+= 1
        pendingBufferEdit = BufferEditCommand(
            id: bufferEditSeq, url: std, range: range,
            newString: text, actionName: actionName,
            caretOffset: caretOffset)
        return true
    }

    /// Make sure the language server's view of `url` matches the live
    /// editor buffer before a position-sensitive request. Every
    /// keystroke already sends `didChange`, but a write that failed
    /// (GitLab #532), a YAML file (whose binding skips the LSP), or a
    /// document the server only saw at load time can leave the mirror
    /// behind — and a definition/hover/rename resolved against a stale
    /// document lands on the wrong column.
    func syncLSPWithLiveText(_ url: URL) {
        guard !ReplFile.isNotebook(url) else { return }
        guard let text = liveText(for: url) else { return }
        guard lsp.openDocuments[url] != text else { return }
        lsp.didChange(url: url, text: text)
    }

    // MARK: - External changes (GitLab #536)

    /// What SOLARO last wrote to (or read from) each file. The
    /// baseline that makes "does this buffer hold unsaved work?"
    /// answerable under per-keystroke autosave, where the buffer
    /// otherwise always equals disk.
    var lastSavedText: [URL: String] = [:]

    /// Files whose buffer AND disk contents have both moved on. While
    /// a file is in here the editor must NOT autosave over it — the
    /// user picks Reload or Keep mine first. Value is the disk text
    /// at the moment the conflict was detected.
    var conflictedFiles: [URL: String] = [:]

    /// Watches the open tabs plus the project root so a `git
    /// checkout`, a pull, or an edit in another editor doesn't leave
    /// the IDE showing — and then re-saving — stale content.
    @ObservationIgnored
    private lazy var fileWatcher: ExternalFileWatcher = {
        let watcher = ExternalFileWatcher()
        watcher.onChange = { [weak self] url in
            self?.handleExternalChange(at: url)
        }
        return watcher
    }()

    /// True when this file must not be autosaved over.
    func isConflicted(_ url: URL) -> Bool {
        conflictedFiles[url.standardizedFileURL] != nil
    }

    /// Point the watcher at the current open tabs + the project root.
    /// Called whenever the tab set changes.
    func refreshWatchedFiles() {
        var targets = openTabs.map(\.standardizedFileURL)
        // The root directory catches files created / deleted outside
        // SOLARO, which is what leaves the sidebar tree stale.
        targets.append(project.rootPath.standardizedFileURL)
        let sources = project.rootPath.appendingPathComponent("sources")
        if FileManager.default.fileExists(atPath: sources.path) {
            targets.append(sources.standardizedFileURL)
        }
        fileWatcher.watch(targets)
    }

    /// One file (or the project root) changed on disk.
    private func handleExternalChange(at url: URL) {
        let std = url.standardizedFileURL
        // A notebook is not a text document. It owns its own model and
        // its own debounced write-back, so every autosave it makes
        // trips this watcher — and the old path then parsed the
        // notebook's JSON as ARO source, filed the parse failure under
        // `parseErrors`, and pushed the JSON to the language server as
        // if it were code. Editing a notebook therefore produced
        // diagnostics about its own file format, and left the text
        // buffer mirror holding JSON that a text-editor write path
        // could later put back on disk.
        if ReplFile.isNotebook(std) {
            gitMonitor.refresh(for: project)
            return
        }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: std.path, isDirectory: &isDirectory)
        if isDirectory.boolValue {
            // A directory changed: files appeared or vanished. Rebuild
            // the model so the tree and the program cache catch up.
            load()
            return
        }
        guard exists else {
            // The file went away (deleted, or renamed by a checkout
            // that hasn't put it back yet). Leave the buffer alone —
            // the user still has their text — but say so.
            conflictedFiles[std] = ""
            return
        }
        guard let disk = try? String(contentsOf: std, encoding: .utf8) else { return }
        switch ExternalChangePolicy.outcome(
            buffer: liveEditorText[std],
            lastSaved: lastSavedText[std],
            disk: disk
        ) {
        case .inSync:
            conflictedFiles.removeValue(forKey: std)
        case .reload:
            conflictedFiles.removeValue(forKey: std)
            adoptDiskContents(disk, for: std)
        case .conflict:
            conflictedFiles[std] = disk
        }
        gitMonitor.refresh(for: project)
    }

    /// Take the file's on-disk contents as the truth: refresh the
    /// buffer mirror, the parse cache, the LSP, and force the center
    /// pane to re-read.
    private func adoptDiskContents(_ disk: String, for url: URL) {
        let std = url.standardizedFileURL
        // Notebooks never travel this path (see handleExternalChange);
        // guarding here too keeps a future caller from parsing JSON as
        // ARO and teaching the LSP about a file it cannot read.
        guard !ReplFile.isNotebook(std) else { return }
        liveEditorText[std] = disk
        lastSavedText[std] = disk
        do {
            programs[std] = try Parser.parse(disk)
            parseErrors.removeValue(forKey: std)
        } catch {
            parseErrors[std] = "\(error)"
        }
        lsp.didChange(url: std, text: disk)
        if currentFile?.standardizedFileURL == std {
            fileReloadTick &+= 1
        }
    }

    /// "Reload" on the conflict bar: discard the buffer and take what
    /// is on disk.
    func resolveConflictByReloading(_ url: URL) {
        let std = url.standardizedFileURL
        guard let disk = conflictedFiles.removeValue(forKey: std) else { return }
        // Re-read rather than trusting the snapshot — the file may
        // have changed again while the bar was up.
        let current = (try? String(contentsOf: std, encoding: .utf8)) ?? disk
        adoptDiskContents(current, for: std)
    }

    /// "Keep mine" on the conflict bar: the buffer wins. Writing it
    /// out re-establishes the baseline, so the file stops being
    /// conflicted and autosave resumes.
    func resolveConflictByKeepingBuffer(_ url: URL) {
        let std = url.standardizedFileURL
        conflictedFiles.removeValue(forKey: std)
        guard let buffer = liveEditorText[std] else { return }
        if writeToDisk(buffer, to: std) {
            lsp.didChange(url: std, text: buffer)
            do {
                programs[std] = try Parser.parse(buffer)
                parseErrors.removeValue(forKey: std)
            } catch {
                parseErrors[std] = "\(error)"
            }
        }
    }

    /// File → Reload (⌥⌘R). Re-reads the project from disk: model,
    /// programs, tree, and every open buffer that has no unsaved
    /// work. The comment in `load()` used to promise this menu item
    /// existed; it never did (GitLab #536).
    func reloadFromDisk() {
        for url in openTabs {
            let std = url.standardizedFileURL
            guard let disk = try? String(contentsOf: std, encoding: .utf8)
            else { continue }
            switch ExternalChangePolicy.outcome(
                buffer: liveEditorText[std],
                lastSaved: lastSavedText[std],
                disk: disk
            ) {
            case .inSync:
                conflictedFiles.removeValue(forKey: std)
            case .reload:
                conflictedFiles.removeValue(forKey: std)
                adoptDiskContents(disk, for: std)
            case .conflict:
                // An explicit Reload still doesn't get to throw away
                // unsaved work without asking — surface the bar.
                conflictedFiles[std] = disk
            }
        }
        load()
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
            // Watch what the user has open (GitLab #536).
            refreshWatchedFiles()
        }
        // Text documents get an external-change baseline; a notebook
        // does not, because it is not edited as text and its own
        // autosave would look like an external write.
        if !ReplFile.isNotebook(url),
           lastSavedText[url.standardizedFileURL] == nil,
           let text = try? String(contentsOf: url, encoding: .utf8) {
            lastSavedText[url.standardizedFileURL] = text
        }
        // Materialize a notebook controller here, in event context —
        // CenterPane's body only *reads* the cache, so opening a
        // `.repl` file never mutates observable state mid-render.
        if ReplFile.isNotebook(url) {
            _ = replNotebook(for: url)
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
        // Closing a notebook tab ends its kernel session — the
        // subprocess would otherwise outlive any way to reach it.
        if let notebook = replNotebooks.removeValue(
            forKey: url.standardizedFileURL) {
            notebook.teardown()
        }
        // Tell the LSP the document is gone (GitLab #530) — the
        // server otherwise accumulates every document ever opened.
        // Project source files are deliberately exempt: `applyParse`
        // opens ALL of them at load time (independent of tabs) so
        // the server has whole-project visibility for cross-file
        // definition/rename/workspace-symbols, and the server drops
        // a closed document from exactly those features. Only
        // documents that entered the server through editing outside
        // the project set are closed with their tab.
        if model?.sourceFiles.contains(url) != true {
            lsp.didClose(url: url)
        }
        // A closed tab shouldn't leave its save-failure banner
        // hanging over the next file (GitLab #532).
        saveState.forget(url)
        conflictedFiles.removeValue(forKey: url.standardizedFileURL)
        refreshWatchedFiles()
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

