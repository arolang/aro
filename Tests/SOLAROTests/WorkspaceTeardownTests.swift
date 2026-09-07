// ============================================================
// WorkspaceTeardownTests.swift
// SOLARO — workspace teardown wiring (GitLab #529)
// ============================================================
//
// The GUI paths that trigger teardown (Close Project, window
// close, ⌘Q) can't be driven headless; what CAN be verified is the
// teardown itself: it must flush every notebook's debounced
// autosave immediately (the 800ms debounce loses the last edit on
// quit otherwise), shut the notebook controllers down, and be safe
// to call twice.

import Testing
import Foundation
@testable import SOLARO

@Suite("WorkspaceController teardown")
struct WorkspaceTeardownTests {

    private func makeScratchProject() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("solaro-teardown-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("teardown() flushes the debounced notebook autosave and clears the controllers")
    @MainActor
    func flushesAutosaveAndClears() throws {
        let root = try makeScratchProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let replURL = root.appendingPathComponent("nb.repl")
        var doc = ReplNotebookDocument()
        doc.cells = [ReplNotebookCell(kind: .code, source: "old")]
        try doc.save(to: replURL)

        let controller = WorkspaceController(project: Project(rootPath: root))
        let notebook = controller.replNotebook(for: replURL)
        let cellID = try #require(notebook.cells.first?.id)
        // Schedules the 800ms debounced save — on ⌘Q that timer
        // never fired and the edit was lost (GitLab #529).
        notebook.updateSource("new source", for: cellID)

        controller.teardown()

        let loaded = try ReplNotebookDocument.load(from: replURL)
        #expect(loaded.cells.first?.source == "new source")
        #expect(controller.replNotebooks.isEmpty)
    }

    @Test("teardown() is idempotent")
    @MainActor
    func idempotent() throws {
        let root = try makeScratchProject()
        defer { try? FileManager.default.removeItem(at: root) }

        let controller = WorkspaceController(project: Project(rootPath: root))
        controller.teardown()
        controller.teardown()   // second call must be a no-op, not a crash
        #expect(controller.replNotebooks.isEmpty)
        #expect(controller.lsp.serverStatus == .stopped)
    }
}
