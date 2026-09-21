// ============================================================
// NotebookCellDecodingTests.swift
// SOLARO — a damaged cell fails the load (GitLab #760)
// ============================================================
//
// A cell whose fields were the wrong shape used to decode into an empty
// code cell with a freshly minted id, and the 800 ms autosave then wrote
// that back — losing the cell's contents and its identity permanently,
// without a message. The Learning course ships as .repl files that
// people edit, so the path is real.
//
// The distinction that matters is absent versus wrong. An omitted field
// is how a hand-written notebook is meant to look.

import Testing
import Foundation
@testable import SOLARO

@Suite("Notebook cell decoding")
struct NotebookCellDecodingTests {

    private func decode(_ json: String) throws -> ReplNotebookDocument {
        try JSONDecoder().decode(ReplNotebookDocument.self,
                                 from: Data(json.utf8))
    }

    @Test func aHandWrittenCellWithOnlyASourceStillOpens() throws {
        let doc = try decode(#"""
        {"version": 1, "cells": [{"source": "Log \"hi\" to the <console>."}]}
        """#)
        #expect(doc.cells.count == 1)
        #expect(doc.cells[0].kind == .code)
        #expect(doc.cells[0].outputs.isEmpty)
        #expect(!doc.cells[0].id.isEmpty)
        #expect(doc.cells[0].source == #"Log "hi" to the <console>."#)
    }

    @Test func anOmittedOutputsFieldMeansTheCellHasNotRun() throws {
        let doc = try decode(#"""
        {"version": 1, "cells": [{"id": "a", "kind": "markdown",
                                  "source": "# Title"}]}
        """#)
        #expect(doc.cells[0].outputs.isEmpty)
        #expect(doc.cells[0].id == "a")
    }

    @Test func aSourceOfTheWrongTypeFailsTheLoad() {
        // This is the bug: it used to become an empty code cell, and
        // the autosave wrote that over the real one.
        #expect(throws: (any Error).self) {
            try decode(#"{"version": 1, "cells": [{"id": "a", "source": 42}]}"#)
        }
    }

    @Test func anUnknownKindFailsTheLoad() {
        #expect(throws: (any Error).self) {
            try decode(#"""
            {"version": 1, "cells": [{"id": "a", "kind": "diagram",
                                      "source": "x"}]}
            """#)
        }
    }

    @Test func anIdOfTheWrongTypeFailsTheLoad() {
        // A new id would silently detach the cell from its history.
        #expect(throws: (any Error).self) {
            try decode(#"{"version": 1, "cells": [{"id": 7, "source": "x"}]}"#)
        }
    }

    @Test func malformedOutputsFailTheLoad() {
        #expect(throws: (any Error).self) {
            try decode(#"""
            {"version": 1, "cells": [{"id": "a", "source": "x",
                                      "outputs": "not a list"}]}
            """#)
        }
    }

    @Test func aGoodCellRoundTrips() throws {
        let original = ReplNotebookDocument(cells: [
            ReplNotebookCell(kind: .markdown, source: "# Hello"),
            ReplNotebookCell(kind: .code, source: "Compute the <n> from 1 + 1."),
        ])
        let decoded = try JSONDecoder().decode(
            ReplNotebookDocument.self, from: try original.encoded())
        #expect(decoded == original)
    }
}

@Suite("Shipped notebooks decode")
struct ShippedNotebookTests {

    /// Every `.repl` the repository ships must still open under the
    /// stricter decoder (#760) — the Learning course is the thing most
    /// at risk from tightening this.
    @Test func everyLearningNotebookLoads() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SOLAROTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Learning")
        let files = (try? FileManager.default
            .contentsOfDirectory(at: root, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "repl" } ?? []

        #expect(!files.isEmpty, "no .repl files found under Learning/")
        for file in files {
            let doc = try ReplNotebookDocument.load(from: file)
            #expect(!doc.cells.isEmpty,
                    "\(file.lastPathComponent) decoded to no cells")
        }
    }
}
