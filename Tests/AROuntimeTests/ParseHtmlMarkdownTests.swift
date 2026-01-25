// ============================================================
// ParseHtmlMarkdownTests.swift
// ARO Runtime - ParseHtml Markdown Specifier Unit Tests
// ============================================================

import Foundation
import Testing
@testable import ARORuntime
@testable import AROParser

@Suite("ParseHtml Markdown Tests")
struct ParseHtmlMarkdownTests {

    func createDescriptors(
        resultBase: String = "result",
        resultSpecifiers: [String] = ["markdown"],
        objectBase: String = "html",
        preposition: Preposition = .from
    ) -> (ResultDescriptor, ObjectDescriptor) {
        let span = SourceSpan(at: SourceLocation())
        let result = ResultDescriptor(base: resultBase, specifiers: resultSpecifiers, span: span)
        let object = ObjectDescriptor(preposition: preposition, base: objectBase, specifiers: [], span: span)
        return (result, object)
    }

    // MARK: - Basic Tests

    @Test("ParseHtml markdown extracts title")
    func testMarkdownExtractsTitle() async throws {
        let action = ParseHtmlAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("html", value: "<html><head><title>My Page</title></head><body><p>Content</p></body></html>")

        let (result, object) = createDescriptors()
        let value = try await action.execute(result: result, object: object, context: context)

        let dict = value as? [String: any Sendable]
        #expect(dict?["title"] as? String == "My Page")
    }

    @Test("ParseHtml markdown returns markdown key")
    func testMarkdownReturnsMarkdownKey() async throws {
        let action = ParseHtmlAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("html", value: "<body><p>Hello</p></body>")

        let (result, object) = createDescriptors()
        let value = try await action.execute(result: result, object: object, context: context)

        let dict = value as? [String: any Sendable]
        #expect(dict?["markdown"] != nil)
    }

    // MARK: - Heading Tests

    @Test("ParseHtml markdown converts h1 heading")
    func testMarkdownConvertH1() async throws {
        let action = ParseHtmlAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("html", value: "<body><h1>Title</h1></body>")

        let (result, object) = createDescriptors()
        let value = try await action.execute(result: result, object: object, context: context)

        let dict = value as? [String: any Sendable]
        let md = dict?["markdown"] as? String ?? ""
        #expect(md.contains("# Title"))
    }

    @Test("ParseHtml markdown converts h2 heading")
    func testMarkdownConvertH2() async throws {
        let action = ParseHtmlAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("html", value: "<body><h2>Subtitle</h2></body>")

        let (result, object) = createDescriptors()
        let value = try await action.execute(result: result, object: object, context: context)

        let dict = value as? [String: any Sendable]
        let md = dict?["markdown"] as? String ?? ""
        #expect(md.contains("## Subtitle"))
    }

    @Test("ParseHtml markdown converts all heading levels")
    func testMarkdownConvertAllHeadings() async throws {
        let action = ParseHtmlAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("html", value: """
            <body>
            <h1>H1</h1>
            <h2>H2</h2>
            <h3>H3</h3>
            <h4>H4</h4>
            <h5>H5</h5>
            <h6>H6</h6>
            </body>
            """)

        let (result, object) = createDescriptors()
        let value = try await action.execute(result: result, object: object, context: context)

        let dict = value as? [String: any Sendable]
        let md = dict?["markdown"] as? String ?? ""
        #expect(md.contains("# H1"))
        #expect(md.contains("## H2"))
        #expect(md.contains("### H3"))
        #expect(md.contains("#### H4"))
        #expect(md.contains("##### H5"))
        #expect(md.contains("###### H6"))
    }

    // MARK: - Link Tests

    @Test("ParseHtml markdown converts links")
    func testMarkdownConvertLinks() async throws {
        let action = ParseHtmlAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("html", value: "<body><a href=\"https://example.com\">Click here</a></body>")

        let (result, object) = createDescriptors()
        let value = try await action.execute(result: result, object: object, context: context)

        let dict = value as? [String: any Sendable]
        let md = dict?["markdown"] as? String ?? ""
        #expect(md.contains("[Click here](https://example.com)"))
    }

    @Test("ParseHtml markdown escapes parentheses in URLs")
    func testMarkdownEscapesUrlParentheses() async throws {
        let action = ParseHtmlAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("html", value: "<body><a href=\"https://example.com/path(1)\">Link</a></body>")

        let (result, object) = createDescriptors()
        let value = try await action.execute(result: result, object: object, context: context)

        let dict = value as? [String: any Sendable]
        let md = dict?["markdown"] as? String ?? ""
        #expect(md.contains("[Link](https://example.com/path%281%29)"))
    }

    // MARK: - Inline Formatting Tests

    @Test("ParseHtml markdown converts bold")
    func testMarkdownConvertBold() async throws {
        let action = ParseHtmlAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("html", value: "<body><p><strong>bold text</strong></p></body>")

        let (result, object) = createDescriptors()
        let value = try await action.execute(result: result, object: object, context: context)

        let dict = value as? [String: any Sendable]
        let md = dict?["markdown"] as? String ?? ""
        #expect(md.contains("**bold text**"))
    }

