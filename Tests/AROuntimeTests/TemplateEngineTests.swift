// ============================================================
// TemplateEngineTests.swift
// ARO Runtime - Template Engine Unit Tests (ARO-0050, Issue #82)
// ============================================================

import Foundation
import Testing
@testable import ARORuntime
@testable import AROParser

// MARK: - Template Parser Tests

@Suite("Template Parser Tests")
struct TemplateParserTests {
    let parser = TemplateParser()

    @Test("Parse static text only")
    func testParseStaticTextOnly() throws {
        let content = "Hello, World!"
        let result = try parser.parse(content)

        #expect(result.segments.count == 1)
        if case .staticText(let text) = result.segments[0] {
            #expect(text == "Hello, World!")
        } else {
            Issue.record("Expected static text segment")
        }
    }

    @Test("Parse simple variable expression")
    func testParseSimpleVariable() throws {
        let content = "Hello, {{ <name> }}!"
        let result = try parser.parse(content)

        #expect(result.segments.count == 3)

        if case .staticText(let text) = result.segments[0] {
            #expect(text == "Hello, ")
        } else {
            Issue.record("Expected static text as first segment")
        }

        if case .expressionShorthand(let expr) = result.segments[1] {
            #expect(expr == "<name>")
        } else {
            Issue.record("Expected expression shorthand segment")
        }

        if case .staticText(let text) = result.segments[2] {
            #expect(text == "!")
        } else {
            Issue.record("Expected static text as last segment")
        }
    }

    @Test("Parse variable with qualifier")
    func testParseVariableWithQualifier() throws {
        let content = "{{ <user: email> }}"
        let result = try parser.parse(content)

        #expect(result.segments.count == 1)
        if case .expressionShorthand(let expr) = result.segments[0] {
            #expect(expr == "<user: email>")
        } else {
            Issue.record("Expected expression shorthand segment")
        }
    }

    @Test("Parse ARO statements with action")
    func testParseAROStatements() throws {
        let content = "{{ <Log> \"Hello\" to the <console>. }}"
        let result = try parser.parse(content)

        #expect(result.segments.count == 1)
        if case .statements(let stmts) = result.segments[0] {
            #expect(stmts.contains("<Log>"))
            #expect(stmts.contains("<console>"))
        } else {
            Issue.record("Expected statements segment")
        }
    }

    @Test("Parse for-each loop")
    func testParseForEachLoop() throws {
        let content = """
        {{ for each <user> in <users> {
        }}
        Name: {{ <user: name> }}
        {{ } }}
        """
        let result = try parser.parse(content)

        // Should have: forEachOpen, staticText (with Name:), expression, staticText, forEachClose
        var foundForEachOpen = false
        var foundForEachClose = false

        for segment in result.segments {
            if case .forEachOpen(let config) = segment {
                foundForEachOpen = true
                #expect(config.itemVariable == "user")
                #expect(config.collection == "users")
                #expect(config.indexVariable == nil)
            }
            if case .forEachClose = segment {
                foundForEachClose = true
            }
        }

        #expect(foundForEachOpen, "Should have for-each open")
        #expect(foundForEachClose, "Should have for-each close")
    }

    @Test("Parse for-each with index")
    func testParseForEachWithIndex() throws {
        let content = "{{ for each <item> at <idx> in <items> { }}{{ } }}"
        let result = try parser.parse(content)

        if case .forEachOpen(let config) = result.segments[0] {
            #expect(config.itemVariable == "item")
            #expect(config.indexVariable == "idx")
            #expect(config.collection == "items")
        } else {
            Issue.record("Expected for-each open segment")
        }
    }

    @Test("Parse string concatenation expression")
    func testParseStringConcatenation() throws {
        let content = "{{ <first> ++ \" \" ++ <last> }}"
        let result = try parser.parse(content)

        #expect(result.segments.count == 1)
        if case .expressionShorthand(let expr) = result.segments[0] {
            #expect(expr.contains("++"))
        } else {
            Issue.record("Expected expression shorthand segment")
        }
    }

    @Test("Parse arithmetic expression")
    func testParseArithmeticExpression() throws {
        let content = "{{ <price> * 1.1 }}"
        let result = try parser.parse(content)

        #expect(result.segments.count == 1)
        if case .expressionShorthand(let expr) = result.segments[0] {
            #expect(expr.contains("*"))
        } else {
            Issue.record("Expected expression shorthand segment")
        }
    }

    @Test("Parse multiple blocks")
    func testParseMultipleBlocks() throws {
        let content = "Hello {{ <firstName> }} {{ <lastName> }}!"
        let result = try parser.parse(content)

        #expect(result.segments.count == 5)
        // staticText, expression, staticText (space), expression, staticText
    }

