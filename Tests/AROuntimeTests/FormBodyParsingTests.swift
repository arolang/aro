// ============================================================
// FormBodyParsingTests.swift
// ARO Runtime - multipart/form-data and form-urlencoded tests
// ============================================================

import XCTest
@testable import ARORuntime

final class FormBodyParsingTests: XCTestCase {

    // MARK: - parseFormURLEncoded

    func testFormURLEncoded_singleField() {
        let body = "name=Alice".data(using: .utf8)!
        let result = SchemaBinding.parseFormURLEncoded(body)
        XCTAssertEqual(result["name"] as? String, "Alice")
    }

    func testFormURLEncoded_multipleFields() {
        let body = "name=Alice&age=30".data(using: .utf8)!
        let result = SchemaBinding.parseFormURLEncoded(body)
        XCTAssertEqual(result["name"] as? String, "Alice")
        XCTAssertEqual(result["age"] as? String, "30")
    }

    func testFormURLEncoded_repeatedKey_becomesArray() {
        let body = "tag=swift&tag=aro".data(using: .utf8)!
        let result = SchemaBinding.parseFormURLEncoded(body)
        let tags = result["tag"] as? [String]
        XCTAssertNotNil(tags)
        XCTAssertEqual(tags, ["swift", "aro"])
    }

    func testFormURLEncoded_threeRepeatedKeys() {
        let body = "x=1&x=2&x=3".data(using: .utf8)!
        let result = SchemaBinding.parseFormURLEncoded(body)
        let values = result["x"] as? [String]
        XCTAssertEqual(values, ["1", "2", "3"])
    }

    func testFormURLEncoded_percentEncodedChars() {
        let body = "city=San%20Francisco&country=United%20States".data(using: .utf8)!
        let result = SchemaBinding.parseFormURLEncoded(body)
        XCTAssertEqual(result["city"] as? String, "San Francisco")
        XCTAssertEqual(result["country"] as? String, "United States")
    }

    func testFormURLEncoded_plusAsSpace() {
        let body = "message=hello+world".data(using: .utf8)!
        let result = SchemaBinding.parseFormURLEncoded(body)
        XCTAssertEqual(result["message"] as? String, "hello world")
    }

    func testFormURLEncoded_keyWithoutValue() {
        let body = "flag".data(using: .utf8)!
        let result = SchemaBinding.parseFormURLEncoded(body)
        XCTAssertEqual(result["flag"] as? String, "")
    }

    func testFormURLEncoded_emptyBody() {
        let body = Data()
        let result = SchemaBinding.parseFormURLEncoded(body)
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - parseMultipartFormData

    private func makeMultipartBody(boundary: String, parts: [(name: String, contentType: String?, value: Data)]) -> Data {
        var body = Data()
        for part in parts {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(part.name)\"\r\n".data(using: .utf8)!)
            if let ct = part.contentType {
                body.append("Content-Type: \(ct)\r\n".data(using: .utf8)!)
            }
            body.append("\r\n".data(using: .utf8)!)
            body.append(part.value)
            body.append("\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }

    func testMultipart_singleTextField() {
        let boundary = "TestBoundary123"
        let body = makeMultipartBody(boundary: boundary, parts: [
            (name: "username", contentType: nil, value: "alice".data(using: .utf8)!)
        ])
        let result = SchemaBinding.parseMultipartFormData(body, boundary: boundary)
        XCTAssertEqual(result["username"] as? String, "alice")
    }

    func testMultipart_twoTextFields() {
        let boundary = "Boundary456"
        let body = makeMultipartBody(boundary: boundary, parts: [
            (name: "first", contentType: nil, value: "Hello".data(using: .utf8)!),
            (name: "second", contentType: nil, value: "World".data(using: .utf8)!)
        ])
        let result = SchemaBinding.parseMultipartFormData(body, boundary: boundary)
        XCTAssertEqual(result["first"] as? String, "Hello")
        XCTAssertEqual(result["second"] as? String, "World")
    }

    func testMultipart_mixedTextAndBinary() {
        let boundary = "MixedBoundary"
        let binaryData = Data([0x89, 0x50, 0x4E, 0x47])  // PNG header bytes
        let body = makeMultipartBody(boundary: boundary, parts: [
            (name: "description", contentType: nil, value: "an image".data(using: .utf8)!),
            (name: "file", contentType: "image/png", value: binaryData)
        ])
        let result = SchemaBinding.parseMultipartFormData(body, boundary: boundary)
        XCTAssertEqual(result["description"] as? String, "an image")
        XCTAssertEqual(result["file"] as? Data, binaryData)
    }

    func testMultipart_textContentTypeIsString() {
        let boundary = "TextBoundary"
        let body = makeMultipartBody(boundary: boundary, parts: [
            (name: "note", contentType: "text/plain", value: "plain text".data(using: .utf8)!)
        ])
        let result = SchemaBinding.parseMultipartFormData(body, boundary: boundary)
        XCTAssertEqual(result["note"] as? String, "plain text")
    }

    // MARK: - extractBoundary

    func testExtractBoundary_standard() {
        let ct = "multipart/form-data; boundary=----WebKitFormBoundary"
        XCTAssertEqual(SchemaBinding.extractBoundary(from: ct), "----WebKitFormBoundary")
    }

    func testExtractBoundary_quoted() {
        let ct = "multipart/form-data; boundary=\"my boundary\""
        XCTAssertEqual(SchemaBinding.extractBoundary(from: ct), "my boundary")
    }

    func testExtractBoundary_missing() {
        let ct = "application/json"
        XCTAssertNil(SchemaBinding.extractBoundary(from: ct))
    }

    // MARK: - bindRequestBody dispatch

    func testBindRequestBody_formURLEncoded_usesFormParser() throws {
        let body = "name=Bob&role=admin".data(using: .utf8)!
        let result = try OpenAPIContextBinder.bindRequestBody(
            body,
            schema: nil,
            components: nil,
            contentType: "application/x-www-form-urlencoded"
        )
        let bodyDict = result["request.body"] as? [String: Any]
        XCTAssertEqual(bodyDict?["name"] as? String, "Bob")
        XCTAssertEqual(bodyDict?["role"] as? String, "admin")
        // Also flattened keys
        XCTAssertEqual(result["request.body.name"] as? String, "Bob")
        XCTAssertEqual(result["request.body.role"] as? String, "admin")
    }

    func testBindRequestBody_json_usesJSONParser() throws {
        let body = #"{"key":"value"}"#.data(using: .utf8)!
        let result = try OpenAPIContextBinder.bindRequestBody(
            body,
            schema: nil,
            components: nil,
            contentType: "application/json"
        )
        let bodyDict = result["request.body"] as? [String: Any]
        XCTAssertEqual(bodyDict?["key"] as? String, "value")
    }

    func testBindRequestBody_nilContentType_usesJSONParser() throws {
        let body = #"{"hello":"world"}"#.data(using: .utf8)!
        let result = try OpenAPIContextBinder.bindRequestBody(
            body,
            schema: nil,
            components: nil,
            contentType: nil
        )
        let bodyDict = result["request.body"] as? [String: Any]
        XCTAssertEqual(bodyDict?["hello"] as? String, "world")
    }

    func testBindRequestBody_emptyBody_returnsEmpty() throws {
        let result = try OpenAPIContextBinder.bindRequestBody(
            nil,
            schema: nil,
            components: nil,
            contentType: "application/x-www-form-urlencoded"
        )
        XCTAssertTrue(result.isEmpty)
    }
}
