// ============================================================
// NotebookMarkdownRenderingTests.swift
// SOLARO — markdown cells render what the author wrote
// ============================================================
//
// Two defects seen in the .repl notebook editor, both visible on the
// very first Learning notebook:
//
//   1. A bullet whose source wraps across lines broke into a bullet
//      plus a stray paragraph.
//   2. `<day-orders>` and friends disappeared from the rendered page.
//      Every ARO variable is written `<like-this>`, and a paragraph
//      containing one was classified as raw HTML and handed to
//      NSAttributedString's importer, which deletes what it reads as
//      unknown tags — so prose about ARO lost the ARO.

import Testing
import Foundation
@testable import SOLARO

@Suite("Notebook markdown rendering")
struct NotebookMarkdownRenderingTests {

    private func blocks(_ source: String) -> [BookMarkdownBlock] {
        BookMarkdownParser.parse(source)
    }

    // MARK: - Wrapped list items

    @Test("A wrapped bullet stays one bullet")
    func wrappedBulletIsOneItem() {
        let source = """
        - **`Create`** is an *OWN* action: it builds a value internally and
          binds it to a name. Nothing is read from outside.
        - The value is a **list of records** — square brackets for the list,
          curly braces for each record.
        """
        let parsed = blocks(source)
        #expect(parsed.count == 1, "expected one list block, got \(parsed.count)")
        guard case .unorderedList(let items) = parsed[0] else {
            Issue.record("expected an unordered list, got \(parsed[0])")
            return
        }
        #expect(items.count == 2)
        #expect(items[0].contains("binds it to a name"))
        #expect(items[1].contains("curly braces for each record"))
    }

    @Test("A wrapped numbered item stays one item")
    func wrappedOrderedItem() {
        let source = """
        1. First point that runs long enough
           to wrap onto a second line.
        2. Second point.
        """
        let parsed = blocks(source)
        #expect(parsed.count == 1)
        guard case .orderedList(let items) = parsed[0] else {
            Issue.record("expected an ordered list, got \(parsed[0])")
            return
        }
        #expect(items.count == 2)
        #expect(items[0].contains("to wrap onto a second line"))
    }

    @Test("A block after a list still ends the list")
    func blockEndsTheList() {
        let source = """
        - one
        - two

        ## A heading
        """
        let parsed = blocks(source)
        #expect(parsed.count == 2)
        guard case .unorderedList(let items) = parsed[0] else {
            Issue.record("expected a list first, got \(parsed[0])")
            return
        }
        #expect(items == ["one", "two"])
        guard case .heading = parsed[1] else {
            Issue.record("expected a heading second, got \(parsed[1])")
            return
        }
    }

    // MARK: - ARO variables are not HTML

    @Test("Prose naming ARO variables stays a paragraph", arguments: [
        "Every action has the same anatomy: `Action the <new-name> from the <source>`.",
        "`<day-orders>` now names this list for the whole session.",
        "Here <status> means each order's status.",
        "A record like <user: name> keeps its qualifier."
    ])
    func aroVariablesAreNotHTML(_ source: String) {
        let parsed = blocks(source)
        #expect(parsed.count == 1)
        guard case .paragraph(let text) = parsed[0] else {
            Issue.record("expected a paragraph, got \(parsed[0]) — the HTML importer would eat the variables")
            return
        }
        // The variable must survive into the block's text.
        #expect(text.contains("<"))
    }

    @Test("Real HTML is still recognised", arguments: [
        "<details><summary>More</summary>body</details>",
        "<table><tr><td>a</td></tr></table>",
        "<img src=\"x.png\" />",
        "<div class=\"note\">text</div>"
    ])
    func realHTMLStillRecognised(_ source: String) {
        let parsed = blocks(source)
        #expect(parsed.count == 1)
        guard case .htmlBlock = parsed[0] else {
            Issue.record("expected an html block, got \(parsed[0])")
            return
        }
    }

    @Test("HTML inside a code span is text, not markup")
    func htmlInCodeSpanIsText() {
        // Showing markup is not asking for it to be rendered.
        let parsed = blocks("Write `<div>` to open a block.")
        #expect(parsed.count == 1)
        guard case .paragraph = parsed[0] else {
            Issue.record("expected a paragraph, got \(parsed[0])")
            return
        }
    }

