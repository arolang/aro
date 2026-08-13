// ============================================================
// MarkdownDocumentTests.swift
// SOLARO — positional markdown model (#488)
// ============================================================
//
// The inline markdown editor's correctness rests entirely on this
// model: block ↔ source-range mapping, byte-exact round-trips, and
// the structural edits (split / merge / promote) that have to
// produce the right blocks once the caret leaves. All of it is
// pure value types, so all of it is tested here rather than
// through the view.

import Testing
import Foundation
@testable import SOLARO

@Suite("MarkdownDocument")
struct MarkdownDocumentTests {

    private let sample = """
    # Title

    Intro paragraph that
    wraps across two lines.

    - one
    - two

    ```aro
    Log "hi" to the <console>.
    ```

    Closing words.
    """

    // MARK: - Ranges

    @Test("Blocks carry the source lines they were parsed from")
    func blockLineRanges() {
        let doc = MarkdownDocument(text: sample)
        #expect(doc.blocks.count == 5)
        #expect(doc.blocks[0].lineRange == 0..<1)      // # Title
        #expect(doc.blocks[1].lineRange == 2..<4)      // paragraph
        #expect(doc.blocks[2].lineRange == 5..<7)      // list
        #expect(doc.blocks[3].lineRange == 8..<11)     // fence incl. both ```
        #expect(doc.blocks[4].lineRange == 12..<13)    // closing
    }