    @Test("Parse Include action")
    func testParseIncludeAction() throws {
        let content = "{{ <Include> the <template: header.tpl>. }}"
        let result = try parser.parse(content)

        #expect(result.segments.count == 1)
        if case .statements(let stmts) = result.segments[0] {
            #expect(stmts.contains("<Include>"))
            #expect(stmts.contains("header.tpl"))
        } else {
            Issue.record("Expected statements segment for Include")
        }
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

    @Test("Error: Unclosed block")
    func testUnclosedBlock() throws {
        let content = "Hello {{ <name>"

        #expect(throws: TemplateParseError.self) {
            _ = try parser.parse(content)
        }
    }

    @Test("Error: Unmatched for-each close")
    func testUnmatchedForEachClose() throws {
        let content = "{{ } }}"

        #expect(throws: TemplateParseError.self) {
            _ = try parser.parse(content)
        }
    }

    @Test("Error: Unclosed for-each block")
    func testUnclosedForEachBlock() throws {
        let content = "{{ for each <item> in <items> { }}"

        #expect(throws: TemplateParseError.self) {
            _ = try parser.parse(content)
        }
    }

    @Test("Error: Invalid for-each syntax - missing brace")
    func testInvalidForEachMissingBrace() throws {
        let content = "{{ for each <item> in <items> }}"

        #expect(throws: TemplateParseError.self) {
            _ = try parser.parse(content)
        }
    }

    @Test("Error: Invalid for-each syntax - missing 'in'")
    func testInvalidForEachMissingIn() throws {
        let content = "{{ for each <item> <items> { }}"

        #expect(throws: TemplateParseError.self) {
            _ = try parser.parse(content)
        }
    }
}

// MARK: - Template Segment Tests

@Suite("Template Segment Tests")
struct TemplateSegmentTests {

    @Test("Static text segment equality")
    func testStaticTextEquality() {
        let seg1 = TemplateSegment.staticText("Hello")
        let seg2 = TemplateSegment.staticText("Hello")
        let seg3 = TemplateSegment.staticText("World")

        #expect(seg1 == seg2)
        #expect(seg1 != seg3)
    }

    @Test("Expression shorthand segment equality")
    func testExpressionShorthandEquality() {
        let seg1 = TemplateSegment.expressionShorthand("<name>")
        let seg2 = TemplateSegment.expressionShorthand("<name>")
        let seg3 = TemplateSegment.expressionShorthand("<email>")

        #expect(seg1 == seg2)
        #expect(seg1 != seg3)
    }

    @Test("ForEachConfig equality")
    func testForEachConfigEquality() {
        let config1 = ForEachConfig(itemVariable: "item", indexVariable: "idx", collection: "items")
        let config2 = ForEachConfig(itemVariable: "item", indexVariable: "idx", collection: "items")
        let config3 = ForEachConfig(itemVariable: "user", indexVariable: nil, collection: "users")

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
        #expect(IncludeAction.verbs.contains("embed"))
        #expect(IncludeAction.verbs.contains("insert"))
    }

    @Test("Include action valid prepositions")
    func testIncludeActionPrepositions() {
        #expect(IncludeAction.validPrepositions.contains(.with))
        #expect(IncludeAction.validPrepositions.contains(.from))
    }
}

// MARK: - Template Error Tests

@Suite("Template Error Tests")
struct TemplateErrorTests {

    @Test("Template not found error description")
    func testNotFoundError() {
        let error = TemplateError.notFound(path: "missing.tpl")
        #expect(error.errorDescription?.contains("not found") == true)
        #expect(error.errorDescription?.contains("missing.tpl") == true)
    }

    @Test("Template parse error description")
    func testParseError() {
        let error = TemplateError.parseError(path: "bad.tpl", message: "Syntax error")
        #expect(error.errorDescription?.contains("parse error") == true)
        #expect(error.errorDescription?.contains("bad.tpl") == true)
    }

    @Test("Template render error description")
    func testRenderError() {
        let error = TemplateError.renderError(path: "fail.tpl", message: "Missing variable")
        #expect(error.errorDescription?.contains("render error") == true)
        #expect(error.errorDescription?.contains("fail.tpl") == true)
    }

    @Test("Invalid template path error description")
    func testInvalidPathError() {
        let error = TemplateError.invalidPath(path: "../escape.tpl")
        #expect(error.errorDescription?.contains("Invalid") == true)
    }
}

// MARK: - Template Parse Error Tests

@Suite("Template Parse Error Tests")
struct TemplateParseErrorTests {

    @Test("Unclosed block error description")
    func testUnclosedBlockError() {
        let error = TemplateParseError.unclosedBlock(line: 5)
        #expect(error.errorDescription?.contains("line 5") == true)
        #expect(error.errorDescription?.contains("Unclosed") == true)
    }