    @Test("The notebook's own prose survives round-trip")
    func courseProseRenders() {
        // Verbatim from Learning/06 — the cell that rendered wrong.
        let source = """
        ## What just happened

        - **`Create`** is an *OWN* action: it builds a value internally and
          binds it to a name. Nothing is read from outside, nothing leaves.
        - `<day-orders>` now names this list for the whole session. It will
          never change; every pipeline stage below derives a *new* name
          from it.

        Every pipeline action below has the same anatomy:
        `Action the <new-name> from the <source> …` — source in, fresh
        result out.
        """
        let parsed = blocks(source)
        #expect(parsed.count == 3, "heading + list + paragraph, got \(parsed.count)")
        guard case .unorderedList(let items) = parsed[1] else {
            Issue.record("expected the list second, got \(parsed[1])")
            return
        }
        #expect(items.count == 2)
        #expect(items[1].contains("<day-orders>"))
        guard case .paragraph(let tail) = parsed[2] else {
            Issue.record("expected a paragraph third, got \(parsed[2])")
            return
        }
        #expect(tail.contains("<new-name>"))
        #expect(tail.contains("<source>"))
    }
}

@Suite("Markdown cells render when you click away")
@MainActor
struct MarkdownBlurRenderTests {

    private func notebook(_ cells: [ReplNotebookCell]) -> ReplNotebookController {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("blur-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("notes.repl")
        try? ReplNotebookDocument(cells: cells).save(to: url)
        return ReplNotebookController(url: url, project: Project(rootPath: dir))
    }

    @Test("Selecting another cell renders the markdown left behind")
    func selectionAwayRenders() {
        let md = ReplNotebookCell(kind: .markdown, source: "# Title")
        let code = ReplNotebookCell(kind: .code, source: "Log 1 to the <console>.")
        let nb = notebook([md, code])
        nb.selectedCellID = md.id
        nb.editingMarkdownIDs.insert(md.id)

        nb.selectedCellID = code.id

        #expect(!nb.editingMarkdownIDs.contains(md.id),
                "clicking away is how a notebook user says 'done'")
    }

    @Test("The cell you move to keeps its open editor")
    func destinationKeepsEditing() {
        let a = ReplNotebookCell(kind: .markdown, source: "one")
        let b = ReplNotebookCell(kind: .markdown, source: "two")
        let nb = notebook([a, b])
        nb.selectedCellID = a.id
        nb.editingMarkdownIDs = [a.id, b.id]

        nb.selectedCellID = b.id

        #expect(!nb.editingMarkdownIDs.contains(a.id))
        #expect(nb.editingMarkdownIDs.contains(b.id), "a freshly opened cell stays open")
    }

    @Test("Staying on the same cell changes nothing")
    func sameSelectionIsNoOp() {
        let md = ReplNotebookCell(kind: .markdown, source: "# Title")
        let nb = notebook([md])
        nb.selectedCellID = md.id
        nb.editingMarkdownIDs.insert(md.id)

        nb.selectedCellID = md.id

        #expect(nb.editingMarkdownIDs.contains(md.id))
    }
}

@Suite("Opening a notebook doesn't dirty it")
@MainActor
struct NotebookSaveStabilityTests {

    @Test("A cell the editor normalised saves back byte-identical")
    func trailingNewlineIsNotAnEdit() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("stable-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("notes.repl")
        let cell = ReplNotebookCell(kind: .markdown, source: "# Title")
        try ReplNotebookDocument(cells: [cell]).save(to: url)
        let before = try Data(contentsOf: url)

        let nb = ReplNotebookController(url: url, project: Project(rootPath: dir))
        // What the text view does to a cell it displays.
        nb.updateSource("# Title\n", for: nb.cells[0].id)
        nb.saveNow()

        #expect(try Data(contentsOf: url) == before,
                "opening a notebook must not rewrite it")
    }

    @Test("Real edits still save")
    func realEditsPersist() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("stable-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("notes.repl")
        try ReplNotebookDocument(cells: [ReplNotebookCell(kind: .code, source: "one")]).save(to: url)

        let nb = ReplNotebookController(url: url, project: Project(rootPath: dir))
        nb.updateSource("one\ntwo", for: nb.cells[0].id)
        nb.saveNow()

        let reloaded = try ReplNotebookDocument.load(from: url)
        #expect(reloaded.cells[0].source == "one\ntwo")
    }
}

