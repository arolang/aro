// ============================================================
// NotebookOutputCapTests.swift
// SOLARO — a chatty cell cannot grow without bound (GitLab #531)
// ============================================================
//
// `appendStream` had no cap on either the number of outputs or the length of
// the accumulated text, so a loop that logs per iteration grew MainActor
// state without limit and autosaved all of it into the `.repl` JSON. These
// assert the arithmetic of the cap, the notice that replaces what was
// dropped, and that the notice stays out of the way of everything that reads
// a stream output.

import Testing
import Foundation
@testable import SOLARO

@Suite("Notebook output cap")
struct NotebookOutputCapTests {

    private func text(bytes: Int) -> String {
        String(repeating: "x", count: bytes)
    }

    @Test func admitsEverythingBelowTheCap() {
        var budget = NotebookStreamBudget()
        let chunk = text(bytes: 1000)
        for _ in 0..<10 {
            #expect(budget.admit(chunk) == chunk)
        }
        #expect(budget.kept == 10_000)
        #expect(budget.suppressed == 0)
        #expect(budget.isTruncated == false)
    }

    @Test func keepsTheHeadAndAccountsForTheTail() {
        var budget = NotebookStreamBudget()
        let cap = NotebookStreamBudget.byteCap
        let admitted = budget.admit(text(bytes: cap + 500))
        // The head is kept, not the tail: where a runaway loop started is
        // the half worth reading, and it is the half that stays stable as
        // the run continues.
        #expect(admitted.utf8.count == cap)
        #expect(budget.kept == cap)
        #expect(budget.suppressed == 500)
        #expect(budget.isTruncated)
    }

    @Test func refusesEverythingOnceFull() {
        var budget = NotebookStreamBudget()
        _ = budget.admit(text(bytes: NotebookStreamBudget.byteCap))
        #expect(budget.isTruncated == false, "exactly at the cap is not over it")
        #expect(budget.admit(text(bytes: 100)) == "")
        #expect(budget.admit(text(bytes: 100)) == "")
        #expect(budget.suppressed == 200, "every refused byte is counted")
        #expect(budget.kept == NotebookStreamBudget.byteCap, "nothing more is kept")
    }

    @Test func aResetStartsTheNextRunWithAFullBudget() {
        var budget = NotebookStreamBudget()
        _ = budget.admit(text(bytes: NotebookStreamBudget.byteCap + 1))
        #expect(budget.isTruncated)
        budget.reset()
        #expect(budget.kept == 0)
        #expect(budget.suppressed == 0)
        #expect(budget.isTruncated == false)
        #expect(budget.admit("hello") == "hello")
    }

    @Test func anEmptyChunkCostsNothing() {
        var budget = NotebookStreamBudget()
        #expect(budget.admit("") == "")
        #expect(budget.kept == 0)
        #expect(budget.suppressed == 0)
    }

    // MARK: - Where the cut lands

    @Test func cutsAtALineBoundaryWhenOneIsNear() {
        let text = "alpha\nbeta\ngamma\n"
        let head = NotebookStreamBudget.head(of: text, withinBytes: 13)
        // 13 bytes reaches into "gamma"; the cut falls back to the end of
        // "beta" so the kept output ends on a whole line.
        #expect(head == "alpha\nbeta\n")
    }

    @Test func keepsThePrefixOfASingleEnormousLine() {
        // No newline to fall back to, and a line boundary at the very start
        // would throw away almost everything — so the prefix is kept.
        let head = NotebookStreamBudget.head(of: "a\n" + String(repeating: "b", count: 100),
                                             withinBytes: 50)
        #expect(head.utf8.count == 50)
        #expect(head.hasPrefix("a\nbbb"))
    }

    @Test func neverSplitsAMultiByteScalar() {
        // "é" is two UTF-8 bytes; a budget that lands mid-scalar must stop
        // before it rather than emit a replacement character.
        let head = NotebookStreamBudget.head(of: "éé", withinBytes: 3)
        #expect(head == "é")
        #expect(head.utf8.count == 2)
        #expect(!head.contains("\u{FFFD}"))
    }

    // MARK: - The notice

    @Test func theNoticeNamesWhatWasDropped() {
        var budget = NotebookStreamBudget()
        _ = budget.admit(text(bytes: NotebookStreamBudget.byteCap + 2_100_000))
        #expect(budget.notice.contains("truncated"))
        #expect(budget.notice.contains("2.0 MB"))
    }

    @Test func byteCountsReadAsSizes() {
        #expect(NotebookStreamBudget.formatBytes(512) == "512 B")
        #expect(NotebookStreamBudget.formatBytes(2048) == "2.0 KB")
        #expect(NotebookStreamBudget.formatBytes(3 * 1024 * 1024) == "3.0 MB")
    }

    @Test func theNoticeIsDistinguishableFromProgramOutput() {
        let notice = ReplCellOutput.truncationNotice("…")
        #expect(notice.isTruncationNotice)
        #expect(notice.kind == .stream)
        // Nothing a kernel can emit collides with it: the protocol's stream
        // names are stdout and stderr.
        #expect(!ReplCellOutput.stream(name: "stdout", text: "x").isTruncationNotice)
        #expect(!ReplCellOutput.stream(name: "stderr", text: "x").isTruncationNotice)
    }

    @Test func theNoticeSurvivesADocumentRoundTrip() throws {
        let cell = ReplNotebookCell(
            kind: .code, source: "Log \"x\" to the <console>.",
            outputs: [.stream(name: "stdout", text: "x\n"),
                      .truncationNotice("… output truncated — 1.0 MB more suppressed.")])
        let data = try JSONEncoder().encode(cell)
        let back = try JSONDecoder().decode(ReplNotebookCell.self, from: data)
        #expect(back.outputs.count == 2)
        #expect(back.outputs.last?.isTruncationNotice == true)
    }

    @Test func ipynbExportUsesAStreamNameJupyterAccepts() throws {
        // nbformat allows exactly "stdout" and "stderr"; the reserved name
        // must not reach the file.
        let document = ReplNotebookDocument(cells: [
            ReplNotebookCell(kind: .code, source: "x",
                             outputs: [.truncationNotice("… output truncated.")])
        ])
        let json = try NotebookIpynb.export(document)
        let object = try JSONSerialization.jsonObject(with: json) as? [String: Any]
        let cells = object?["cells"] as? [[String: Any]]
        let outputs = cells?.first?["outputs"] as? [[String: Any]]
        let name = outputs?.first?["name"] as? String
        #expect(name == "stderr")
        #expect(json.count > 0)
    }
}
