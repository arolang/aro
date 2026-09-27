// ============================================================
// HTMLAttributeSelectTests.swift
// ARO Runtime — reading attributes out of parsed HTML
// ARO-0011 §1.5, GitLab #860
// ============================================================
//
// `Parse … html` returned element *text*, and nothing could read an attribute.
// So the ordinary tasks — collect every `img[src]`, every `a[href]`, the
// `content` of a meta tag — could not be written at all.

import Foundation
import Testing
@testable import ARORuntime
@testable import AROParser

@Suite("HTML attribute selection (#860)")
struct HTMLAttributeSelectTests {

    private static let page = """
    <html>
      <head>
        <title>Example</title>
        <meta name="description" content="A page about things">
      </head>
      <body>
        <a href="/one" class="nav">One</a>
        <a>Not a link</a>
        <a href="/two" class="nav">Two</a>
        <img src="/a.png" alt="A">
        <img alt="B">
        <input value="">
      </body>
    </html>
    """

    private func select(_ selector: String, in html: String = page) async throws -> [String] {
        let span = SourceSpan(at: SourceLocation())
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("page", value: html)
        context.bind("_expression_", value: selector)
        let value = try await ParseHtmlAction().execute(
            result: ResultDescriptor(base: "out", specifiers: ["select"], span: span),
            object: ObjectDescriptor(preposition: .from, base: "page", specifiers: [], span: span),
            context: context)
        return try #require(value as? [String])
    }

    // MARK: - Attributes

    @Test("`a@href` yields the hrefs")
    func hrefs() async throws {
        #expect(try await select("a@href") == ["/one", "/two"])
    }

    @Test("an element without the attribute contributes nothing")
    func missingAttributeIsSkipped() async throws {
        // The decision the issue asked for: the result is the attributes that
        // exist, not a list with holes at the indexes where they do not. A
        // list with holes is only useful for correlating by index, and CSS can
        // already say what you meant — see the next test.
        let all = try await select("a")
        let hrefs = try await select("a@href")
        #expect(all.count == 3)
        #expect(hrefs.count == 2)
    }

    @Test("selecting only elements that have the attribute keeps positions aligned")
    func attributePresenceSelector() async throws {
        // CSS expresses it, so ARO does not need to: `a[href]` selects exactly
        // the elements that have one, and the two lists line up by
        // construction.
        let texts = try await select("a[href]")
        let hrefs = try await select("a[href]@href")
        #expect(texts == ["One", "Two"])
        #expect(hrefs == ["/one", "/two"])
        #expect(texts.count == hrefs.count)
    }

    @Test("an attribute that is present but empty is reported, not dropped")
    func emptyAttributeIsPresent() async throws {
        // `value=""` is a value somebody wrote. Dropping it would conflate
        // "no value" with "an empty value", and only the first is a missing
        // attribute.
        #expect(try await select("input@value") == [""])
    }

    @Test("image sources and meta content, the cases the issue names")
    func imagesAndMeta() async throws {
        #expect(try await select("img@src") == ["/a.png"])
        #expect(try await select("meta[name=description]@content") == ["A page about things"])
    }

    @Test("a class attribute comes back once per element")
    func repeatedAttribute() async throws {
        #expect(try await select("a.nav@class") == ["nav", "nav"])
    }

    // MARK: - No attribute: text

    @Test("a selector with no `@` yields element text")
    func textWithoutAttribute() async throws {
        // One qualifier covers "the link texts" and "the link targets", so
        // nobody has to remember two.
        #expect(try await select("a") == ["One", "Not a link", "Two"])
        #expect(try await select("title") == ["Example"])
    }

    @Test("a selector matching nothing yields an empty list")
    func noMatches() async throws {
        #expect(try await select("video@src").isEmpty)
        #expect(try await select("video").isEmpty)
    }

    // MARK: - Splitting the selector

    @Test("the split is on the LAST @, because a selector may contain one")
    func splitOnLastAt() {
        // `[data-x="a@b"]` is a valid CSS selector; splitting on the first `@`
        // would cut it in half.
        #expect(ParseHtmlAction.splitSelector("a@href").query == "a")
        #expect(ParseHtmlAction.splitSelector("a@href").attribute == "href")

        let tricky = ParseHtmlAction.splitSelector("[data-x=\"a@b\"]@href")
        #expect(tricky.query == "[data-x=\"a@b\"]")
        #expect(tricky.attribute == "href")
    }

    @Test("a selector with no @ has no attribute")
    func splitWithoutAt() {
        #expect(ParseHtmlAction.splitSelector("div.content").attribute == nil)
    }

    @Test("a trailing @ is not an attribute request")
    func splitTrailingAt() {
        // Nor is a leading one. Either way the whole string stays the
        // selector, and SwiftSoup reports it if it is nonsense — better than
        // silently selecting something else.
        #expect(ParseHtmlAction.splitSelector("a@").attribute == nil)
        #expect(ParseHtmlAction.splitSelector("@href").attribute == nil)
    }

    @Test("an attribute name is letters, digits and the separators HTML allows")
    func splitRejectsNonAttributeNames() {
        #expect(ParseHtmlAction.splitSelector("a@data-id").attribute == "data-id")
        #expect(ParseHtmlAction.splitSelector("svg@xlink:href").attribute == "xlink:href")
        // A `@` inside what is plainly still a selector is left alone.
        #expect(ParseHtmlAction.splitSelector("a@[href]").attribute == nil)
    }

    // MARK: - The statement

    @Test("`select` with no selector is an error naming what is missing")
    func missingSelector() async {
        let span = SourceSpan(at: SourceLocation())
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("page", value: Self.page)
        await #expect(throws: (any Error).self) {
            _ = try await ParseHtmlAction().execute(
                result: ResultDescriptor(base: "out", specifiers: ["select"], span: span),
                object: ObjectDescriptor(preposition: .from, base: "page",
                                         specifiers: [], span: span),
                context: context)
        }
    }

    @Test("`Parse the <r: select>` reaches the HTML parser too")
    func parseVerbDispatches() async throws {
        // `Parse` routes its HTML qualifiers to ParseHtmlAction; `select` has
        // to be one of them or the statement falls through to Extract.
        let span = SourceSpan(at: SourceLocation())
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("page", value: Self.page)
        context.bind("_expression_", value: "a@href")
        let value = try await ParseDispatchAction().execute(
            result: ResultDescriptor(base: "out", specifiers: ["select"], span: span),
            object: ObjectDescriptor(preposition: .from, base: "page", specifiers: [], span: span),
            context: context)
        #expect(value as? [String] == ["/one", "/two"])
    }

    @Test("the existing modes still answer what they answered")
    func existingModesUnchanged() async throws {
        let span = SourceSpan(at: SourceLocation())
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("page", value: Self.page)
        let links = try await ParseHtmlAction().execute(
            result: ResultDescriptor(base: "out", specifiers: ["links"], span: span),
            object: ObjectDescriptor(preposition: .from, base: "page", specifiers: [], span: span),
            context: context)
        #expect(links as? [String] == ["/one", "/two"])
    }
}
