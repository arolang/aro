// ============================================================
// ReplNotebookControllerTests.swift
// SOLARO — notebook run queue + structural ops (GitLab #542)
// ============================================================
//
// The controller owns the trickiest async logic in the notebook
// stack — a serial run queue with a dedupe, a single-task pump, a
// re-drain tail call for cells enqueued during the `info()` await,
// and queue abandonment when the kernel dies — and until now only
// clicking exercised any of it. `ReplKernelDriving` is the seam:
// these tests drive the controller against `FakeKernel`, which
// answers instantly, can hold an execution open, and can mutate the
// notebook from inside an await.

import Testing
import Foundation
import SwiftUI
import AppKit
@testable import SOLARO

// MARK: - Fake kernel

@MainActor
final class FakeKernel: ReplKernelDriving {

    var state: ReplKernelClient.State = .ready
    var serverVersion: String? = "0.0.0-test"

    /// Cell sources handed to `execute`, in order.
    private(set) var executed: [String] = []
    private(set) var ensureStartedCount = 0
    private(set) var infoCount = 0
    private(set) var interruptCount = 0
    private(set) var restartCount = 0
    private(set) var shutdownCount = 0

    /// Stream messages emitted before each outcome.
    var streams: [(name: String, text: String)] = []
    /// Outcome for a given source. Default: a bare `ok`.
    var outcomeFor: (String) -> ReplKernelClient.ExecOutcome = { _ in
        ReplKernelClient.ExecOutcome(status: "ok", executionCount: 1)
    }
    /// Runs inside `info()` — the exact window the re-drain race
    /// lives in.
    var duringInfo: (() -> Void)?
    /// The first `execute` blocks until `release()` is called.
    var holdFirstExecution = false

    private var gate: CheckedContinuation<Void, Never>?

    func release() {
        gate?.resume()
        gate = nil
    }

    func ensureStarted(project: Project) async {
        ensureStartedCount += 1
        state = .ready
    }

    func execute(code: String,
                 onStream: @escaping @MainActor (String, String) -> Void)
        async -> ReplKernelClient.ExecOutcome {
        executed.append(code)
        if holdFirstExecution {
            holdFirstExecution = false
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                gate = c
            }
        }
        for chunk in streams { onStream(chunk.name, chunk.text) }
        return outcomeFor(code)
    }

    func info() async -> ReplKernelClient.KernelInfo? {
        infoCount += 1
        duringInfo?()
        duringInfo = nil
        return ReplKernelClient.KernelInfo(
            version: "0.0.0-test", featureSets: [], variables: [])
    }

    func interrupt(reason: String) { interruptCount += 1 }
    func restart(project: Project) async { restartCount += 1 }
    func shutdown() { shutdownCount += 1 }
}

// MARK: - Suite

@Suite("ReplNotebookController")
@MainActor
struct ReplNotebookControllerTests {

    // MARK: Fixtures