    @Test("Invalid for-each syntax error description")
    func testInvalidForEachSyntaxError() {
        let error = TemplateParseError.invalidForEachSyntax(line: 10, detail: "missing keyword")
        #expect(error.errorDescription?.contains("line 10") == true)
        #expect(error.errorDescription?.contains("for-each") == true)
    }

    @Test("Unmatched for-each close error description")
    func testUnmatchedForEachCloseError() {
        let error = TemplateParseError.unmatchedForEachClose(line: 15)
        #expect(error.errorDescription?.contains("line 15") == true)
    }

    @Test("Nested for-each not closed error description")
    func testNestedForEachNotClosedError() {
        let error = TemplateParseError.nestedForEachNotClosed(line: 20)
        #expect(error.errorDescription?.contains("line 20") == true)
        #expect(error.errorDescription?.contains("Unclosed") == true)
    }
}

// MARK: - Parsed Template Tests

@Suite("Parsed Template Tests")
struct ParsedTemplateTests {

    @Test("Parsed template initialization")
    func testParsedTemplateInit() {
        let segments: [TemplateSegment] = [
            .staticText("Hello "),
            .expressionShorthand("<name>"),
            .staticText("!")
        ]
        let template = ParsedTemplate(path: "test.tpl", segments: segments)

        #expect(template.path == "test.tpl")
        #expect(template.segments.count == 3)
    }

    @Test("Empty template")
    func testEmptyTemplate() throws {
        let parser = TemplateParser()
        let result = try parser.parse("")

        #expect(result.segments.isEmpty)
    }

    @Test("Whitespace only template")
    func testWhitespaceOnlyTemplate() throws {
        let parser = TemplateParser()
        let result = try parser.parse("   \n\t  ")

        #expect(result.segments.count == 1)
        if case .staticText(_) = result.segments[0] {
            // OK - whitespace is preserved as static text
        } else {
            Issue.record("Expected static text segment")
        }
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

// MARK: - Complex Template Tests

@Suite("Complex Template Tests")
struct ComplexTemplateTests {
    let parser = TemplateParser()

    @Test("Parse HTML template with variables")
    func testParseHTMLTemplate() throws {
        let content = """
        <html>
        <head><title>{{ <title> }}</title></head>
        <body>
        <h1>{{ <heading> }}</h1>
        <p>{{ <content> }}</p>
        </body>
        </html>
        """
        let result = try parser.parse(content)

        // Count expression segments
        let expressionCount = result.segments.filter {
            if case .expressionShorthand(_) = $0 { return true }
            return false
        }.count

        #expect(expressionCount == 3, "Should have 3 expression segments")
    }

    @Test("Parse nested for-each loops")
    func testParseNestedForEachLoops() throws {
        let content = """
        {{ for each <category> in <categories> {
        }}
        Category: {{ <category: name> }}
        {{ for each <product> in <category: products> {
        }}
        - {{ <product: name> }}
        {{ } }}
        {{ } }}
        """
        let result = try parser.parse(content)

        // Count for-each opens and closes
        let openCount = result.segments.filter {
            if case .forEachOpen(_) = $0 { return true }
            return false
        }.count

        let closeCount = result.segments.filter {
            if case .forEachClose = $0 { return true }
            return false
        }.count

        #expect(openCount == 2, "Should have 2 for-each opens")
        #expect(closeCount == 2, "Should have 2 for-each closes")
    }

    @Test("Parse email template")
    func testParseEmailTemplate() throws {
        let content = """
        Dear {{ <user: name> }},

        Your order #{{ <order: id> }} has been confirmed.

        Items:
        {{ for each <item> in <order: items> {
        }}
        - {{ <item: name> }}: ${{ <item: price> }}
        {{ } }}

        Total: ${{ <order: total> }}

        Thank you for your purchase!
        """
        let result = try parser.parse(content)

        // Should parse without errors
        #expect(result.segments.count > 0)

        // Should have for-each
        let hasForEach = result.segments.contains {
            if case .forEachOpen(_) = $0 { return true }
            return false
        }
        #expect(hasForEach, "Should contain for-each loop")
    }

    @Test("Parse template with match expression")
    func testParseMatchExpression() throws {
        let content = """
        {{ match <status> {
            when "active" { <Log> "Active" to the <console>. }
            when "inactive" { <Log> "Inactive" to the <console>. }
        } }}
        """
        let result = try parser.parse(content)

        #expect(result.segments.count == 1)
        if case .statements(let stmts) = result.segments[0] {
            #expect(stmts.contains("match"))
            #expect(stmts.contains("active"))
        } else {
            Issue.record("Expected statements segment for match")
        }
    }
}