    @Test("Raw source of a block is its exact bytes")
    func rawSourceIsExact() {
        let doc = MarkdownDocument(text: sample)
        #expect(doc.rawSource(at: 0) == "# Title")
        #expect(doc.rawSource(at: 1)
                == "Intro paragraph that\nwraps across two lines.")
        #expect(doc.rawSource(at: 3)
                == "```aro\nLog \"hi\" to the <console>.\n```")
    }

    @Test("Character ranges address the block inside the whole buffer")
    func characterRanges() {
        let doc = MarkdownDocument(text: sample)
        let text = Array(doc.text)
        for index in doc.blocks.indices {
            let range = doc.characterRange(at: index)
            #expect(String(text[range]) == doc.rawSource(at: index))
        }
    }

    @Test("Caret offsets convert to buffer coordinates and back")
    func caretRoundTrip() {
        let doc = MarkdownDocument(text: sample)
        // 5 characters into the second line of the paragraph block.
        let position = doc.caretLineColumn(blockIndex: 1, offset: 26)
        #expect(position.line == 3)
        #expect(position.column == 5)
        let back = doc.caretPosition(line: 3, column: 5)
        #expect(back == MarkdownCaretPosition(blockIndex: 1, offset: 26))
    }

    @Test("A blank separator line resolves to the block above it")
    func nearestBlockForBlankLine() {
        let doc = MarkdownDocument(text: sample)
        #expect(doc.blockIndex(forLine: 1) == nil)
        #expect(doc.nearestBlockIndex(toLine: 1) == 0)
    }

    // MARK: - Round-trip fidelity

    @Test("Visiting every block without typing leaves the file untouched",
          arguments: [
            "# A\n\nB\n",
            "text\r\nwith crlf\r\n",
            "- a\n- b\n\n\n\ntrailing blanks\n\n",
            "no trailing newline",
            "",
          ])
    func roundTripIsByteExact(source: String) {
        var doc = MarkdownDocument(text: source)
        #expect(doc.text == source)
        // Simulate the caret entering and leaving every block: the
        // editor writes the block's own source back unchanged.
        for index in doc.blocks.indices {
            let raw = doc.rawSource(at: index)
            doc.replaceSource(at: index, with: raw)
            doc.reparse(around: index)
        }
        #expect(doc.text == source)
    }

    // MARK: - Editing

    @Test("Typing in a block rewrites only that block's lines")
    func editIsLocal() {
        var doc = MarkdownDocument(text: sample)
        doc.replaceSource(at: 0, with: "# Renamed")
        #expect(doc.text.hasPrefix("# Renamed\n\nIntro"))
        #expect(doc.rawSource(at: 4) == "Closing words.")
    }

    @Test("Blocks after an edit that changes line count stay addressable")
    func rangesShiftAfterEdit() {
        var doc = MarkdownDocument(text: sample)
        doc.replaceSource(at: 0, with: "# Title\nsecond line")
        #expect(doc.blocks[1].lineRange == 3..<5)
        #expect(doc.rawSource(at: 4) == "Closing words.")
    }

    // MARK: - Structural edits

    @Test("A blank line splits a paragraph in two once the caret leaves")
    func blankLineSplitsParagraph() {
        var doc = MarkdownDocument(text: "alpha\nbeta\n")
        #expect(doc.blocks.count == 1)
        doc.replaceSource(at: 0, with: "alpha\n\nbeta")
        // Still one block while the caret is inside it.
        #expect(doc.blocks.count == 1)
        doc.reparse(around: 0)
        #expect(doc.blocks.count == 2)
        #expect(doc.rawSource(at: 0) == "alpha")
        #expect(doc.rawSource(at: 1) == "beta")
        #expect(doc.text == "alpha\n\nbeta\n")
    }

    @Test("Deleting the blank line between two paragraphs merges them")
    func mergeParagraphs() {
        var doc = MarkdownDocument(text: "alpha\n\nbeta\n")
        #expect(doc.blocks.count == 2)
        let landed = doc.mergeWithPrevious(at: 1)
        #expect(landed == MarkdownCaretPosition(blockIndex: 0, offset: 5))
        #expect(doc.blocks.count == 1)
        #expect(doc.rawSource(at: 0) == "alpha\nbeta")
        #expect(doc.text == "alpha\nbeta\n")
    }

    @Test("Merging adjacent blocks joins the boundary lines")
    func mergeAdjacentBlocks() {
        var doc = MarkdownDocument(text: "# Head\ntext\n")
        #expect(doc.blocks.count == 2)
        let landed = doc.mergeWithPrevious(at: 1)
        #expect(landed == MarkdownCaretPosition(blockIndex: 0, offset: 6))
        #expect(doc.text == "# Headtext\n")
    }

    @Test("mergeWithNext folds the following block into this one")
    func mergeForward() {
        var doc = MarkdownDocument(text: "alpha\n\nbeta\n")
        let landed = doc.mergeWithNext(at: 0)
        #expect(landed == MarkdownCaretPosition(blockIndex: 0, offset: 5))
        #expect(doc.text == "alpha\nbeta\n")
    }

    @Test("Typing `# ` promotes a paragraph to a heading on exit")
    func promoteToHeading() {
        var doc = MarkdownDocument(text: "alpha\n\nbeta\n")
        doc.replaceSource(at: 0, with: "# alpha")
        doc.reparse(around: 0)
        #expect(doc.blocks[0].block == .heading(level: 1, text: "alpha"))
        #expect(doc.blocks[1].block == .paragraph("beta"))
    }

    @Test("Emptying a block removes it and leaves the rest intact")
    func emptyingRemovesBlock() {
        var doc = MarkdownDocument(text: "alpha\n\nbeta\n")
        doc.replaceSource(at: 0, with: "")
        doc.reparse(around: 0)
        #expect(doc.blocks.count == 1)
        #expect(doc.rawSource(at: 0) == "beta")
    }

    @Test("Re-parsing a fence's region keeps it one block")
    func fenceStaysWhole() {
        var doc = MarkdownDocument(text: """
        ```
        one

        two
        ```

        after
        """)
        #expect(doc.blocks.count == 2)
        doc.replaceSource(at: 0, with: "```\none\n\ntwo\nthree\n```")
        doc.reparse(around: 0)
        #expect(doc.blocks.count == 2)
        if case .codeBlock(_, let body) = doc.blocks[0].block {
            #expect(body == "one\n\ntwo\nthree")
        } else {
            Issue.record("expected a code block, got \(doc.blocks[0].block)")
        }
    }

    @Test("Re-parsing one region does not disturb blocks outside it")
    func reparseIsLocal() {
        var doc = MarkdownDocument(text: sample)
        let untouched = doc.blocks[4]
        doc.replaceSource(at: 1, with: "Intro paragraph rewritten.")
        doc.reparse(around: 1)
        // Same block, same identity — SwiftUI keeps its view and
        // therefore its scroll position.
        #expect(doc.blocks.last?.id == untouched.id)
        #expect(doc.blocks.last?.block == untouched.block)
    }

    // MARK: - Parser robustness

    @Test("Pathological block openers terminate instead of spinning",
          arguments: [
            "| not | a | table |",
            "####### seven hashes",
            "|\n|\n|",
          ])
    func parserTerminates(source: String) {
        let doc = MarkdownDocument(text: source)
        #expect(!doc.blocks.isEmpty)
        #expect(doc.text == source)
    }
}

@Suite("MarkdownCaretEntry")
struct MarkdownCaretEntryTests {

