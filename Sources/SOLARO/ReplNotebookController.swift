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
    var selectedCellID: String?
    /// Markdown cells currently showing raw source. Everything
    /// else renders. A brand-new markdown cell starts here so the
    /// user can type immediately.
    var editingMarkdownIDs: Set<String> = []

    let kernel = ReplKernelClient()

    /// Cell currently executing on the kernel.
    private(set) var runningCellID: String?
    /// Cells waiting behind it, in run order.
    private(set) var queuedCellIDs: [String] = []

    /// Kernel-info popover payload; refreshed after each run.
    private(set) var kernelInfo: ReplKernelClient.KernelInfo?

    private var saveTask: Task<Void, Never>?
    private var queueTask: Task<Void, Never>?

    init(url: URL, project: Project) {
        self.url = url
        self.project = project
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
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        guard loadError == nil else { return }
        do {
            try ReplNotebookDocument(cells: cells).save(to: url)
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

    // MARK: - Cell structure

    @discardableResult
    func addCell(kind: ReplNotebookCell.Kind, after id: String?) -> String {
        let cell = ReplNotebookCell(kind: kind)
        if let id, let idx = cellIndex(of: id) {
            cells.insert(cell, at: idx + 1)
        } else if id == nil {
            cells.append(cell)
        } else {
            cells.append(cell)
        }
        selectedCellID = cell.id
        if kind == .markdown { editingMarkdownIDs.insert(cell.id) }
        scheduleSave()
        return cell.id
    }

    @discardableResult
    func addCell(kind: ReplNotebookCell.Kind, before id: String) -> String {
        let cell = ReplNotebookCell(kind: kind)
        if let idx = cellIndex(of: id) {
            cells.insert(cell, at: idx)
        } else {
            cells.append(cell)
        }
        selectedCellID = cell.id
        if kind == .markdown { editingMarkdownIDs.insert(cell.id) }
        scheduleSave()
        return cell.id
    }

    func deleteCell(_ id: String) {
        guard let idx = cellIndex(of: id) else { return }
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
        scheduleSave()
    }

    func moveCell(_ id: String, by delta: Int) {
        guard let idx = cellIndex(of: id) else { return }
        let target = idx + delta
        guard target >= 0, target < cells.count else { return }
        cells.swapAt(idx, target)
        scheduleSave()
    }

    func convertCell(_ id: String, to kind: ReplNotebookCell.Kind) {
        guard let idx = cellIndex(of: id), cells[idx].kind != kind else { return }
        cells[idx].kind = kind
        cells[idx].outputs = []
        cells[idx].executionCount = nil
        cells[idx].durationMs = nil
        if kind == .markdown {
            editingMarkdownIDs.insert(id)
        } else {
            editingMarkdownIDs.remove(id)
        }
        scheduleSave()
    }

    func clearAllOutputs() {
        for idx in cells.indices {
            cells[idx].outputs = []
            cells[idx].executionCount = nil
            cells[idx].durationMs = nil
        }
        scheduleSave()
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
        kernel.interrupt()
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
