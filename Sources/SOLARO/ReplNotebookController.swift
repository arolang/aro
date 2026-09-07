// ============================================================
// ReplNotebookController.swift
// SOLARO — live state for one open .repl notebook
// ============================================================
//
// Owns the cell list, the selection, the kernel client, and the
// serial run queue for one `.repl` file. The document on disk is
// the source of truth for content; this controller is the source
// of truth for everything transient (what's selected, what's
// running, what's queued).
//
// The run queue is serial by design: the JSON REPL protocol is
// request/response and `REPLSession` is not internally
// synchronised (ARO-0091 §Limits), so "Run All" enqueues cells in
// order and the loop feeds them to the kernel one at a time.
// Within a cell, ARO's own concurrency still applies — statements
// defer and overlap per ARO-0088.

import Foundation
import Observation

@MainActor
@Observable
final class ReplNotebookController {

    let url: URL
    let project: Project

    private(set) var cells: [ReplNotebookCell] = []
    /// Load failure, shown instead of the notebook.
    private(set) var loadError: String?

    /// The focused cell — target of toolbar actions and keyboard
    /// cell operations.
    ///
    /// Moving the selection renders any markdown cell left behind:
    /// clicking into a markdown cell opens its source, and clicking
    /// away is how a notebook user says "done" — Jupyter renders on
    /// blur too. Without this, a cell only rendered on ⇧⏎ or Esc, so
    /// a notebook read as raw markdown wherever someone had looked.
    var selectedCellID: String? {
        didSet {
            guard oldValue != selectedCellID else { return }
            commitMarkdownEditing(except: selectedCellID)
        }
    }

    /// Render every markdown cell whose source is open, except the
    /// one named — the cell being moved to, which the caller may
    /// have deliberately opened for editing (a new cell, or M).
    func commitMarkdownEditing(except keep: String? = nil) {
        let leaving = editingMarkdownIDs.filter { $0 != keep }
        guard !leaving.isEmpty else { return }
        editingMarkdownIDs.subtract(leaving)
    }
    /// Markdown cells currently showing raw source. Everything
    /// else renders. A brand-new markdown cell starts here so the
    /// user can type immediately.
    var editingMarkdownIDs: Set<String> = []

    /// Jupyter's command mode: a cell is selected but no editor has
    /// the keyboard, so single keys act on the cell (A / B / DD /
    /// M / Y / arrows) instead of typing into it. Esc enters,
    /// ⏎ or a click in an editor leaves (GitLab #538).
    var commandMode = false

    /// The kernel session. Injected through `ReplKernelDriving` so
    /// the run queue can be tested against a scripted fake instead
    /// of a live `aro repl --json` subprocess (GitLab #542).
    let kernel: any ReplKernelDriving

    /// Cell currently executing on the kernel.
    private(set) var runningCellID: String?
    /// Cells waiting behind it, in run order.
    private(set) var queuedCellIDs: [String] = []

    /// Kernel-info popover payload; refreshed after each run.
    private(set) var kernelInfo: ReplKernelClient.KernelInfo?

    private var saveTask: Task<Void, Never>?
    private var queueTask: Task<Void, Never>?

    /// How long a mutation waits before it hits disk. Injectable so
    /// tests can assert the debounce without sleeping most of a
    /// second per case.
    private let saveDebounce: Duration

    init(url: URL,
         project: Project,
         kernel: (any ReplKernelDriving)? = nil,
         saveDebounce: Duration = .milliseconds(800)) {
        self.url = url
        self.project = project
        self.kernel = kernel ?? ReplKernelClient()
        self.saveDebounce = saveDebounce
        load()
    }

    // MARK: - Document

    private func load() {
        do {
            var doc = try ReplNotebookDocument.load(from: url)
            if doc.cells.isEmpty {
                // Never show a zero-cell notebook — there'd be
                // nothing to click on.
                doc.cells = [ReplNotebookCell(kind: .code)]
            }
            cells = doc.cells
            loadError = nil
            selectedCellID = cells.first?.id
        } catch {
            loadError = "\(error.localizedDescription)"
        }
    }

