// ============================================================
// NotebookReloadRaceTests.swift
// SOLARO — a notebook's own save does not reload over the user (#759)
// ============================================================
//
// The notebook autosaves atomically, which the kqueue watcher reports as
// a rename — so every save comes back as an external change. The guard
// against reloading over unsaved work was `saveTask == nil`, which asks
// the wrong question twice: saveNow clears it before the write, and the
// watcher's 200 ms debounce lands after. An edit made in that window was
// reloaded away, and load() replaced the cells wholesale and sent the
// selection back to the first cell.

import Testing
import Foundation
@testable import SOLARO

@Suite("Notebook reload race", .serialized)
@MainActor
struct NotebookReloadRaceTests {

    private func temporaryNotebook(
        _ doc: ReplNotebookDocument
    ) throws -> (URL, Project) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("solaro-nb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
        let url = root.appendingPathComponent("scratch.repl")
        try doc.save(to: url)
        return (url, Project(rootPath: root))
    }

    private var twoCells: ReplNotebookDocument {
        ReplNotebookDocument(cells: [
            ReplNotebookCell(id: "one", kind: .code, source: "first"),
            ReplNotebookCell(id: "two", kind: .code, source: "second"),
        ])
    }

    @Test func aSaveComingBackAsAWatcherEventChangesNothing() throws {
        let (url, project) = try temporaryNotebook(twoCells)
        defer { try? FileManager.default
            .removeItem(at: url.deletingLastPathComponent()) }

        let notebook = ReplNotebookController(url: url, project: project,
                                              saveDebounce: .milliseconds(10))
        notebook.updateSource("edited first", for: "one")
        notebook.saveNow()

        // This is the event the write itself produced, arriving after
        // saveNow has already cleared saveTask.
        notebook.reloadFromDiskIfUnedited()

        #expect(notebook.cells.first?.source == "edited first")
    }

    @Test func anEditMadeWhileTheSaveEventIsInFlightSurvives() throws {
        let (url, project) = try temporaryNotebook(twoCells)
        defer { try? FileManager.default
            .removeItem(at: url.deletingLastPathComponent()) }

        let notebook = ReplNotebookController(url: url, project: project,
                                              saveDebounce: .milliseconds(10))
        notebook.updateSource("saved", for: "one")
        notebook.saveNow()
        // The user keeps typing in the window between the write and the
        // debounced watcher event. This is the keystroke that used to
        // be thrown away.
        notebook.updateSource("still typing", for: "one")
        notebook.reloadFromDiskIfUnedited()

        #expect(notebook.cells.first?.source == "still typing")
    }

    @Test func agenuineExternalChangeIsStillPickedUp() throws {
        let (url, project) = try temporaryNotebook(twoCells)
        defer { try? FileManager.default
            .removeItem(at: url.deletingLastPathComponent()) }

        let notebook = ReplNotebookController(url: url, project: project,
                                              saveDebounce: .milliseconds(10))
        #expect(notebook.cells.first?.source == "first")

        // Somebody else writes the file — a checkout, a pull, another
        // editor. The model is stale and must catch up, which is the
        // whole reason this path exists.
        try ReplNotebookDocument(cells: [
            ReplNotebookCell(id: "one", kind: .code, source: "from git"),
            ReplNotebookCell(id: "two", kind: .code, source: "second"),
        ]).save(to: url)
        notebook.reloadFromDiskIfUnedited()

        #expect(notebook.cells.first?.source == "from git")
    }

    @Test func areloadKeepsTheReadersPlace() throws {
        let (url, project) = try temporaryNotebook(twoCells)
        defer { try? FileManager.default
            .removeItem(at: url.deletingLastPathComponent()) }

        let notebook = ReplNotebookController(url: url, project: project,
                                              saveDebounce: .milliseconds(10))
        notebook.selectedCellID = "two"

        try ReplNotebookDocument(cells: [
            ReplNotebookCell(id: "one", kind: .code, source: "changed"),
            ReplNotebookCell(id: "two", kind: .code, source: "second"),
        ]).save(to: url)
        notebook.reloadFromDiskIfUnedited()

        #expect(notebook.cells.first?.source == "changed")
        // A change further down the file should not jump the notebook
        // back to the top.
        #expect(notebook.selectedCellID == "two")
    }
}