    @Test("ParseHtml markdown converts italic")
    func testMarkdownConvertItalic() async throws {
        let action = ParseHtmlAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("html", value: "<body><p><em>italic text</em></p></body>")

        let (result, object) = createDescriptors()
        let value = try await action.execute(result: result, object: object, context: context)

        let dict = value as? [String: any Sendable]
        let md = dict?["markdown"] as? String ?? ""
        #expect(md.contains("*italic text*"))
    }

    @Test("ParseHtml markdown converts inline code")
    func testMarkdownConvertInlineCode() async throws {
        let action = ParseHtmlAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("html", value: "<body><p>Use <code>print()</code> function</p></body>")

        let (result, object) = createDescriptors()
        let value = try await action.execute(result: result, object: object, context: context)

        let dict = value as? [String: any Sendable]
        let md = dict?["markdown"] as? String ?? ""
        #expect(md.contains("`print()`"))
    }

    @Test("ParseHtml markdown converts strikethrough")
    func testMarkdownConvertStrikethrough() async throws {
        let action = ParseHtmlAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("html", value: "<body><p><del>deleted</del></p></body>")

        let (result, object) = createDescriptors()
        let value = try await action.execute(result: result, object: object, context: context)

        let dict = value as? [String: any Sendable]
        let md = dict?["markdown"] as? String ?? ""
        #expect(md.contains("~~deleted~~"))
    }

    // MARK: - List Tests

    @Test("ParseHtml markdown converts unordered lists")
    func testMarkdownConvertUnorderedLists() async throws {
        let action = ParseHtmlAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("html", value: "<body><ul><li>Item 1</li><li>Item 2</li></ul></body>")

        let (result, object) = createDescriptors()
        let value = try await action.execute(result: result, object: object, context: context)

        let dict = value as? [String: any Sendable]
        let md = dict?["markdown"] as? String ?? ""
        #expect(md.contains("- Item 1"))
        #expect(md.contains("- Item 2"))
    }

    @Test("ParseHtml markdown converts ordered lists")
    func testMarkdownConvertOrderedLists() async throws {
        let action = ParseHtmlAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("html", value: "<body><ol><li>First</li><li>Second</li></ol></body>")

        let (result, object) = createDescriptors()
        let value = try await action.execute(result: result, object: object, context: context)

        let dict = value as? [String: any Sendable]
        let md = dict?["markdown"] as? String ?? ""
        #expect(md.contains("1. First"))
        #expect(md.contains("2. Second"))
    }

    // MARK: - Table Tests

    @Test("ParseHtml markdown converts tables")
    func testMarkdownConvertTables() async throws {
        let action = ParseHtmlAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("html", value: """
            <body>
            <table>
                <thead><tr><th>Name</th><th>Age</th></tr></thead>
                <tbody><tr><td>Alice</td><td>30</td></tr></tbody>
            </table>
            </body>
            """)

        let (result, object) = createDescriptors()
        let value = try await action.execute(result: result, object: object, context: context)

        let dict = value as? [String: any Sendable]
        let md = dict?["markdown"] as? String ?? ""
        #expect(md.contains("| Name | Age |"))
        #expect(md.contains("|---|---|"))
        #expect(md.contains("| Alice | 30 |"))
    }

    @Test("ParseHtml markdown escapes pipes in table cells")
    func testMarkdownEscapesPipesInTables() async throws {
        let action = ParseHtmlAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("html", value: """
            <body>
            <table>
                <tr><th>Header</th></tr>
                <tr><td>Value | with pipe</td></tr>
            </table>
            </body>
            """)

        let (result, object) = createDescriptors()
        let value = try await action.execute(result: result, object: object, context: context)

        let dict = value as? [String: any Sendable]
        let md = dict?["markdown"] as? String ?? ""
        #expect(md.contains("Value \\| with pipe"))
    }

    // MARK: - Blockquote Tests

    @Test("ParseHtml markdown converts blockquotes")
    func testMarkdownConvertBlockquotes() async throws {
        let action = ParseHtmlAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("html", value: "<body><blockquote>Quoted text</blockquote></body>")

        let (result, object) = createDescriptors()
        let value = try await action.execute(result: result, object: object, context: context)

        let dict = value as? [String: any Sendable]
        let md = dict?["markdown"] as? String ?? ""
        #expect(md.contains("> Quoted text"))
    }

    // MARK: - Code Block Tests

    @Test("ParseHtml markdown converts code blocks")
    func testMarkdownConvertCodeBlocks() async throws {
        let action = ParseHtmlAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("html", value: "<body><pre><code>let x = 1</code></pre></body>")

        let (result, object) = createDescriptors()
        let value = try await action.execute(result: result, object: object, context: context)

        let dict = value as? [String: any Sendable]
        let md = dict?["markdown"] as? String ?? ""
        #expect(md.contains("```"))
        #expect(md.contains("let x = 1"))
    }

