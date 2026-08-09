// ============================================================
// TemplateErrorReportingTests.swift
// ARO Runtime - Template error messages (GitLab #484)
// ============================================================

import Foundation
import Testing
@testable import ARORuntime

// MARK: - Positions

@Suite("Template Segment Lines")
struct TemplateSegmentLineTests {

    @Test("Every segment gets a source line")
    func testLinesParallelSegments() throws {
        let parsed = try TemplateParser().parse("""
        <html>
        <body>
        <h1>{{ Print <name> to the <template>. }}</h1>
        </body>
        </html>
        """, path: "page.html")

        #expect(parsed.segmentLines.count == parsed.segments.count)
    }

    @Test("A block's line matches where it appears in the source")
    func testBlockLine() throws {
        let parsed = try TemplateParser().parse("""
        <html>
        <body>
        <h1>{{ Print <name> to the <template>. }}</h1>
        </body>
        </html>
        """, path: "page.html")

        // The block sits on line 3.
        let blockIndex = try #require(
            parsed.segments.firstIndex {
                if case .statements = $0 { return true }
                return false
            }
        )
        #expect(parsed.line(ofSegment: blockIndex) == 3)
    }

    @Test("Multiple blocks get their own lines")
    func testMultipleBlockLines() throws {
        let parsed = try TemplateParser().parse("""
        {{ Print <a> to the <template>. }}
        middle
        {{ Print <b> to the <template>. }}
        """, path: "page.html")

        let blockLines = parsed.segments.indices.compactMap { index -> Int? in
            if case .statements = parsed.segments[index] { return parsed.line(ofSegment: index) }
            return nil
        }
        #expect(blockLines == [1, 3])
    }

    @Test("A template built without positions reports nil")
    func testMissingPositionsAreNil() {
        let parsed = ParsedTemplate(path: "x.html", segments: [.staticText("hi")])

        #expect(parsed.line(ofSegment: 0) == nil)
    }

    @Test("Out-of-range indices report nil rather than trapping")
    func testOutOfRangeIsNil() throws {
        let parsed = try TemplateParser().parse("plain", path: "x.html")

        #expect(parsed.line(ofSegment: 99) == nil)
        #expect(parsed.line(ofSegment: -1) == nil)
    }
}

// MARK: - Hints

@Suite("Template Block Hints")
struct TemplateBlockHintTests {

    @Test("A bare identifier gets the Mustache hint")
    func testMustacheHint() throws {
        let hint = try #require(TemplateBlockHint.hint(forBlock: "name"))

        #expect(hint.contains("not Mustache variables"))
        #expect(hint.contains("Print <name> to the <template>."))
    }

    @Test("A dotted path suggests the base variable")
    func testDottedMustacheHint() throws {
        let hint = try #require(TemplateBlockHint.hint(forBlock: "user.name"))

        #expect(hint.contains("Print <user>"))
    }

    @Test("A statement missing its period is hinted")
    func testMissingPeriodHint() throws {
        let hint = try #require(
            TemplateBlockHint.hint(forBlock: "Print <name> to the <template>")
        )

        #expect(hint.contains("end with a period"))
    }

    @Test("A well-formed statement gets no hint")
    func testNoHintForValidStatement() {
        #expect(TemplateBlockHint.hint(forBlock: "Print <name> to the <template>.") == nil)
    }

    @Test("An empty block gets no hint")
    func testNoHintForEmpty() {
        #expect(TemplateBlockHint.hint(forBlock: "") == nil)
        #expect(TemplateBlockHint.hint(forBlock: "   \n  ") == nil)
    }

    @Test("A for-each opener gets no hint")
    func testNoHintForLoopSyntax() {
        // Ends with `{`, so the missing-period rule must not fire.
        #expect(TemplateBlockHint.hint(forBlock: "for each <u> in <users> {") == nil)
    }
}

// MARK: - Messages

@Suite("Template Error Messages")
struct TemplateErrorMessageTests {

    @Test("A positioned render error names the file, line, block and hint")
    func testPositionedMessage() throws {
        let error = TemplateError.renderErrorAt(
            path: "page.html",
            line: 3,
            source: "name",
            message: "Expected action verb, but got identifier(name)",
            hint: "use Print"
        )
        let description = try #require(error.errorDescription)

        #expect(description.contains("page.html:3"))
        #expect(description.contains("3 | {{ name }}"))
        #expect(description.contains("hint: use Print"))
        // Must not leak the Swift case name.
        #expect(!description.contains("renderErrorAt("))
    }

    @Test("A multi-line block shows only its first line")
    func testMultiLineBlockTruncated() throws {
        let error = TemplateError.renderErrorAt(
            path: "p.html", line: 2,
            source: "Extract the <a> from the <b>.\nCompute the <c> from <a>.",
            message: "boom", hint: nil
        )
        let description = try #require(error.errorDescription)

        #expect(description.contains("Extract the <a>"))
        #expect(!description.contains("Compute the <c>"))
    }

    @Test("Existing cases still describe themselves")
    func testOtherCasesUnchanged() throws {
        #expect(
            TemplateError.notFound(path: "x.html").errorDescription
                == "Template not found: ./templates/x.html"
        )
        #expect(
            TemplateError.renderError(path: "x.html", message: "m").errorDescription
                == "Template render error in x.html: m"
        )
    }

    @Test("templatePath is available for every case")
    func testTemplatePathAccessor() {
        #expect(TemplateError.notFound(path: "a").templatePath == "a")
        #expect(TemplateError.parseError(path: "b", message: "m").templatePath == "b")
        #expect(TemplateError.renderError(path: "c", message: "m").templatePath == "c")
        #expect(TemplateError.invalidPath(path: "d").templatePath == "d")
        #expect(
            TemplateError.renderErrorAt(path: "e", line: 1, source: "s", message: "m", hint: nil)
                .templatePath == "e"
        )
    }
}