    @Test("Entering from above lands on the first line at the column")
    func firstLine() {
        #expect(MarkdownCaretEntry.firstLine(column: 3)
            .resolve(in: "abcdef\nghi") == 3)
        // Clamped when the target line is shorter.
        #expect(MarkdownCaretEntry.firstLine(column: 30)
            .resolve(in: "ab\nghi") == 2)
    }

    @Test("Entering from below lands on the last line at the column")
    func lastLine() {
        #expect(MarkdownCaretEntry.lastLine(column: 2)
            .resolve(in: "abc\ndef") == 6)
        #expect(MarkdownCaretEntry.lastLine(column: 99)
            .resolve(in: "abc\ndef") == 7)
    }

    @Test("Explicit offsets clamp to the block")
    func offsets() {
        #expect(MarkdownCaretEntry.offset(2).resolve(in: "abcd") == 2)
        #expect(MarkdownCaretEntry.offset(99).resolve(in: "abcd") == 4)
        #expect(MarkdownCaretEntry.offset(-5).resolve(in: "abcd") == 0)
        #expect(MarkdownCaretEntry.end.resolve(in: "abcd") == 4)
    }
}

@Suite("MarkdownUndoStack")
struct MarkdownUndoStackTests {

    private func snapshot(_ text: String) -> MarkdownSnapshot {
        MarkdownSnapshot(text: text)
    }

    @Test("Undo returns the state recorded before the mutation")
    func undoRestores() {
        var stack = MarkdownUndoStack()
        stack.record(snapshot("a"), key: nil, at: 0)
        #expect(stack.canUndo)
        #expect(stack.undo(current: snapshot("ab")) == snapshot("a"))
        #expect(!stack.canUndo)
        #expect(stack.canRedo)
        #expect(stack.redo(current: snapshot("a")) == snapshot("ab"))
    }

    @Test("A run of keystrokes in one block collapses into one step")
    func coalescesTyping() {
        var stack = MarkdownUndoStack()
        stack.record(snapshot("a"), key: "block-1", at: 0)
        stack.record(snapshot("ab"), key: "block-1", at: 0.1)
        stack.record(snapshot("abc"), key: "block-1", at: 0.2)
        #expect(stack.undo(current: snapshot("abcd")) == snapshot("a"))
        #expect(!stack.canUndo)
    }

    @Test("Typing in a different block starts a new step")
    func differentBlockBreaksTheRun() {
        var stack = MarkdownUndoStack()
        stack.record(snapshot("a"), key: "block-1", at: 0)
        stack.record(snapshot("ab"), key: "block-2", at: 0.1)
        #expect(stack.undo(current: snapshot("abc")) == snapshot("ab"))
        #expect(stack.undo(current: snapshot("ab")) == snapshot("a"))
    }

    @Test("A pause between keystrokes starts a new step")
    func pauseBreaksTheRun() {
        var stack = MarkdownUndoStack()
        stack.record(snapshot("a"), key: "block-1", at: 0)
        stack.record(snapshot("ab"), key: "block-1", at: 10)
        #expect(stack.undo(current: snapshot("abc")) == snapshot("ab"))
        #expect(stack.undo(current: snapshot("ab")) == snapshot("a"))
    }

    @Test("Leaving a block breaks coalescing explicitly")
    func breakCoalescing() {
        var stack = MarkdownUndoStack()
        stack.record(snapshot("a"), key: "block-1", at: 0)
        stack.breakCoalescing()
        stack.record(snapshot("ab"), key: "block-1", at: 0.1)
        #expect(stack.undo(current: snapshot("abc")) == snapshot("ab"))
    }

    @Test("A fresh edit clears the redo stack")
    func editClearsRedo() {
        var stack = MarkdownUndoStack()
        stack.record(snapshot("a"), key: nil, at: 0)
        _ = stack.undo(current: snapshot("ab"))
        #expect(stack.canRedo)
        stack.record(snapshot("a"), key: nil, at: 1)
        #expect(!stack.canRedo)
    }
}

@Suite("MarkdownFile")
struct MarkdownFileTests {

    @Test("Claims .md and .markdown, case-insensitively",
          arguments: ["README.md", "notes.MARKDOWN", "a/b/c.Md"])
    func claimsMarkdown(path: String) {
        #expect(MarkdownFile.isMarkdown(URL(fileURLWithPath: path)))
    }

    @Test("Leaves other files to the code editor",
          arguments: ["main.aro", "openapi.yaml", "notes.txt", "mdx.mdx"])
    func ignoresOthers(path: String) {
        #expect(!MarkdownFile.isMarkdown(URL(fileURLWithPath: path)))
    }
}