@Suite("A notebook is never written as text")
@MainActor
struct NotebookTextWriteGuardTests {

    private func project() throws -> (URL, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("notes.repl")
        try ReplNotebookDocument(cells: [
            ReplNotebookCell(kind: .markdown, source: "# Title"),
            ReplNotebookCell(kind: .code, source: "Log 1 to the <console>.")
        ]).save(to: url)
        return (dir, url)
    }

    @Test("An empty text write cannot truncate a notebook")
    func emptyWriteIsRefused() throws {
        let (dir, url) = try project()
        let before = try Data(contentsOf: url)
        let controller = WorkspaceController(project: Project(rootPath: dir))

        // What the editor's cache holds mid-load — and what used to
        // reach disk, leaving a 0-byte notebook.
        let wrote = controller.writeToDisk("", to: url)

        #expect(wrote == false, "the text path must refuse a notebook")
        #expect(try Data(contentsOf: url) == before)
        #expect(try ReplNotebookDocument.load(from: url).cells.count == 2)
    }

    @Test("Even valid-looking text is refused")
    func anyTextWriteIsRefused() throws {
        let (dir, url) = try project()
        let controller = WorkspaceController(project: Project(rootPath: dir))

        #expect(controller.writeToDisk("Log 2 to the <console>.", to: url) == false)
        #expect(try ReplNotebookDocument.load(from: url).cells.count == 2)
    }

    @Test("Ordinary source files still write")
    func sourceFilesUnaffected() throws {
        let (dir, _) = try project()
        let aro = dir.appendingPathComponent("main.aro")
        let controller = WorkspaceController(project: Project(rootPath: dir))

        #expect(controller.writeToDisk("Log 1 to the <console>.", to: aro) == true)
        #expect(try String(contentsOf: aro, encoding: .utf8) == "Log 1 to the <console>.")
    }
}

@Suite("A notebook notices the file changing underneath it")
@MainActor
struct NotebookExternalChangeTests {

    private func project() throws -> (URL, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ext-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("notes.repl")
        try ReplNotebookDocument(cells: [
            ReplNotebookCell(kind: .markdown, source: "# One"),
            ReplNotebookCell(kind: .code, source: "Log 1 to the <console>.")
        ]).save(to: url)
        return (dir, url)
    }

    @Test("A checkout under an open notebook is adopted, not overwritten")
    func adoptsDiskContents() throws {
        let (dir, url) = try project()
        let nb = ReplNotebookController(url: url, project: Project(rootPath: dir))
        #expect(nb.cells.count == 2)

        // What `git checkout` looks like from in here: the file now
        // holds different cells, in a different order.
        try ReplNotebookDocument(cells: [
            ReplNotebookCell(kind: .code, source: "Log 2 to the <console>."),
            ReplNotebookCell(kind: .markdown, source: "# Two"),
            ReplNotebookCell(kind: .code, source: "Log 3 to the <console>.")
        ]).save(to: url)

        nb.reloadFromDiskIfUnedited()

        #expect(nb.cells.count == 3, "the model must follow the file")
        #expect(nb.cells[0].kind == .code)
        #expect(nb.cells[1].source == "# Two")
    }

    @Test("Unsaved work outranks a background change")
    func keepsUnsavedEdits() throws {
        let (dir, url) = try project()
        let nb = ReplNotebookController(url: url, project: Project(rootPath: dir))
        // A markdown cell open for editing is work in progress.
        nb.editingMarkdownIDs.insert(nb.cells[0].id)

        try ReplNotebookDocument(cells: [
            ReplNotebookCell(kind: .code, source: "Log 9 to the <console>.")
        ]).save(to: url)

        nb.reloadFromDiskIfUnedited()

        #expect(nb.cells.count == 2, "the user's open editor is not discarded")
    }
}
