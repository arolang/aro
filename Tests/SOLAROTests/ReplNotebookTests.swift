// ============================================================
// ReplNotebookTests.swift
// SOLARO — .repl notebook document + display model (Swift Testing)
// ============================================================

import Testing
import Foundation
@testable import SOLARO

@Suite("ReplNotebookDocument")
struct ReplNotebookDocumentTests {

    private func tmpFile() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("solaro-repl-\(UUID().uuidString).repl")
    }

    @Test("Round-trips cells, outputs, and execution metadata")
    func roundTrip() throws {
        var doc = ReplNotebookDocument()
        doc.cells = [
            ReplNotebookCell(kind: .markdown, source: "# Title"),
            ReplNotebookCell(
                kind: .code,
                source: "Compute the <n: length> from \"abc\".",
                outputs: [
                    .stream(name: "stdout", text: "hi\n"),
                    .result(plainText: "3", jsonValue: "3"),
                ],
                executionCount: 4,
                durationMs: 12.5
            ),
            ReplNotebookCell(
                kind: .code,
                source: "Log <x> to the <console>.",
                outputs: [
                    .error(name: "AROError", value: "boom",
                           traceback: ["boom", "  at line 1"]),
                ]
            ),
        ]

        let url = tmpFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try doc.save(to: url)
        let loaded = try ReplNotebookDocument.load(from: url)

        #expect(loaded == doc)
        #expect(loaded.version == ReplNotebookDocument.currentVersion)
    }

    @Test("An empty file opens as an empty notebook")
    func emptyFile() throws {
        let url = tmpFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data().write(to: url)
        let loaded = try ReplNotebookDocument.load(from: url)
        #expect(loaded.cells.isEmpty)
    }

    @Test("A newer format version is refused, not mis-read")
    func newerVersionRefused() throws {
        let url = tmpFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"version": 99, "cells": []}"#.utf8).write(to: url)
        #expect(throws: ReplNotebookDocument.LoadError.self) {
            _ = try ReplNotebookDocument.load(from: url)
        }
    }

    @Test("Cells missing optional fields still decode")
    func lenientCellDecoding() throws {
        let url = tmpFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("""
        {"version": 1, "cells": [
            {"kind": "code", "source": "Log \\"x\\" to the <console>."},
            {"kind": "markdown"}
        ]}
        """.utf8).write(to: url)
        let loaded = try ReplNotebookDocument.load(from: url)
        #expect(loaded.cells.count == 2)
        #expect(loaded.cells[0].outputs.isEmpty)
        #expect(loaded.cells[1].source == "")
        // Ids are synthesized when absent — and stay unique.
        #expect(loaded.cells[0].id != loaded.cells[1].id)
    }

    @Test("The starter notebook encodes and re-opens")
    func starterRoundTrip() throws {
        let url = tmpFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try ReplNotebookDocument.starter(named: "Demo").save(to: url)
        let loaded = try ReplNotebookDocument.load(from: url)
        #expect(loaded.cells.count == 2)
        #expect(loaded.cells[0].kind == .markdown)
        #expect(loaded.cells[1].kind == .code)
    }
}

@Suite("ReplDisplayTable")
struct ReplDisplayTableTests {

    @Test("A list of records becomes a table with the union of keys")
    func listOfRecords() throws {
        let json = #"[{"name":"a","age":1},{"name":"b","city":"x"}]"#
        let table = try #require(ReplDisplayTable.fromJSON(json))
        // Column order: the first record's keys (sorted), then keys
        // later records introduce, in encounter order.
        #expect(table.columns == ["age", "name", "city"])
        #expect(table.rows.count == 2)
        #expect(table.rows[0] == ["1", "a", "—"])
        #expect(table.rows[1] == ["—", "b", "x"])
    }

    @Test("A single record becomes field/value rows")
    func singleRecord() throws {
        let table = try #require(
            ReplDisplayTable.fromJSON(#"{"name":"a","age":1}"#))
        #expect(table.columns == ["Field", "Value"])
        #expect(table.rows == [["age", "1"], ["name", "a"]])
    }

    @Test("Scalars and lists of scalars fall back to text/plain")
    func nonTabularShapes() {
        #expect(ReplDisplayTable.fromJSON("42") == nil)
        #expect(ReplDisplayTable.fromJSON(#""hello""#) == nil)
        #expect(ReplDisplayTable.fromJSON("[1,2,3]") == nil)
        #expect(ReplDisplayTable.fromJSON("[]") == nil)
        #expect(ReplDisplayTable.fromJSON("not json") == nil)
    }

    @Test("Row overflow is reported, not silently dropped")
    func rowTruncation() throws {
        let rows = (0..<150).map { #"{"i":\#($0)}"# }.joined(separator: ",")
        let table = try #require(ReplDisplayTable.fromJSON("[\(rows)]"))
        #expect(table.rows.count == ReplDisplayTable.maxRows)
        #expect(table.truncatedRowCount == 50)
    }
}
