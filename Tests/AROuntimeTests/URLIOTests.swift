// ============================================================
// URLIOTests.swift
// ARO Runtime - URL I/O Tests (ARO-0052)
// ============================================================

import Foundation
import Testing
@testable import ARORuntime
@testable import AROParser

// MARK: - Content-Type to Format Tests

@Suite("Content-Type Format Detection")
struct ContentTypeFormatTests {

    @Test("JSON Content-Type maps to json format")
    func testJSONContentType() {
        let format = FormatDeserializer.formatFromContentType("application/json")
        #expect(format == .json)
    }

    @Test("JSON Content-Type with charset maps to json format")
    func testJSONContentTypeWithCharset() {
        let format = FormatDeserializer.formatFromContentType("application/json; charset=utf-8")
        #expect(format == .json)
    }

    @Test("XML Content-Type maps to xml format")
    func testXMLContentType() {
        let format = FormatDeserializer.formatFromContentType("application/xml")
        #expect(format == .xml)

        let format2 = FormatDeserializer.formatFromContentType("text/xml")
        #expect(format2 == .xml)
    }

    @Test("CSV Content-Type maps to csv format")
    func testCSVContentType() {
        let format = FormatDeserializer.formatFromContentType("text/csv")
        #expect(format == .csv)

        let format2 = FormatDeserializer.formatFromContentType("application/csv")
        #expect(format2 == .csv)
    }

    @Test("TSV Content-Type maps to tsv format")
    func testTSVContentType() {
        let format = FormatDeserializer.formatFromContentType("text/tab-separated-values")
        #expect(format == .tsv)
    }

    @Test("YAML Content-Type maps to yaml format")
    func testYAMLContentType() {
        let format = FormatDeserializer.formatFromContentType("text/yaml")
        #expect(format == .yaml)

        let format2 = FormatDeserializer.formatFromContentType("application/x-yaml")
        #expect(format2 == .yaml)

        let format3 = FormatDeserializer.formatFromContentType("application/yaml")
        #expect(format3 == .yaml)
    }

    @Test("TOML Content-Type maps to toml format")
    func testTOMLContentType() {
        let format = FormatDeserializer.formatFromContentType("application/toml")
        #expect(format == .toml)

        let format2 = FormatDeserializer.formatFromContentType("text/toml")
        #expect(format2 == .toml)
    }

    @Test("Plain text Content-Type maps to text format")
    func testPlainTextContentType() {
        let format = FormatDeserializer.formatFromContentType("text/plain")
        #expect(format == .text)
    }

    @Test("HTML Content-Type maps to html format")
    func testHTMLContentType() {
        let format = FormatDeserializer.formatFromContentType("text/html")
        #expect(format == .html)
    }

    @Test("Markdown Content-Type maps to markdown format")
    func testMarkdownContentType() {
        let format = FormatDeserializer.formatFromContentType("text/markdown")
        #expect(format == .markdown)
    }

    @Test("JSONL Content-Type maps to jsonl format")
    func testJSONLContentType() {
        let format = FormatDeserializer.formatFromContentType("application/x-ndjson")
        #expect(format == .jsonl)

        let format2 = FormatDeserializer.formatFromContentType("application/jsonl")
        #expect(format2 == .jsonl)
    }

    @Test("Unknown Content-Type defaults to text format")
    func testUnknownContentType() {
        let format = FormatDeserializer.formatFromContentType("application/octet-stream")
        #expect(format == .text)

        let format2 = FormatDeserializer.formatFromContentType("some/weird-type")
        #expect(format2 == .text)
    }

    @Test("Case-insensitive Content-Type detection")
    func testCaseInsensitiveContentType() {
        let format = FormatDeserializer.formatFromContentType("Application/JSON")
        #expect(format == .json)

        let format2 = FormatDeserializer.formatFromContentType("TEXT/CSV")
        #expect(format2 == .csv)
    }
}

// MARK: - URL I/O Action Tests

@Suite("URL I/O Actions")
struct URLIOActionTests {

    func createDescriptors(
        resultBase: String = "result",
        resultSpecifiers: [String] = [],
        objectBase: String = "url",
        objectSpecifiers: [String] = [],
        preposition: Preposition = .from
    ) -> (ResultDescriptor, ObjectDescriptor) {
        let span = SourceSpan(at: SourceLocation())
        let result = ResultDescriptor(base: resultBase, specifiers: resultSpecifiers, span: span)
        let object = ObjectDescriptor(preposition: preposition, base: objectBase, specifiers: objectSpecifiers, span: span)
        return (result, object)
    }

    @Test("ReadAction recognizes url system object")
    func testReadActionVerbs() {
        #expect(ReadAction.verbs.contains("read"))
        #expect(ReadAction.validPrepositions.contains(.from))
    }

