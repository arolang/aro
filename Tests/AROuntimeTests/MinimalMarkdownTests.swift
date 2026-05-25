import XCTest
@testable import ARORuntime

/// Tests for the built-in MinimalMarkdown helper introduced alongside
/// the `markdown` Compute qualifier and the `| markdown` template
/// filter. The subset is intentionally small — these tests pin the
/// contract for what the helper does and does not do.
final class MinimalMarkdownTests: XCTestCase {

    func testEmptyInputYieldsEmptyOutput() {
        XCTAssertEqual(MinimalMarkdown.toHTML(""), "")
    }

    func testPlainParagraphIsWrapped() {
        XCTAssertEqual(MinimalMarkdown.toHTML("Hello world."), "<p>Hello world.</p>")
    }

    func testTwoParagraphsSeparatedByBlankLine() {
        let md   = "First paragraph.\n\nSecond paragraph."
        let html = MinimalMarkdown.toHTML(md)
        XCTAssertEqual(html, "<p>First paragraph.</p>\n<p>Second paragraph.</p>")
    }

    func testATXHeadingsLevels1Through6() {
        for level in 1...6 {
            let hashes = String(repeating: "#", count: level)
            let html   = MinimalMarkdown.toHTML("\(hashes) Title")
            XCTAssertEqual(html, "<h\(level)>Title</h\(level)>")
        }
    }

    func testBoldAndItalicInline() {
        XCTAssertEqual(MinimalMarkdown.toHTML("a **bold** and *italic*."),
                       "<p>a <strong>bold</strong> and <em>italic</em>.</p>")
    }

    func testUnderscoreItalicAlternative() {
        XCTAssertEqual(MinimalMarkdown.toHTML("an _italic_ word."),
                       "<p>an <em>italic</em> word.</p>")
    }

    func testInlineCode() {
        // The minimal helper does not protect code-block content from
        // subsequent inline replacements; that's an accepted limitation
        // of the small CommonMark subset we ship. The contract here is
        // just "backtick spans land inside <code>".
        let html = MinimalMarkdown.toHTML("call `printf(\"hi\")` here.")
        XCTAssertEqual(html, "<p>call <code>printf(&quot;hi&quot;)</code> here.</p>")
    }

    func testLink() {
        let html = MinimalMarkdown.toHTML("see [the docs](https://example.com).")
        XCTAssertEqual(html, "<p>see <a href=\"https://example.com\">the docs</a>.</p>")
    }

    func testFencedCodeBlockIsEscaped() {
        let md = """
        ```
        let x = 1 < 2 && 3 > 2;
        ```
        """
        let html = MinimalMarkdown.toHTML(md)
        XCTAssertEqual(html, "<pre><code>let x = 1 &lt; 2 &amp;&amp; 3 &gt; 2;</code></pre>")
    }

    func testFencedCodeBlockKeepsBlankLines() {
        // The block-splitter must not break inside a fence.
        let md = """
        ```
        a

        b
        ```
        """
        let html = MinimalMarkdown.toHTML(md)
        XCTAssertEqual(html, "<pre><code>a\n\nb</code></pre>")
    }

    func testHTMLSpecialsInProseAreEscaped() {
        let html = MinimalMarkdown.toHTML("compare 1 < 2 & 3 > 0")
        XCTAssertEqual(html, "<p>compare 1 &lt; 2 &amp; 3 &gt; 0</p>")
    }
}
