// ============================================================
// TemplateEngineTests.swift
// Tests for ARO Template Engine (ARO-0050)
// ============================================================

import Testing
import Foundation
@testable import ARORuntime
@testable import AROParser

// MARK: - Template Segment Tests

@Suite("Template Segment Tests")
struct TemplateSegmentTests {

    @Test("Static text segment equality")
    func testStaticTextEquality() {
        let segment1 = TemplateSegment.staticText("Hello")
        let segment2 = TemplateSegment.staticText("Hello")
        let segment3 = TemplateSegment.staticText("World")

        #expect(segment1 == segment2)
        #expect(segment1 != segment3)
    }

    @Test("Expression shorthand segment equality")
    func testExpressionShorthandEquality() {
        let segment1 = TemplateSegment.expressionShorthand("user")
        let segment2 = TemplateSegment.expressionShorthand("user")
        let segment3 = TemplateSegment.expressionShorthand("name")

        #expect(segment1 == segment2)
        #expect(segment1 != segment3)
    }

    @Test("For-each config equality")
    func testForEachConfigEquality() {
        let config1 = ForEachConfig(itemVariable: "user", indexVariable: nil, collection: "users")
        let config2 = ForEachConfig(itemVariable: "user", indexVariable: nil, collection: "users")
        let config3 = ForEachConfig(itemVariable: "item", indexVariable: "idx", collection: "items")

        #expect(config1 == config2)
        #expect(config1 != config3)
    }

    @Test("For-each config with index variable")
    func testForEachConfigWithIndex() {
        let config = ForEachConfig(itemVariable: "user", indexVariable: "i", collection: "users")

        #expect(config.itemVariable == "user")
        #expect(config.indexVariable == "i")
        #expect(config.collection == "users")
    }
}

// MARK: - Template Parser Tests

@Suite("Template Parser Tests")
struct TemplateParserTests {
    private let parser = TemplateParser()

    @Test("Parse static text only")
    func testParseStaticText() throws {
        let content = "Hello, World!"
        let parsed = try parser.parse(content)

        #expect(parsed.segments.count == 1)
        if case .staticText(let text) = parsed.segments[0] {
            #expect(text == "Hello, World!")
        } else {
            Issue.record("Expected static text segment")
        }
    }

    @Test("Parse expression shorthand")
    func testParseExpressionShorthand() throws {
        let content = "Hello, {{ <user: name> }}!"
        let parsed = try parser.parse(content)

        #expect(parsed.segments.count == 3)
        if case .staticText(let text) = parsed.segments[0] {
            #expect(text == "Hello, ")
        }
        if case .expressionShorthand(let expr) = parsed.segments[1] {
            #expect(expr.contains("user"))
        }
        if case .staticText(let text) = parsed.segments[2] {
            #expect(text == "!")
        }
    }

    @Test("Parse simple variable reference")
    func testParseSimpleVariable() throws {
        let content = "Value: {{ <value> }}"
        let parsed = try parser.parse(content)

        #expect(parsed.segments.count == 2)
        if case .expressionShorthand(let expr) = parsed.segments[1] {
            #expect(expr.contains("value"))
        }
    }

    @Test("Parse for-each loop")
    func testParseForEach() throws {
        let content = """
        {{ for each <item> in <items> { }}
        - {{ <item> }}
        {{ } }}
        """
        let parsed = try parser.parse(content)

        var hasForEachOpen = false
        var hasForEachClose = false

        for segment in parsed.segments {
            if case .forEachOpen = segment {
                hasForEachOpen = true
            }
            if case .forEachClose = segment {
                hasForEachClose = true
            }
        }

        #expect(hasForEachOpen)
        #expect(hasForEachClose)
    }

    @Test("Parse for-each with index")
    func testParseForEachWithIndex() throws {
        let content = """
        {{ for each <user> at <idx> in <users> { }}
        {{ <idx> }}: {{ <user> }}
        {{ } }}
        """
        let parsed = try parser.parse(content)

        var foundConfig: ForEachConfig?
        for segment in parsed.segments {
            if case .forEachOpen(let config) = segment {
                foundConfig = config
                break
            }
        }

        #expect(foundConfig != nil)
        #expect(foundConfig?.itemVariable == "user")
        #expect(foundConfig?.indexVariable == "idx")
        #expect(foundConfig?.collection == "users")
    }

    @Test("Parse multiple segments")
    func testParseMultipleSegments() throws {
        let content = "Hello {{ <name> }}, welcome to {{ <place> }}!"
        let parsed = try parser.parse(content)

        #expect(parsed.segments.count == 5)
    }

    @Test("Parse empty template")
    func testParseEmptyTemplate() throws {
        let parsed = try parser.parse("")

        #expect(parsed.segments.isEmpty)
    }

    @Test("Parse template with only expressions")
    func testParseOnlyExpressions() throws {
        let content = "{{ <a> }}{{ <b> }}{{ <c> }}"
        let parsed = try parser.parse(content)

        #expect(parsed.segments.count == 3)
        for segment in parsed.segments {
            if case .expressionShorthand = segment {
                continue
            } else {
                Issue.record("Expected all expression shorthand segments")
            }
        }
    }
}

