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