    private func tmpDir() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("solaro-nb-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A notebook file with `sources` as code cells, plus the
    /// controller wired to `kernel`.
    private func makeNotebook(
        _ sources: [String],
        kernel: FakeKernel = FakeKernel(),
        markdownAt: Set<Int> = [],
        saveDebounce: Duration = .milliseconds(20)
    ) throws -> (ReplNotebookController, FakeKernel, URL) {
        let dir = tmpDir()
        let url = dir.appendingPathComponent("nb.repl")
        var doc = ReplNotebookDocument()
        doc.cells = sources.enumerated().map { idx, src in
            ReplNotebookCell(kind: markdownAt.contains(idx) ? .markdown : .code,
                             source: src)
        }
        try doc.save(to: url)
        let controller = ReplNotebookController(
            url: url,
            project: Project(rootPath: dir),
            kernel: kernel,
            saveDebounce: saveDebounce)
        return (controller, kernel, url)
    }

    /// Spin until the run queue is empty. Fails the caller by
    /// timing out rather than hanging the suite — a stranded cell
    /// (the re-drain bug) shows up exactly here.
    private func drain(_ nb: ReplNotebookController,
                       timeout: Duration = .seconds(3)) async {
        let deadline = ContinuousClock.now + timeout
        while nb.isExecuting, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    private func spin(_ times: Int = 40) async {
        for _ in 0..<times {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    // MARK: - Run queue

    @Test("Run All executes every code cell in order, skipping markdown")
    func runAllOrder() async throws {
        let (nb, kernel, _) = try makeNotebook(
            ["one", "prose", "two", "three"], markdownAt: [1])
        nb.runAll()
        await drain(nb)
        #expect(kernel.executed == ["one", "two", "three"])
        #expect(kernel.ensureStartedCount >= 1)
        #expect(nb.runningCellID == nil)
        #expect(nb.queuedCellIDs.isEmpty)
    }

    @Test("Enqueuing the same cell twice runs it once")
    func enqueueDedupe() async throws {
        let (nb, kernel, _) = try makeNotebook(["one", "two"])
        kernel.holdFirstExecution = true
        nb.runAll()
        await spin()
        // While cell one is held, ask for the whole notebook again.
        nb.runAll()
        #expect(nb.queuedCellIDs.count == 1)   // "two", still once
        kernel.release()
        await drain(nb)
        #expect(kernel.executed == ["one", "two"])
    }

    @Test("A cell already running is not queued behind itself")
    func runningCellIsNotRequeued() async throws {
        let (nb, kernel, _) = try makeNotebook(["one"])
        kernel.holdFirstExecution = true
        nb.runAll()
        await spin()
        let running = try #require(nb.runningCellID)
        nb.runCell(running)
        #expect(nb.queuedCellIDs.isEmpty)
        kernel.release()
        await drain(nb)
        #expect(kernel.executed == ["one"])
    }

    /// The race the re-drain tail call exists for: a cell enqueued
    /// while `drainQueue` awaits the kernel-info snapshot sees
    /// `queueTask` still set, so its own pump is a no-op. Without
    /// the tail call it waits forever.
    @Test("A cell enqueued during the kernel-info await still runs")
    func reDrainsCellsEnqueuedDuringInfo() async throws {
        let (nb, kernel, _) = try makeNotebook(["one", "two"])
        let second = nb.cells[1].id
        kernel.duringInfo = { [weak nb] in nb?.runCell(second) }
        nb.runCell(nb.cells[0].id)
        await drain(nb)
        #expect(kernel.executed == ["one", "two"])
        #expect(nb.queuedCellIDs.isEmpty)
    }

    @Test("A cell enqueued while another runs joins the same drain")
    func enqueueDuringRun() async throws {
        let (nb, kernel, _) = try makeNotebook(["one", "two"])
        kernel.holdFirstExecution = true
        nb.runCell(nb.cells[0].id)
        await spin()
        nb.runCell(nb.cells[1].id)
        #expect(nb.queuedCellIDs.count == 1)
        kernel.release()
        await drain(nb)
        #expect(kernel.executed == ["one", "two"])
    }

    @Test("A dead kernel drops the rest of the queue instead of failing every cell")
    func kernelDeathDrainsQueue() async throws {
        let (nb, kernel, _) = try makeNotebook(["one", "two", "three"])
        kernel.outcomeFor = { code in
            ReplKernelClient.ExecOutcome(
                status: "error",
                errorName: "KernelDied", errorValue: "Kernel died.",
                traceback: ["Kernel died."],
                executionCount: 1,
                kernelDied: code == "one")
        }
        nb.runAll()
        await drain(nb)
        #expect(kernel.executed == ["one"])
        #expect(nb.queuedCellIDs.isEmpty)
        #expect(nb.runningCellID == nil)
        #expect(nb.cells[0].outputs.first?.errorName == "KernelDied")
        #expect(nb.cells[1].outputs.isEmpty)
    }

    @Test("Deleting a queued cell takes it out of the queue")
    func deleteWhileQueued() async throws {
        let (nb, kernel, _) = try makeNotebook(["one", "two", "three"])
        kernel.holdFirstExecution = true
        nb.runAll()
        await spin()
        #expect(nb.queuedCellIDs.count == 2)
        nb.deleteCell(nb.cells[1].id)
        #expect(nb.queuedCellIDs.count == 1)
        kernel.release()
        await drain(nb)
        #expect(kernel.executed == ["one", "three"])
    }

    @Test("Interrupt clears the queue and tells the kernel")
    func interruptClearsQueue() async throws {
        let (nb, kernel, _) = try makeNotebook(["one", "two", "three"])
        kernel.holdFirstExecution = true
        nb.runAll()
        await spin()
        nb.interrupt()
        #expect(nb.queuedCellIDs.isEmpty)
        #expect(kernel.interruptCount == 1)
        kernel.release()
        await drain(nb)
        #expect(kernel.executed == ["one"])
    }

    @Test("Run All Above and Run Cell and Below take the right slices")
    func partialRuns() async throws {
        let (nb, kernel, _) = try makeNotebook(["one", "two", "three"])
        nb.runAllAbove(nb.cells[2].id)
        await drain(nb)
        #expect(kernel.executed == ["one", "two"])

        let (nb2, kernel2, _) = try makeNotebook(["one", "two", "three"])
        nb2.runCellAndBelow(nb2.cells[1].id)
        await drain(nb2)
        #expect(kernel2.executed == ["two", "three"])
    }

    @Test("Running a markdown cell renders it instead of reaching the kernel")
    func markdownRunsWithoutKernel() async throws {
        let (nb, kernel, _) = try makeNotebook(["prose"], markdownAt: [0])
        nb.editingMarkdownIDs.insert(nb.cells[0].id)
        nb.runCell(nb.cells[0].id)
        await spin(10)
        #expect(kernel.executed.isEmpty)
        #expect(nb.editingMarkdownIDs.isEmpty)
    }

    // MARK: - Output application

    @Test("Consecutive chunks of one stream coalesce; a switch starts a new output")
    func streamCoalescing() async throws {
        let (nb, kernel, _) = try makeNotebook(["one"])
        kernel.streams = [
            (name: "stdout", text: "hel"),
            (name: "stdout", text: "lo\n"),
            (name: "stderr", text: "warned\n"),
            (name: "stdout", text: "back\n"),
        ]
        nb.runAll()
        await drain(nb)
        let outputs = nb.cells[0].outputs
        #expect(outputs.count == 3)
        #expect(outputs[0].streamName == "stdout")
        #expect(outputs[0].text == "hello\n")
        #expect(outputs[1].streamName == "stderr")
        #expect(outputs[2].text == "back\n")
    }

    @Test("An ok outcome appends the display bundle and the badge")
    func okOutcome() async throws {
        let (nb, kernel, _) = try makeNotebook(["one"])
        kernel.outcomeFor = { _ in
            ReplKernelClient.ExecOutcome(
                status: "ok", plainText: "42", jsonValue: "42",
                durationMs: 7.5, executionCount: 3)
        }
        nb.runAll()
        await drain(nb)
        let cell = nb.cells[0]
        #expect(cell.executionCount == 3)
        #expect(cell.durationMs == 7.5)
        #expect(cell.outputs.count == 1)
        #expect(cell.outputs[0].kind == .result)
        #expect(cell.outputs[0].plainText == "42")
    }

    @Test("An ok outcome with nothing to display appends no output")
    func okWithoutDisplay() async throws {
        let (nb, _, _) = try makeNotebook(["one"])
        nb.runAll()
        await drain(nb)
        #expect(nb.cells[0].outputs.isEmpty)
        #expect(nb.cells[0].executionCount == 1)
    }

    @Test("An error outcome appends a named error with its traceback")
    func errorOutcome() async throws {
        let (nb, kernel, _) = try makeNotebook(["one"])
        kernel.outcomeFor = { _ in
            ReplKernelClient.ExecOutcome(
                status: "error", errorName: "AROError", errorValue: "boom",
                traceback: ["boom", "  at line 1"], executionCount: 2)
        }
        nb.runAll()
        await drain(nb)
        let output = try #require(nb.cells[0].outputs.first)
        #expect(output.kind == .error)
        #expect(output.errorName == "AROError")
        #expect(output.errorValue == "boom")
        #expect(output.traceback?.count == 2)
    }

    @Test("A re-run replaces the previous run's outputs")
    func reRunClearsOutputs() async throws {
        let (nb, kernel, _) = try makeNotebook(["one"])
        kernel.streams = [(name: "stdout", text: "first\n")]
        nb.runAll()
        await drain(nb)
        #expect(nb.cells[0].outputs.count == 1)
        kernel.streams = [(name: "stdout", text: "second\n")]
        nb.runAll()
        await drain(nb)
        #expect(nb.cells[0].outputs.count == 1)
        #expect(nb.cells[0].outputs[0].text == "second\n")
    }

    // MARK: - Structural operations

    @Test("Deleting the last cell leaves an empty one behind")
    func deleteKeepsOneCell() throws {
        let (nb, _, _) = try makeNotebook(["only"])
        nb.deleteCell(nb.cells[0].id)
        #expect(nb.cells.count == 1)
        #expect(nb.cells[0].source.isEmpty)
        #expect(nb.selectedCellID == nb.cells[0].id)
    }

    @Test("Deleting the selected cell selects its neighbour")
    func deleteMovesSelection() throws {
        let (nb, _, _) = try makeNotebook(["one", "two", "three"])
        nb.selectedCellID = nb.cells[1].id
        nb.deleteCell(nb.cells[1].id)
        #expect(nb.cells.map(\.source) == ["one", "three"])
        #expect(nb.selectedCellID == nb.cells[1].id)   // "three"

        nb.selectedCellID = nb.cells[1].id
        nb.deleteCell(nb.cells[1].id)                  // last cell
        #expect(nb.selectedCellID == nb.cells[0].id)
    }

    @Test("Move refuses to walk off either end")
    func moveBounds() throws {
        let (nb, _, _) = try makeNotebook(["one", "two"])
        nb.moveCell(nb.cells[0].id, by: -1)
        #expect(nb.cells.map(\.source) == ["one", "two"])
        nb.moveCell(nb.cells[1].id, by: 1)
        #expect(nb.cells.map(\.source) == ["one", "two"])
        nb.moveCell(nb.cells[0].id, by: 1)
        #expect(nb.cells.map(\.source) == ["two", "one"])
    }

    @Test("Converting a cell wipes outputs that no longer describe it")
    func convertWipesOutputs() async throws {
        let (nb, kernel, _) = try makeNotebook(["one"])
        kernel.streams = [(name: "stdout", text: "hi\n")]
        nb.runAll()
        await drain(nb)
        #expect(!nb.cells[0].outputs.isEmpty)
        nb.convertCell(nb.cells[0].id, to: .markdown)
        #expect(nb.cells[0].kind == .markdown)
        #expect(nb.cells[0].outputs.isEmpty)
        #expect(nb.cells[0].executionCount == nil)
        #expect(nb.editingMarkdownIDs.contains(nb.cells[0].id))
    }

    @Test("Clear All Outputs clears every cell")
    func clearAllOutputs() async throws {
        let (nb, kernel, _) = try makeNotebook(["one", "two"])
        kernel.streams = [(name: "stdout", text: "hi\n")]
        nb.runAll()
        await drain(nb)
        #expect(nb.cells.allSatisfy { !$0.outputs.isEmpty })
        nb.clearAllOutputs()
        #expect(nb.cells.allSatisfy { $0.outputs.isEmpty })
        #expect(nb.cells.allSatisfy { $0.executionCount == nil })
    }

    // MARK: - Saving

    @Test("A mutation reaches disk after the debounce, not before")
    func saveDebounces() async throws {
        let (nb, _, url) = try makeNotebook(["one"], saveDebounce: .milliseconds(80))
        nb.updateSource("edited", for: nb.cells[0].id)
        let immediate = try ReplNotebookDocument.load(from: url)
        #expect(immediate.cells[0].source == "one")
        try? await Task.sleep(for: .milliseconds(250))
        let settled = try ReplNotebookDocument.load(from: url)
        #expect(settled.cells[0].source == "edited")
    }

    @Test("Edits inside the window coalesce into one write")
    func saveCoalesces() async throws {
        let (nb, _, url) = try makeNotebook(["one"], saveDebounce: .milliseconds(80))
        let id = nb.cells[0].id
        for step in 1...5 {
            nb.updateSource("step\(step)", for: id)
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(try ReplNotebookDocument.load(from: url).cells[0].source == "one")
        try? await Task.sleep(for: .milliseconds(250))
        #expect(try ReplNotebookDocument.load(from: url).cells[0].source == "step5")
    }

    @Test("saveNow writes immediately and cancels the pending debounce")
    func saveNowWins() async throws {
        let (nb, _, url) = try makeNotebook(["one"], saveDebounce: .milliseconds(80))
        nb.updateSource("edited", for: nb.cells[0].id)
        nb.saveNow()
        #expect(try ReplNotebookDocument.load(from: url).cells[0].source == "edited")
    }

    /// A notebook that failed to load must never write: the buffer
    /// is empty, and saving it would replace the file we couldn't
    /// read with an empty notebook.
    @Test("A failed load blocks every save")
    func loadErrorBlocksSaves() async throws {
        let dir = tmpDir()
        let url = dir.appendingPathComponent("future.repl")
        let raw = #"{"version":99,"cells":[]}"#
        try Data(raw.utf8).write(to: url)

        let nb = ReplNotebookController(
            url: url, project: Project(rootPath: dir),
            kernel: FakeKernel(), saveDebounce: .milliseconds(20))
        #expect(nb.loadError != nil)
        nb.saveNow()
        nb.addCell(kind: .code, after: nil)
        try? await Task.sleep(for: .milliseconds(120))
        #expect(try String(contentsOf: url, encoding: .utf8) == raw)
    }

    // MARK: - Undo (GitLab #537)

    /// Deterministic grouping: without a run loop to close the
    /// event group, each operation is bracketed by hand so one ⌘Z
    /// undoes one operation.
    private func undoable(_ manager: UndoManager, _ body: () -> Void) {
        manager.beginUndoGrouping()
        body()
        manager.endUndoGrouping()
    }

    private func withUndo(_ sources: [String],
                          markdownAt: Set<Int> = [])
        throws -> (ReplNotebookController, FakeKernel, UndoManager) {
        let (nb, kernel, _) = try makeNotebook(sources, markdownAt: markdownAt)
        let manager = UndoManager()
        manager.groupsByEvent = false
        nb.undoManager = manager
        return (nb, kernel, manager)
    }

    @Test("Undo brings a deleted cell back with its outputs and position")
    func undoDelete() async throws {
        let (nb, kernel, manager) = try withUndo(["one", "two", "three"])
        kernel.streams = [(name: "stdout", text: "middle output\n")]
        nb.runCell(nb.cells[1].id)
        await drain(nb)

        let doomed = nb.cells[1]
        undoable(manager) { nb.deleteCell(doomed.id) }
        #expect(nb.cells.map(\.source) == ["one", "three"])
        #expect(manager.canUndo)

        manager.undo()
        #expect(nb.cells.map(\.source) == ["one", "two", "three"])
        #expect(nb.cells[1] == doomed)                 // outputs and badge too
        #expect(nb.cells[1].outputs.first?.text == "middle output\n")
    }

    @Test("Redo re-applies the delete")
    func redoDelete() throws {
        let (nb, _, manager) = try withUndo(["one", "two"])
        undoable(manager) { nb.deleteCell(nb.cells[0].id) }
        manager.undo()
        #expect(nb.cells.map(\.source) == ["one", "two"])
        #expect(manager.canRedo)
        manager.redo()
        #expect(nb.cells.map(\.source) == ["two"])
    }

    @Test("Undo restores the selection the delete moved")
    func undoRestoresSelection() throws {
        let (nb, _, manager) = try withUndo(["one", "two"])
        nb.selectedCellID = nb.cells[0].id
        undoable(manager) { nb.deleteCell(nb.cells[0].id) }
        #expect(nb.selectedCellID == nb.cells[0].id)   // "two"
        manager.undo()
        #expect(nb.selectedCellID == nb.cells[0].id)   // "one" again
        #expect(nb.cells[0].source == "one")
    }

    @Test("Undo of the last-cell delete removes the replacement cell")
    func undoDeleteOfOnlyCell() throws {
        let (nb, _, manager) = try withUndo(["only"])
        undoable(manager) { nb.deleteCell(nb.cells[0].id) }
        #expect(nb.cells[0].source.isEmpty)
        manager.undo()
        #expect(nb.cells.map(\.source) == ["only"])
    }

    @Test("Undo of a convert restores the kind and the outputs it wiped")
    func undoConvert() async throws {
        let (nb, kernel, manager) = try withUndo(["one"])
        kernel.streams = [(name: "stdout", text: "hi\n")]
        nb.runAll()
        await drain(nb)
        let before = nb.cells[0]

        undoable(manager) { nb.convertCell(before.id, to: .markdown) }
        #expect(nb.cells[0].outputs.isEmpty)
        manager.undo()
        #expect(nb.cells[0] == before)
        #expect(nb.cells[0].kind == .code)
        #expect(nb.cells[0].outputs.count == 1)
        #expect(!nb.editingMarkdownIDs.contains(before.id))
    }

    @Test("Undo of Clear All Outputs brings every cell's outputs back")
    func undoClearAllOutputs() async throws {
        let (nb, kernel, manager) = try withUndo(["one", "two"])
        kernel.streams = [(name: "stdout", text: "out\n")]
        nb.runAll()
        await drain(nb)
        let before = nb.cells

        undoable(manager) { nb.clearAllOutputs() }
        #expect(nb.cells.allSatisfy { $0.outputs.isEmpty })
        manager.undo()
        #expect(nb.cells == before)
    }

    @Test("Undo of a move puts the cell back")
    func undoMove() throws {
        let (nb, _, manager) = try withUndo(["one", "two"])
        undoable(manager) { nb.moveCell(nb.cells[0].id, by: 1) }
        #expect(nb.cells.map(\.source) == ["two", "one"])
        manager.undo()
        #expect(nb.cells.map(\.source) == ["one", "two"])
    }

    @Test("Undo of an insert removes the new cell")
    func undoInsert() throws {
        let (nb, _, manager) = try withUndo(["one"])
        undoable(manager) { nb.addCell(kind: .markdown, after: nb.cells[0].id) }
        #expect(nb.cells.count == 2)
        manager.undo()
        #expect(nb.cells.map(\.source) == ["one"])
        #expect(nb.editingMarkdownIDs.isEmpty)
    }

    @Test("An operation that changes nothing registers no undo step")
    func noOpRegistersNothing() throws {
        let (nb, _, manager) = try withUndo(["one", "two"])
        // No explicit grouping here: an empty group would itself be
        // undoable, and what's under test is that nothing registers.
        nb.moveCell(nb.cells[0].id, by: -1)          // off the top
        nb.convertCell(nb.cells[0].id, to: .code)    // already code
        nb.clearAllOutputs()                         // nothing to clear
        #expect(!manager.canUndo)
    }

    @Test("Structural operations still work with no undo manager attached")
    func worksWithoutUndoManager() throws {
        let (nb, _, _) = try makeNotebook(["one", "two"])
        #expect(nb.undoManager == nil)
        nb.deleteCell(nb.cells[0].id)
        #expect(nb.cells.map(\.source) == ["two"])
    }

    @Test("Undo of a delete does not silently re-queue the cell")
    func undoDoesNotRequeue() async throws {
        let (nb, kernel, manager) = try withUndo(["one", "two", "three"])
        kernel.holdFirstExecution = true
        nb.runAll()
        await spin()
        undoable(manager) { nb.deleteCell(nb.cells[1].id) }
        manager.undo()
        #expect(nb.cells.count == 3)
        #expect(!nb.queuedCellIDs.contains(nb.cells[1].id))
        kernel.release()
        await drain(nb)
        #expect(kernel.executed == ["one", "three"])
    }

    @Test("Teardown saves and shuts the kernel down")
    func teardown() throws {
        let (nb, kernel, url) = try makeNotebook(["one"])
        nb.updateSource("edited", for: nb.cells[0].id)
        nb.teardown()
        #expect(kernel.shutdownCount == 1)
        #expect(try ReplNotebookDocument.load(from: url).cells[0].source == "edited")
    }

    // MARK: - Cell commands (GitLab #538)

    /// A private pasteboard so tests never touch the user's
    /// clipboard. Returns nil when the pasteboard server isn't
    /// reachable (a headless session), which is the one case where
    /// these assertions cannot run at all.
    private func scratchPasteboard() -> NSPasteboard? {
        let pb = NSPasteboard(name: NSPasteboard.Name("solaro.tests.\(UUID().uuidString)"))
        pb.clearContents()
        pb.setString("probe", forType: .string)
        return pb.string(forType: .string) == "probe" ? pb : nil
    }

    @Test("Copy then paste inserts an equal cell with a fresh identity")
    func copyPaste() async throws {
        guard let pb = scratchPasteboard() else { return }
        let (nb, kernel, _) = try makeNotebook(["one", "two"])
        kernel.streams = [(name: "stdout", text: "printed\n")]
        nb.runCell(nb.cells[0].id)
        await drain(nb)

        let source = nb.cells[0]
        nb.copyCell(source.id, to: pb)
        nb.pasteCells(after: nb.cells[1].id, from: pb)

        #expect(nb.cells.count == 3)
        let pasted = nb.cells[2]
        #expect(pasted.id != source.id)
        #expect(pasted.source == source.source)
        #expect(pasted.kind == source.kind)
        #expect(pasted.outputs == source.outputs)
        #expect(nb.selectedCellID == pasted.id)

        // Pasting again must not collide with the first paste.
        nb.pasteCells(after: pasted.id, from: pb)
        #expect(Set(nb.cells.map(\.id)).count == nb.cells.count)
    }

    @Test("Cut removes the cell and leaves it on the pasteboard")
    func cutCell() throws {
        guard let pb = scratchPasteboard() else { return }
        let (nb, _, _) = try makeNotebook(["one", "two"])
        nb.cutCell(nb.cells[0].id, to: pb)
        #expect(nb.cells.map(\.source) == ["two"])
        nb.pasteCells(after: nb.cells[0].id, from: pb)
        #expect(nb.cells.map(\.source) == ["two", "one"])
    }

    /// Cut/copy/paste is how you move a cell more than one slot —
    /// the reason the ±1 swap was painful in a thirty-cell notebook.
    @Test("Cut and paste moves a cell across the notebook in one step")
    func cutAndPasteMovesFar() throws {
        guard let pb = scratchPasteboard() else { return }
        let (nb, _, _) = try makeNotebook(["a", "b", "c", "d", "e"])
        nb.cutCell(nb.cells[0].id, to: pb)
        nb.pasteCells(after: nb.cells.last?.id, from: pb)
        #expect(nb.cells.map(\.source) == ["b", "c", "d", "e", "a"])
    }

    @Test("Plain text on the pasteboard pastes as a code cell")
    func pastePlainText() throws {
        guard let pb = scratchPasteboard() else { return }
        pb.clearContents()
        pb.setString("Log \"hi\" to the <console>.", forType: .string)
        let (nb, _, _) = try makeNotebook(["one"])
        nb.pasteCells(after: nb.cells[0].id, from: pb)
        #expect(nb.cells.count == 2)
        #expect(nb.cells[1].kind == .code)
        #expect(nb.cells[1].source == "Log \"hi\" to the <console>.")
    }

    @Test("An empty pasteboard pastes nothing")
    func pasteNothing() throws {
        guard let pb = scratchPasteboard() else { return }
        pb.clearContents()
        let (nb, _, _) = try makeNotebook(["one"])
        #expect(nb.pasteCells(after: nb.cells[0].id, from: pb).isEmpty)
        #expect(nb.cells.count == 1)
    }

    @Test("Cells round-trip through the pasteboard with their outputs")
    func pasteboardRoundTrip() throws {
        guard let pb = scratchPasteboard() else { return }
        let cells = [
            ReplNotebookCell(kind: .markdown, source: "# Title"),
            ReplNotebookCell(kind: .code, source: "Compute the <n> from 1 + 1.",
                             outputs: [.result(plainText: "2", jsonValue: "2")],
                             executionCount: 7),
        ]
        ReplCellPasteboard.write(cells, to: pb)
        #expect(ReplCellPasteboard.read(from: pb) == cells)
        // The text flavour carries the sources for other editors.
        #expect(pb.string(forType: .string)?.contains("# Title") == true)
    }

    @Test("Duplicate puts a copy right below the original")
    func duplicate() throws {
        let (nb, _, _) = try makeNotebook(["one", "two"])
        nb.duplicateCell(nb.cells[0].id)
        #expect(nb.cells.map(\.source) == ["one", "one", "two"])
        #expect(nb.cells[0].id != nb.cells[1].id)
        #expect(nb.selectedCellID == nb.cells[1].id)
    }

    @Test("Merge folds the next cell into this one")
    func merge() async throws {
        let (nb, kernel, _) = try makeNotebook(["one", "two", "three"])
        kernel.streams = [(name: "stdout", text: "kept\n")]
        nb.runCell(nb.cells[0].id)
        await drain(nb)

        nb.mergeCellBelow(nb.cells[0].id)
        #expect(nb.cells.count == 2)
        #expect(nb.cells[0].source == "one\ntwo")
        #expect(nb.cells[0].outputs.first?.text == "kept\n")  // first cell's
        #expect(nb.selectedCellID == nb.cells[0].id)
        #expect(nb.cells[1].source == "three")
    }

    @Test("Merge on the last cell does nothing")
    func mergeAtEnd() throws {
        let (nb, _, _) = try makeNotebook(["one", "two"])
        nb.mergeCellBelow(nb.cells[1].id)
        #expect(nb.cells.map(\.source) == ["one", "two"])
    }

    @Test("Arrow navigation walks the cells and stops at the ends")
    func selectionNavigation() throws {
        let (nb, _, _) = try makeNotebook(["one", "two", "three"])
        nb.selectedCellID = nb.cells[0].id
        nb.selectCell(offset: -1)
        #expect(nb.selectedCellID == nb.cells[0].id)
        nb.selectCell(offset: 1)
        #expect(nb.selectedCellID == nb.cells[1].id)
        nb.selectCell(offset: 1)
        nb.selectCell(offset: 1)
        #expect(nb.selectedCellID == nb.cells[2].id)
        nb.selectedCellID = nil
        nb.selectCell(offset: 1)
        #expect(nb.selectedCellID == nb.cells[0].id)
    }

    @Test("Paste, duplicate and merge are all undoable")
    func cellCommandsAreUndoable() throws {
        guard let pb = scratchPasteboard() else { return }
        let (nb, _, manager) = try withUndo(["one", "two"])
        let original = nb.cells

        nb.copyCell(nb.cells[0].id, to: pb)
        undoable(manager) { nb.pasteCells(after: nb.cells[1].id, from: pb) }
        #expect(nb.cells.count == 3)
        manager.undo()
        #expect(nb.cells == original)

        undoable(manager) { nb.duplicateCell(nb.cells[0].id) }
        manager.undo()
        #expect(nb.cells == original)

        undoable(manager) { nb.mergeCellBelow(nb.cells[0].id) }
        #expect(nb.cells.count == 1)
        manager.undo()
        #expect(nb.cells == original)

        undoable(manager) { nb.cutCell(nb.cells[0].id, to: pb) }
        manager.undo()
        #expect(nb.cells == original)
    }
}

/// The command-mode key map (GitLab #538). Resolution goes through
/// KeybindingStore, so these also prove the keys are remappable
/// rather than hardcoded in the view.
@Suite("Notebook command-mode keys", .serialized)
@MainActor
struct NotebookKeyRouterTests {

    private func freshStore() -> KeybindingStore {
        let suite = "solaro.tests.notebookkeys.\(UUID().uuidString)"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        return KeybindingStore(defaults: UserDefaults(suiteName: suite)!)
    }

    @Test("Jupyter's defaults map to the right commands")
    func defaults() {
        let store = freshStore()
        func cmd(_ key: KeyEquivalent, _ mods: EventModifiers = [])
            -> NotebookCellCommand? {
            NotebookKeyRouter.command(key: key, modifiers: mods, store: store)
        }
        #expect(cmd("a") == .insertAbove)
        #expect(cmd("b") == .insertBelow)
        #expect(cmd("d") == .deleteCell)
        #expect(cmd("m") == .toMarkdown)
        #expect(cmd("y") == .toCode)
        #expect(cmd(.upArrow) == .selectAbove)
        #expect(cmd(.downArrow) == .selectBelow)
        #expect(cmd(.return) == .editCell)
        #expect(cmd("d", [.command]) == .duplicate)
    }

    /// The pair that makes modifier-exact matching necessary.
    @Test("M converts, ⇧M merges")
    func shiftMIsDistinct() {
        let store = freshStore()
        #expect(NotebookKeyRouter.command(key: "m", modifiers: [], store: store)
                == .toMarkdown)
        #expect(NotebookKeyRouter.command(key: "M", modifiers: [.shift], store: store)
                == .mergeBelow)
    }

    @Test("An unbound key matches nothing")
    func unbound() {
        let store = freshStore()
        #expect(NotebookKeyRouter.command(key: "q", modifiers: [], store: store) == nil)
        #expect(NotebookKeyRouter.command(key: "a", modifiers: [.control],
                                          store: store) == nil)
    }

    @Test("A remapped notebook key is honoured")
    func honoursOverride() {
        let store = freshStore()
        store.setOverride(KeybindingBinding(key: "i", modifiers: []),
                          for: "notebook.insertCellAbove")
        #expect(NotebookKeyRouter.command(key: "i", modifiers: [], store: store)
                == .insertAbove)
        #expect(NotebookKeyRouter.command(key: "a", modifiers: [], store: store) == nil)
    }

    @Test("Every command-mode command is in the registry")
    func allCommandsRegistered() {
        let known = Set(KeybindingRegistry.shared.map(\.id))
        for command in NotebookCellCommand.allCases {
            #expect(known.contains(command.rawValue),
                    "unregistered command id: \(command.rawValue)")
        }
    }

    @Test("Only delete asks for a second press")
    func doublePressOnlyForDelete() {
        for command in NotebookCellCommand.allCases {
            #expect(command.needsDoublePress == (command == .deleteCell))
        }
    }

    @Test("DD fires on the second press, and only inside the window")
    func doublePressLatch() {
        var latch = DoublePressLatch(window: 1.0)
        #expect(latch.press(at: 0) == false)
        #expect(latch.press(at: 0.4) == true)
        // Disarmed: the next press starts a new pair.
        #expect(latch.press(at: 0.5) == false)
        #expect(latch.press(at: 5.0) == false)   // too late, re-arms
        #expect(latch.press(at: 5.2) == true)
    }
}