    /// Debounced write-back. Every mutation funnels through here so
    /// the file follows the buffer the same way the code editor's
    /// keystroke autosave does.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self, saveDebounce] in
            try? await Task.sleep(for: saveDebounce)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        guard loadError == nil else { return }
        do {
            // Trailing newlines are trimmed on the way to disk. The
            // text view normalises a cell it displays by appending
            // one, which came back as an edit and autosaved — so
            // merely OPENING a notebook dirtied the file, and
            // browsing the course turned every notebook looked at
            // into a modified file in git. Trimming here rather
            // than in the buffer keeps
            // typing untouched: pressing Return still puts a newline
            // in the editor, it just does not end up in the file.
            let normalized = cells.map { cell -> ReplNotebookCell in
                var copy = cell
                while copy.source.hasSuffix("\n") { copy.source.removeLast() }
                return copy
            }
            try ReplNotebookDocument(cells: normalized).save(to: url)
        } catch {
            FileHandle.standardError.write(
                Data("[ReplNotebook] Warning: couldn't save \(url.lastPathComponent): \(error)\n".utf8))
        }
    }

    // MARK: - Cell content

    func cellIndex(of id: String) -> Int? {
        cells.firstIndex { $0.id == id }
    }

    func updateSource(_ source: String, for id: String) {
        guard let idx = cellIndex(of: id), cells[idx].source != source else { return }
        cells[idx].source = source
        scheduleSave()
    }

    // MARK: - Undo

    /// The workspace's UndoManager, handed over by the view.
    ///
    /// Structural cell operations register here so ⌘Z brings a cell
    /// back — with its outputs, its kind and its position (GitLab
    /// #537). Before this, delete / convert / clear-outputs were
    /// one-click irreversible and the 800 ms autosave made the loss
    /// permanent within the second; the per-cell text view's own
    /// UndoManager only ever knew about characters.
    ///
    /// Weak: the manager belongs to the window, and the blocks it
    /// stores already reference this controller.
    weak var undoManager: UndoManager?

    /// Everything a structural operation can disturb. Cells are
    /// values, so a snapshot is a cheap copy that keeps outputs and
    /// execution counts intact.
    private struct Snapshot {
        var cells: [ReplNotebookCell]
        var selection: String?
        var editing: Set<String>
    }

    private var snapshot: Snapshot {
        Snapshot(cells: cells, selection: selectedCellID,
                 editing: editingMarkdownIDs)
    }

    /// Wrap a structural mutation in an undo registration. A body
    /// that changes nothing registers nothing, so ⌘Z never spends a
    /// step on a no-op.
    private func structural(_ actionName: String, _ body: () -> Void) {
        let before = snapshot
        body()
        guard cells != before.cells || editingMarkdownIDs != before.editing else {
            return
        }
        registerUndo(restoring: before, actionName: actionName)
        scheduleSave()
    }

    private func registerUndo(restoring snap: Snapshot, actionName: String) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { controller in
            controller.restore(snap, actionName: actionName)
        }
        undoManager.setActionName(actionName)
        WorkspaceUndoRegistry.shared.noteUndoChange()
    }

    private func restore(_ snap: Snapshot, actionName: String) {
        // Register the inverse first: while an undo is running the
        // manager files new registrations as redo.
        registerUndo(restoring: snapshot, actionName: actionName)
        cells = snap.cells
        selectedCellID = snap.selection
        editingMarkdownIDs = snap.editing
        // A cell that no longer exists can't stay queued — and one
        // that came back does not silently re-enter the queue.
        let live = Set(cells.map(\.id))
        queuedCellIDs.removeAll { !live.contains($0) }
        scheduleSave()
    }

    // MARK: - Cell structure

    @discardableResult
    func addCell(kind: ReplNotebookCell.Kind, after id: String?) -> String {
        let cell = ReplNotebookCell(kind: kind)
        structural("Insert Cell") {
            if let id, let idx = cellIndex(of: id) {
                cells.insert(cell, at: idx + 1)
            } else {
                cells.append(cell)
            }
            selectedCellID = cell.id
            if kind == .markdown { editingMarkdownIDs.insert(cell.id) }
        }
        return cell.id
    }

    @discardableResult
    func addCell(kind: ReplNotebookCell.Kind, before id: String) -> String {
        let cell = ReplNotebookCell(kind: kind)
        structural("Insert Cell") {
            if let idx = cellIndex(of: id) {
                cells.insert(cell, at: idx)
            } else {
                cells.append(cell)
            }
            selectedCellID = cell.id
            if kind == .markdown { editingMarkdownIDs.insert(cell.id) }
        }
        return cell.id
    }

    func deleteCell(_ id: String) {
        guard let idx = cellIndex(of: id) else { return }
        structural("Delete Cell") {
            queuedCellIDs.removeAll { $0 == id }
            cells.remove(at: idx)
            editingMarkdownIDs.remove(id)
            if cells.isEmpty {
                // Same rule as load(): a notebook always has a cell.
                cells = [ReplNotebookCell(kind: .code)]
            }
            if selectedCellID == id {
                selectedCellID = cells[min(idx, cells.count - 1)].id
            }
        }
    }

    func moveCell(_ id: String, by delta: Int) {
        guard let idx = cellIndex(of: id) else { return }
        let target = idx + delta
        guard target >= 0, target < cells.count else { return }
        structural("Move Cell") {
            cells.swapAt(idx, target)
        }
    }

    func convertCell(_ id: String, to kind: ReplNotebookCell.Kind) {
        guard let idx = cellIndex(of: id), cells[idx].kind != kind else { return }
        structural(kind == .markdown ? "Convert to Markdown" : "Convert to Code") {
            cells[idx].kind = kind
            cells[idx].outputs = []
            cells[idx].executionCount = nil
            cells[idx].durationMs = nil
            if kind == .markdown {
                editingMarkdownIDs.insert(id)
            } else {
                editingMarkdownIDs.remove(id)
            }
        }
    }

    /// Insert cells after `id` (at the end when `id` is nil or
    /// unknown), each with a fresh identity so the same clipboard
    /// contents can be pasted repeatedly. Outputs come along —
    /// pasting a cell you copied brings what it printed, the way
    /// Jupyter's clipboard behaves.
    @discardableResult
    func insertCells(_ newCells: [ReplNotebookCell],
                     after id: String?,
                     actionName: String = "Paste Cells") -> [String] {
        guard !newCells.isEmpty else { return [] }
        var copies = newCells
        for idx in copies.indices { copies[idx].id = UUID().uuidString }
        structural(actionName) {
            let at = id.flatMap { cellIndex(of: $0) }.map { $0 + 1 } ?? cells.count
            cells.insert(contentsOf: copies, at: at)
            selectedCellID = copies.last?.id
            for cell in copies where cell.kind == .markdown && cell.source.isEmpty {
                editingMarkdownIDs.insert(cell.id)
            }
        }
        return copies.map(\.id)
    }

    /// Jupyter's ⌘C+⌘V in one step, right below the original.
    func duplicateCell(_ id: String) {
        guard let idx = cellIndex(of: id) else { return }
        insertCells([cells[idx]], after: id, actionName: "Duplicate Cell")
    }

    /// Jupyter's ⇧M: fold the next cell into this one. The merged
    /// cell keeps the first cell's kind and its captured outputs —
    /// same as Jupyter, and the outputs are one undo away either
    /// way.
    func mergeCellBelow(_ id: String) {
        guard let idx = cellIndex(of: id), idx + 1 < cells.count else { return }
        structural("Merge Cells") {
            let below = cells[idx + 1]
            var joined = cells[idx].source
            if !joined.isEmpty, !joined.hasSuffix("\n") { joined += "\n" }
            joined += below.source
            cells[idx].source = joined
            cells.remove(at: idx + 1)
            queuedCellIDs.removeAll { $0 == below.id }
            editingMarkdownIDs.remove(below.id)
            selectedCellID = cells[idx].id
        }
    }

    /// Move the selection by `offset` cells, clamped to the ends.
    /// Nothing is selected yet → land on the first cell.
    func selectCell(offset: Int) {
        guard !cells.isEmpty else { return }
        guard let current = selectedCellID, let idx = cellIndex(of: current) else {
            selectedCellID = cells.first?.id
            return
        }
        let target = min(max(idx + offset, 0), cells.count - 1)
        selectedCellID = cells[target].id
    }

    func clearAllOutputs() {
        structural("Clear All Outputs") {
            for idx in cells.indices {
                cells[idx].outputs = []
                cells[idx].executionCount = nil
                cells[idx].durationMs = nil
            }
        }
    }

    // MARK: - Running

    var isExecuting: Bool {
        runningCellID != nil || !queuedCellIDs.isEmpty
    }

    func isQueued(_ id: String) -> Bool {
        queuedCellIDs.contains(id) || runningCellID == id
    }

    /// Run one cell. Markdown cells "run" by rendering; code cells
    /// join the serial queue.
    func runCell(_ id: String) {
        guard let idx = cellIndex(of: id) else { return }
        if cells[idx].kind == .markdown {
            editingMarkdownIDs.remove(id)
            return
        }
        enqueue([id])
    }

    /// ⇧⏎ — run, then select (creating if needed) the next cell.
    func runCellAndAdvance(_ id: String) {
        runCell(id)
        guard let idx = cellIndex(of: id) else { return }
        if idx + 1 < cells.count {
            selectedCellID = cells[idx + 1].id
        } else {
            addCell(kind: .code, after: id)
        }
    }

    /// ⌥⏎ — run, then insert a fresh cell right below.
    func runCellAndInsertBelow(_ id: String) {
        runCell(id)
        addCell(kind: .code, after: id)
    }

    func runAll() {
        finishAllMarkdownEditing()
        enqueue(cells.filter { $0.kind == .code }.map(\.id))
    }

    /// Everything strictly above `id`, in order — Jupyter's
    /// "Run All Above".
    func runAllAbove(_ id: String) {
        guard let idx = cellIndex(of: id) else { return }
        enqueue(cells[..<idx].filter { $0.kind == .code }.map(\.id))
    }

    /// `id` and everything below it.
    func runCellAndBelow(_ id: String) {
        guard let idx = cellIndex(of: id) else { return }
        enqueue(cells[idx...].filter { $0.kind == .code }.map(\.id))
    }

    private func finishAllMarkdownEditing() {
        editingMarkdownIDs.removeAll()
    }

    private func enqueue(_ ids: [String]) {
        for id in ids where !queuedCellIDs.contains(id) && runningCellID != id {
            queuedCellIDs.append(id)
        }
        pumpQueue()
    }

    private func pumpQueue() {
        guard queueTask == nil else { return }
        queueTask = Task { [weak self] in
            await self?.drainQueue()
            self?.queueTask = nil
        }
    }

    private func drainQueue() async {
        await kernel.ensureStarted(project: project)
        while !queuedCellIDs.isEmpty {
            let id = queuedCellIDs.removeFirst()
            guard let idx = cellIndex(of: id) else { continue }
            runningCellID = id
            cells[idx].outputs = []
            cells[idx].durationMs = nil

            let source = cells[idx].source
            let outcome = await kernel.execute(code: source) { [weak self] name, text in
                self?.appendStream(name: name, text: text, to: id)
            }
            applyOutcome(outcome, to: id)
            runningCellID = nil

            if outcome.kernelDied {
                // The rest of the queue can't produce anything
                // meaningful against a dead session — drop it.
                queuedCellIDs.removeAll()
                break
            }
        }
        runningCellID = nil
        saveNow()
        kernelInfo = await kernel.info()
        // Cells enqueued while we awaited the session snapshot see
        // `queueTask` still set and skip the pump — drain them here
        // instead of leaving them stranded until the next run.
        if !queuedCellIDs.isEmpty {
            await drainQueue()
        }
    }

    private func appendStream(name: String, text: String, to id: String) {
        guard let idx = cellIndex(of: id) else { return }
        // Coalesce with the previous chunk when it's the same
        // stream — keeps the outputs array from fragmenting into
        // per-write slivers on chatty cells.
        if let last = cells[idx].outputs.indices.last,
           cells[idx].outputs[last].kind == .stream,
           cells[idx].outputs[last].streamName == name {
            cells[idx].outputs[last].text = (cells[idx].outputs[last].text ?? "") + text
        } else {
            cells[idx].outputs.append(.stream(name: name, text: text))
        }
    }

    private func applyOutcome(_ outcome: ReplKernelClient.ExecOutcome, to id: String) {
        guard let idx = cellIndex(of: id) else { return }
        cells[idx].executionCount = outcome.executionCount
        cells[idx].durationMs = outcome.durationMs
        if outcome.status == "ok" {
            if outcome.plainText != nil || outcome.jsonValue != nil {
                cells[idx].outputs.append(.result(plainText: outcome.plainText,
                                                  jsonValue: outcome.jsonValue))
            }
        } else {
            cells[idx].outputs.append(.error(
                name: outcome.errorName ?? "AROError",
                value: outcome.errorValue ?? "Execution failed",
                traceback: outcome.traceback ?? []
            ))
        }
    }

    // MARK: - Kernel controls

    /// Stop the running cell by killing the session — the honest
    /// interrupt (ARO-0091 §Interrupt). Queued cells are dropped.
    func interrupt() {
        queuedCellIDs.removeAll()
        kernel.interrupt(reason: ReplKernelClient.interruptReason)
    }

    func restartKernel() {
        queuedCellIDs.removeAll()
        Task { [weak self] in
            guard let self else { return }
            await self.kernel.restart(project: self.project)
            self.kernelInfo = nil
        }
    }

    func restartAndRunAll() {
        queuedCellIDs.removeAll()
        Task { [weak self] in
            guard let self else { return }
            await self.kernel.restart(project: self.project)
            self.kernelInfo = nil
            self.runAll()
        }
    }

    /// Called when the notebook leaves the screen for good.
    func teardown() {
        saveNow()
        kernel.shutdown()
    }
}
