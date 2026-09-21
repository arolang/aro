// ============================================================
// NotebookIpynbTests.swift
// SOLARO — `.repl` ↔ `.ipynb` (GitLab #769)
// ============================================================
//
// The book positions notebooks as the Jupyter-parity surface and ARO
// ships a real Jupyter kernel, but handing a notebook to somebody in
// JupyterLab needed the format JupyterLab reads, and there was neither
// an export nor an import.

import Testing
import Foundation
@testable import SOLARO

@Suite("Jupyter notebook interchange")
struct NotebookIpynbTests {

    private var sample: ReplNotebookDocument {
        ReplNotebookDocument(cells: [
            ReplNotebookCell(id: "intro", kind: .markdown,
                             source: "# Hello\n\nAn ARO notebook."),
            ReplNotebookCell(
                id: "code", kind: .code,
                source: "Compute the <n> from 1 + 1.",
                outputs: [
                    ReplCellOutput(kind: .stream, streamName: "stdout",
                                   text: "2\n"),
                    ReplCellOutput(kind: .result, plainText: "2",
                                   jsonValue: "{\"n\":2}"),
                ],
                executionCount: 3),
        ])
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data)
                        as? [String: Any])
    }

    @Test func exportsNbformat4() throws {
        let root = try object(try NotebookIpynb.export(sample))
        #expect(root["nbformat"] as? Int == 4)
        #expect(root["nbformat_minor"] as? Int == 5)
    }

    @Test func declaresTheAROKernel() throws {
        // Without this, opening the file asks which kernel to use,
        // every time.
        let root = try object(try NotebookIpynb.export(sample))
        let metadata = try #require(root["metadata"] as? [String: Any])
        let kernelspec = try #require(metadata["kernelspec"] as? [String: Any])
        #expect(kernelspec["name"] as? String == "aro")
        #expect(kernelspec["display_name"] as? String == "ARO")
    }

    @Test func cellTypesAndSourcesSurvive() throws {
        let root = try object(try NotebookIpynb.export(sample))
        let cells = try #require(root["cells"] as? [[String: Any]])
        #expect(cells.count == 2)
        #expect(cells[0]["cell_type"] as? String == "markdown")
        #expect(cells[1]["cell_type"] as? String == "code")
        #expect(cells[1]["execution_count"] as? Int == 3)
        // nbformat 4.5 gives every cell a stable id, which is what
        // makes a notebook diff rather than re-write.
        #expect(cells[0]["id"] as? String == "intro")
    }

    @Test func textIsSplitIntoLinesWithTheirNewlines() {
        // What nbformat says, and what makes an .ipynb diff line by
        // line instead of as one long string.
        #expect(NotebookIpynb.sourceLines("a\nb\n") == ["a\n", "b\n"])
        #expect(NotebookIpynb.sourceLines("a\nb") == ["a\n", "b"])
        #expect(NotebookIpynb.sourceLines("") == [])
    }

    @Test func aMarkdownCellHasNoOutputsField() throws {
        // Jupyter rejects a markdown cell that carries outputs.
        let root = try object(try NotebookIpynb.export(sample))
        let cells = try #require(root["cells"] as? [[String: Any]])
        #expect(cells[0]["outputs"] == nil)
        #expect(cells[0]["execution_count"] == nil)
    }

    // MARK: - Import

    @Test func aRoundTripKeepsWhatBothFormatsHave() throws {
        let exported = try NotebookIpynb.export(sample)
        let back = try NotebookIpynb.importNotebook(exported)
        #expect(back.cells.count == 2)
        #expect(back.cells[0].kind == .markdown)
        #expect(back.cells[0].source == "# Hello\n\nAn ARO notebook.")
        #expect(back.cells[1].source == "Compute the <n> from 1 + 1.")
        #expect(back.cells[1].executionCount == 3)
        #expect(back.cells[1].outputs.count == 2)
        #expect(back.cells[1].outputs[0].text == "2\n")
        #expect(back.cells[1].outputs[1].plainText == "2")
    }

    @Test func readsTextGivenAsAPlainString() throws {
        // nbformat allows either a string or a list of lines for any
        // text field, and real notebooks in the wild contain both.
        let json = #"""
        {"nbformat": 4, "nbformat_minor": 5, "metadata": {},
         "cells": [{"cell_type": "code", "source": "Log \"hi\".",
                    "outputs": [], "execution_count": null}]}
        """#
        let document = try NotebookIpynb.importNotebook(Data(json.utf8))
        #expect(document.cells.first?.source == #"Log "hi"."#)
    }

    @Test func aRawCellBecomesMarkdownSoItsTextSurvives() throws {
        let json = """
        {"nbformat": 4, "nbformat_minor": 5, "metadata": {},
         "cells": [{"cell_type": "raw", "source": ["verbatim\\n"]}]}
        """
        let document = try NotebookIpynb.importNotebook(Data(json.utf8))
        // Not code — running it would be wrong — but not discarded.
        #expect(document.cells.first?.kind == .markdown)
        #expect(document.cells.first?.source == "verbatim\n")
    }

    @Test func anErrorOutputSurvives() throws {
        let json = """
        {"nbformat": 4, "nbformat_minor": 5, "metadata": {},
         "cells": [{"cell_type": "code", "source": "x", "outputs": [
            {"output_type": "error", "ename": "ParseError",
             "evalue": "unexpected token", "traceback": ["line 1"]}]}]}
        """
        let document = try NotebookIpynb.importNotebook(Data(json.utf8))
        let output = try #require(document.cells.first?.outputs.first)
        #expect(output.kind == .error)
        #expect(output.errorName == "ParseError")
        #expect(output.traceback == ["line 1"])
    }

    @Test func aFileThatIsNotANotebookIsRefused() {
        #expect(throws: (any Error).self) {
            try NotebookIpynb.importNotebook(Data("{}".utf8))
        }
        #expect(throws: (any Error).self) {
            try NotebookIpynb.importNotebook(Data("not json".utf8))
        }
    }

    @Test func anOlderNbformatIsRefusedWithItsVersion() {
        // Better than a silent misread: nbformat 3 nests cells inside
        // worksheets and would import as nothing.
        #expect(throws: (any Error).self) {
            try NotebookIpynb.importNotebook(Data(
                #"{"nbformat": 3, "cells": []}"#.utf8))
        }
    }
}

@Suite("Notebook strip outputs on save", .serialized)
@MainActor
struct NotebookStripOutputsTests {

    private func temporaryNotebook() throws -> (URL, Project) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("solaro-strip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
        let url = root.appendingPathComponent("scratch.repl")
        try ReplNotebookDocument(cells: [
            ReplNotebookCell(id: "one", kind: .code, source: "x",
                             outputs: [ReplCellOutput(kind: .stream,
                                                      streamName: "stdout",
                                                      text: "1\n")],
                             executionCount: 1, durationMs: 4),
        ]).save(to: url)
        return (url, Project(rootPath: root))
    }

    private func withSetting(_ value: Bool, _ body: () throws -> Void) rethrows {
        let key = SolaroPrefs.notebookStripOutputs.rawValue
        let previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(value, forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }
        try body()
    }

    @Test func offByDefaultTheOutputsAreWritten() throws {
        let (url, project) = try temporaryNotebook()
        defer { try? FileManager.default
            .removeItem(at: url.deletingLastPathComponent()) }

        try withSetting(false) {
            let notebook = ReplNotebookController(url: url, project: project,
                                                  saveDebounce: .milliseconds(10))
            notebook.updateSource("y", for: "one")
            notebook.saveNow()
            let saved = try ReplNotebookDocument.load(from: url)
            #expect(saved.cells[0].outputs.count == 1)
            #expect(saved.cells[0].executionCount == 1)
        }
    }

    @Test func onTheFileHasNoOutputsButTheBufferStillDoes() throws {
        let (url, project) = try temporaryNotebook()
        defer { try? FileManager.default
            .removeItem(at: url.deletingLastPathComponent()) }

        try withSetting(true) {
            let notebook = ReplNotebookController(url: url, project: project,
                                                  saveDebounce: .milliseconds(10))
            notebook.updateSource("y", for: "one")
            notebook.saveNow()

            let saved = try ReplNotebookDocument.load(from: url)
            // The point: a notebook that was read should not show up as
            // changed because its cells re-rendered.
            #expect(saved.cells[0].outputs.isEmpty)
            #expect(saved.cells[0].executionCount == nil)
            #expect(saved.cells[0].durationMs == nil)
            #expect(saved.cells[0].source == "y")

            // The user is still looking at the outputs, so the buffer
            // keeps them — this is a property of the file, not of the
            // session.
            #expect(notebook.cells[0].outputs.count == 1)
        }
    }
}