// MARK: - Template Parse Error Tests

@Suite("Template Parse Error Tests")
struct TemplateParseErrorTests {
    private let parser = TemplateParser()

    @Test("Unclosed block error message")
    func testUnclosedBlockErrorMessage() {
        let error = TemplateParseError.unclosedBlock(line: 5)
        #expect(error.errorDescription?.contains("line 5") == true)
        #expect(error.errorDescription?.contains("Unclosed") == true)
    }

    @Test("Invalid for-each syntax error message")
    func testInvalidForEachSyntaxErrorMessage() {
        let error = TemplateParseError.invalidForEachSyntax(line: 10, detail: "missing 'in' keyword")
        #expect(error.errorDescription?.contains("line 10") == true)
        #expect(error.errorDescription?.contains("missing 'in' keyword") == true)
    }

    @Test("Unmatched for-each close error message")
    func testUnmatchedForEachCloseErrorMessage() {
        let error = TemplateParseError.unmatchedForEachClose(line: 15)
        #expect(error.errorDescription?.contains("line 15") == true)
        #expect(error.errorDescription?.contains("no matching") == true)
    }
}

// MARK: - Template Error Tests

@Suite("Template Error Tests")
struct TemplateErrorTests {

    @Test("Not found error message")
    func testNotFoundErrorMessage() {
        let error = TemplateError.notFound(path: "user-list.html")
        #expect(error.errorDescription?.contains("user-list.html") == true)
        #expect(error.errorDescription?.contains("not found") == true)
    }

    @Test("Parse error message")
    func testParseErrorMessage() {
        let error = TemplateError.parseError(path: "broken.tpl", message: "unexpected token")
        #expect(error.errorDescription?.contains("broken.tpl") == true)
        #expect(error.errorDescription?.contains("unexpected token") == true)
    }

    @Test("Render error message")
    func testRenderErrorMessage() {
        let error = TemplateError.renderError(path: "template.html", message: "undefined variable")
        #expect(error.errorDescription?.contains("template.html") == true)
        #expect(error.errorDescription?.contains("undefined variable") == true)
    }

    @Test("Invalid path error message")
    func testInvalidPathErrorMessage() {
        let error = TemplateError.invalidPath(path: "../escape.html")
        #expect(error.errorDescription?.contains("../escape.html") == true)
        #expect(error.errorDescription?.contains("Invalid") == true)
    }
}

// MARK: - Parsed Template Tests

@Suite("Parsed Template Tests")
struct ParsedTemplateTests {

    @Test("Parsed template stores path")
    func testParsedTemplateStorePath() {
        let segments: [TemplateSegment] = [.staticText("Hello")]
        let template = ParsedTemplate(path: "greeting.html", segments: segments)

        #expect(template.path == "greeting.html")
    }

    @Test("Parsed template stores segments")
    func testParsedTemplateStoreSegments() {
        let segments: [TemplateSegment] = [
            .staticText("Hello, "),
            .expressionShorthand("name"),
            .staticText("!")
        ]
        let template = ParsedTemplate(path: "greeting.html", segments: segments)

        #expect(template.segments.count == 3)
    }
}

// MARK: - Template Service Tests

@Suite("Template Service Tests")
struct TemplateServiceTests {

    @Test("Service initializes with directory")
    func testServiceInitialization() {
        let service = AROTemplateService(templatesDirectory: "/tmp/templates")
        // Service is non-optional, verify it has the expected configuration
        #expect(type(of: service) == AROTemplateService.self)
    }

    @Test("Non-existent template returns not found")
    func testNonExistentTemplate() async {
        let service = AROTemplateService(templatesDirectory: "/tmp/nonexistent-templates-dir")
        let exists = await service.exists(path: "nonexistent.html")
        #expect(exists == false)
    }

    @Test("Invalid path with directory traversal rejected")
    func testInvalidPathRejected() async {
        let service = AROTemplateService(templatesDirectory: "/tmp/templates")
        let exists = await service.exists(path: "../../../etc/passwd")
        #expect(exists == false)
    }

    @Test("Load throws for directory traversal")
    func testLoadRejectsDirectoryTraversal() async throws {
        let service = AROTemplateService(templatesDirectory: "/tmp/templates")
        do {
            _ = try await service.load(path: "../etc/passwd")
            Issue.record("Expected error for directory traversal")
        } catch {
            // Expected error
            #expect(error is TemplateError)
        }
    }
}

// MARK: - Include Action Tests

@Suite("Include Action Tests")
struct IncludeActionTests {

    @Test("Include action role is own")
    func testIncludeActionRole() {
        #expect(IncludeAction.role == .own)
    }

    @Test("Include action verbs")
    func testIncludeActionVerbs() {
        #expect(IncludeAction.verbs.contains("include"))
    }

    @Test("Include action valid prepositions")
    func testIncludeActionPrepositions() {
        #expect(IncludeAction.validPrepositions.contains(.from))
    }
}