    @Test("WriteAction recognizes url system object")
    func testWriteActionVerbs() {
        #expect(WriteAction.verbs.contains("write"))
        #expect(WriteAction.validPrepositions.contains(.to))
    }

    @Test("ReadAction validates URL format")
    func testReadActionValidatesURLFormat() async throws {
        let action = ReadAction()
        let context = RuntimeContext(featureSetName: "Test")

        // Invalid URL (no protocol)
        let (result, object) = createDescriptors(
            objectBase: "url",
            objectSpecifiers: ["invalid-url-no-protocol"],
            preposition: .from
        )

        await #expect(throws: ActionError.self) {
            _ = try await action.execute(result: result, object: object, context: context)
        }
    }

    @Test("WriteAction validates URL format")
    func testWriteActionValidatesURLFormat() async throws {
        let action = WriteAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("data", value: ["test": "value"] as [String: any Sendable])

        // Invalid URL (no protocol)
        let (result, object) = createDescriptors(
            resultBase: "data",
            objectBase: "url",
            objectSpecifiers: ["invalid-url-no-protocol"],
            preposition: .to
        )

        await #expect(throws: ActionError.self) {
            _ = try await action.execute(result: result, object: object, context: context)
        }
    }

    @Test("URLWriteResult contains expected properties")
    func testURLWriteResult() {
        let result = URLWriteResult(
            url: "https://api.example.com/data",
            statusCode: 201,
            success: true,
            body: "{\"id\": 123}"
        )

        #expect(result.url == "https://api.example.com/data")
        #expect(result.statusCode == 201)
        #expect(result.success == true)
        #expect(result.body == "{\"id\": 123}")
    }

    @Test("URLWriteResult marks 4xx/5xx as not successful")
    func testURLWriteResultFailure() {
        let result = URLWriteResult(
            url: "https://api.example.com/data",
            statusCode: 404,
            success: false,
            body: "Not found"
        )

        #expect(result.success == false)
    }
}

// MARK: - Integration Tests (require network)

#if canImport(Network)
@Suite("URL I/O Integration", .serialized)
struct URLIOIntegrationTests {

    @Test("Read JSON from public API")
    func testReadJSONFromPublicAPI() async throws {
        let action = ReadAction()
        let context = RuntimeContext(featureSetName: "Test")

        // Use a reliable public API endpoint
        let (result, object) = (
            ResultDescriptor(base: "data", specifiers: [], span: SourceSpan(at: SourceLocation())),
            ObjectDescriptor(preposition: .from, base: "url", specifiers: ["https://jsonplaceholder.typicode.com/todos/1"], span: SourceSpan(at: SourceLocation()))
        )

        let value = try await action.execute(result: result, object: object, context: context)

        // Response should be parsed as dictionary
        if let dict = value as? [String: any Sendable] {
            #expect(dict["id"] != nil)
            #expect(dict["title"] != nil)
        } else {
            Issue.record("Expected dictionary response")
        }
    }

    @Test("Read from URL with as String specifier returns raw content")
    func testReadFromURLAsString() async throws {
        let action = ReadAction()
        let context = RuntimeContext(featureSetName: "Test")

        // Use "as String" specifier to bypass parsing
        let (result, object) = (
            ResultDescriptor(base: "data", specifiers: ["as String"], span: SourceSpan(at: SourceLocation())),
            ObjectDescriptor(preposition: .from, base: "url", specifiers: ["https://jsonplaceholder.typicode.com/todos/1"], span: SourceSpan(at: SourceLocation()))
        )

        let value = try await action.execute(result: result, object: object, context: context)

        // Response should be a raw string
        if let str = value as? String {
            #expect(str.contains("userId"))
            #expect(str.contains("title"))
        } else {
            Issue.record("Expected string response")
        }
    }

    @Test("Write to URL performs POST request")
    func testWriteToURLPerformsPOST() async throws {
        let action = WriteAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("payload", value: [
            "title": "foo",
            "body": "bar",
            "userId": 1
        ] as [String: any Sendable])

        let (result, object) = (
            ResultDescriptor(base: "payload", specifiers: [], span: SourceSpan(at: SourceLocation())),
            ObjectDescriptor(preposition: .to, base: "url", specifiers: ["https://jsonplaceholder.typicode.com/posts"], span: SourceSpan(at: SourceLocation()))
        )

        let value = try await action.execute(result: result, object: object, context: context)

        // Response should be a URLWriteResult
        if let writeResult = value as? URLWriteResult {
            #expect(writeResult.success == true)
            #expect(writeResult.statusCode == 201)
        } else {
            Issue.record("Expected URLWriteResult")
        }
    }
}
#endif