    @Test("ParseHtml markdown detects language class")
    func testMarkdownDetectsLanguageClass() async throws {
        let action = ParseHtmlAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("html", value: "<body><pre><code class=\"language-swift\">let x = 1</code></pre></body>")

        let (result, object) = createDescriptors()
        let value = try await action.execute(result: result, object: object, context: context)

        let dict = value as? [String: any Sendable]
        let md = dict?["markdown"] as? String ?? ""
        #expect(md.contains("```swift"))
    }

    // MARK: - Horizontal Rule Tests

    @Test("ParseHtml markdown converts horizontal rules")
    func testMarkdownConvertHr() async throws {
        let action = ParseHtmlAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("html", value: "<body><p>Above</p><hr><p>Below</p></body>")

        let (result, object) = createDescriptors()
        let value = try await action.execute(result: result, object: object, context: context)

        let dict = value as? [String: any Sendable]
        let md = dict?["markdown"] as? String ?? ""
        #expect(md.contains("---"))
    }

    // MARK: - Image Tests

    @Test("ParseHtml markdown converts images")
    func testMarkdownConvertImages() async throws {
        let action = ParseHtmlAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("html", value: "<body><img src=\"image.png\" alt=\"My Image\"></body>")

        let (result, object) = createDescriptors()
        let value = try await action.execute(result: result, object: object, context: context)

        let dict = value as? [String: any Sendable]
        let md = dict?["markdown"] as? String ?? ""
        #expect(md.contains("![My Image](image.png)"))
    }

    // MARK: - Content Priority Tests

    @Test("ParseHtml markdown prefers main element")
    func testMarkdownPrefersMainElement() async throws {
        let action = ParseHtmlAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("html", value: """
            <body>
            <nav><p>Navigation</p></nav>
            <main><p>Main content</p></main>
            </body>
            """)

        let (result, object) = createDescriptors()
        let value = try await action.execute(result: result, object: object, context: context)

        let dict = value as? [String: any Sendable]
        let md = dict?["markdown"] as? String ?? ""
        #expect(md.contains("Main content"))
    }

    @Test("ParseHtml markdown prefers article element")
    func testMarkdownPrefersArticleElement() async throws {
        let action = ParseHtmlAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("html", value: """
            <body>
            <aside><p>Sidebar</p></aside>
            <article><p>Article content</p></article>
            </body>
            """)

        let (result, object) = createDescriptors()
        let value = try await action.execute(result: result, object: object, context: context)

        let dict = value as? [String: any Sendable]
        let md = dict?["markdown"] as? String ?? ""
        #expect(md.contains("Article content"))
    }

    // MARK: - Ignored Elements Tests

    @Test("ParseHtml markdown ignores script tags")
    func testMarkdownIgnoresScript() async throws {
        let action = ParseHtmlAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("html", value: "<body><p>Content</p><script>alert('test')</script></body>")

        let (result, object) = createDescriptors()
        let value = try await action.execute(result: result, object: object, context: context)

        let dict = value as? [String: any Sendable]
        let md = dict?["markdown"] as? String ?? ""
        #expect(!md.contains("alert"))
    }

    @Test("ParseHtml markdown ignores style tags")
    func testMarkdownIgnoresStyle() async throws {
        let action = ParseHtmlAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("html", value: "<body><p>Content</p><style>body{color:red}</style></body>")

        let (result, object) = createDescriptors()
        let value = try await action.execute(result: result, object: object, context: context)

        let dict = value as? [String: any Sendable]
        let md = dict?["markdown"] as? String ?? ""
        #expect(!md.contains("color:red"))
    }

    // MARK: - Paragraph Tests

    @Test("ParseHtml markdown preserves paragraph breaks")
    func testMarkdownPreservesParagraphs() async throws {
        let action = ParseHtmlAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("html", value: "<body><p>First paragraph</p><p>Second paragraph</p></body>")

        let (result, object) = createDescriptors()
        let value = try await action.execute(result: result, object: object, context: context)

        let dict = value as? [String: any Sendable]
        let md = dict?["markdown"] as? String ?? ""
        // Two paragraphs should have double newline between them
        #expect(md.contains("First paragraph"))
        #expect(md.contains("Second paragraph"))
    }

    // MARK: - Error Handling

    @Test("ParseHtml markdown handles malformed HTML")
    func testMarkdownHandlesMalformedHtml() async throws {
        let action = ParseHtmlAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("html", value: "<body><p>Unclosed paragraph<p>Another")

        let (result, object) = createDescriptors()
        let value = try await action.execute(result: result, object: object, context: context)

        let dict = value as? [String: any Sendable]
        #expect(dict?["markdown"] != nil)
    }

    @Test("ParseHtml markdown handles empty body")
    func testMarkdownHandlesEmptyBody() async throws {
        let action = ParseHtmlAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("html", value: "<html><body></body></html>")

        let (result, object) = createDescriptors()
        let value = try await action.execute(result: result, object: object, context: context)

        let dict = value as? [String: any Sendable]
        let md = dict?["markdown"] as? String ?? ""
        #expect(md.isEmpty || md.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}
