// ============================================================
// SchemaBindingResponseValidationTests.swift
// ARO Runtime - Response body validation tests (ARO-0180)
// ============================================================

import XCTest
@testable import ARORuntime

final class SchemaBindingResponseValidationTests: XCTestCase {

    // MARK: - Helpers

    /// Build a minimal Operation with a single response schema.
    private func makeOperation(
        statusCode: String,
        schemaType: String,
        schemaProperties: [String: SchemaRef]? = nil,
        required: [String]? = nil
    ) -> ARORuntime.Operation {
        let schema = Schema(
            type: schemaType,
            properties: schemaProperties,
            required: required
        )
        let mediaType = MediaType(schema: SchemaRef(schema))
        let response = OpenAPIResponse(
            description: "Response",
            headers: nil,
            content: ["application/json": mediaType],
            ref: nil
        )
        return ARORuntime.Operation(
            operationId: "testOp",
            summary: nil,
            description: nil,
            tags: nil,
            parameters: nil,
            requestBody: nil,
            responses: [statusCode: response],
            deprecated: nil,
            security: nil
        )
    }

    /// Build an Operation with no content (no schema to validate).
    private func makeOperationNoContent(statusCode: String) -> ARORuntime.Operation {
        let response = OpenAPIResponse(
            description: "No content",
            headers: nil,
            content: nil,
            ref: nil
        )
        return ARORuntime.Operation(
            operationId: "testOp",
            summary: nil,
            description: nil,
            tags: nil,
            parameters: nil,
            requestBody: nil,
            responses: [statusCode: response],
            deprecated: nil,
            security: nil
        )
    }

    /// Build an Operation with no responses at all.
    private func makeOperationEmptyResponses() -> ARORuntime.Operation {
        return ARORuntime.Operation(
            operationId: "testOp",
            summary: nil,
            description: nil,
            tags: nil,
            parameters: nil,
            requestBody: nil,
            responses: [:],
            deprecated: nil,
            security: nil
        )
    }

    // MARK: - Tests

    /// Valid body against an integer schema should return nil.
    func testValidIntegerBody_returnsNil() {
        let operation = makeOperation(statusCode: "200", schemaType: "integer")
        let result = SchemaBinding.validateResponseBody(
            42,
            forStatusCode: 200,
            operation: operation,
            components: nil
        )
        XCTAssertNil(result, "Expected nil for valid integer body")
    }

    /// Valid body against a string schema should return nil.
    func testValidStringBody_returnsNil() {
        let operation = makeOperation(statusCode: "200", schemaType: "string")
        let result = SchemaBinding.validateResponseBody(
            "hello",
            forStatusCode: 200,
            operation: operation,
            components: nil
        )
        XCTAssertNil(result, "Expected nil for valid string body")
    }

    /// Body with wrong type should return a non-nil error string.
    func testInvalidBody_wrongType_returnsErrorString() {
        let operation = makeOperation(statusCode: "200", schemaType: "string")
        // Passing an integer when the schema expects a string
        let result = SchemaBinding.validateResponseBody(
            123,
            forStatusCode: 200,
            operation: operation,
            components: nil
        )
        XCTAssertNotNil(result, "Expected an error string for type mismatch")
    }

    /// No response schema in spec should return nil (no validation performed).
    func testNoResponseSchema_returnsNil() {
        let operation = makeOperationNoContent(statusCode: "200")
        let result = SchemaBinding.validateResponseBody(
            ["key": "value"],
            forStatusCode: 200,
            operation: operation,
            components: nil
        )
        XCTAssertNil(result, "Expected nil when no schema is defined")
    }

    /// Unrecognised status code with no 'default' entry should return nil.
    func testUnrecognisedStatusCode_noDefault_returnsNil() {
        let operation = makeOperation(statusCode: "200", schemaType: "string")
        let result = SchemaBinding.validateResponseBody(
            "hello",
            forStatusCode: 404,
            operation: operation,
            components: nil
        )
        XCTAssertNil(result, "Expected nil when status code has no matching response and no default")
    }

    /// Status code with no match should fall back to 'default' response schema.
    func testFallbackToDefault_validBody_returnsNil() {
        // Create an operation with only a "default" response entry
        let schema = Schema(type: "string")
        let mediaType = MediaType(schema: SchemaRef(schema))
        let defaultResponse = OpenAPIResponse(
            description: "Default",
            headers: nil,
            content: ["application/json": mediaType],
            ref: nil
        )
        let operation = ARORuntime.Operation(
            operationId: "testOp",
            summary: nil,
            description: nil,
            tags: nil,
            parameters: nil,
            requestBody: nil,
            responses: ["default": defaultResponse],
            deprecated: nil,
            security: nil
        )
        // Status 503 is not defined; runtime should fall back to "default"
        let result = SchemaBinding.validateResponseBody(
            "ok",
            forStatusCode: 503,
            operation: operation,
            components: nil
        )
        XCTAssertNil(result, "Expected nil when body matches 'default' response schema")
    }

    /// Status code with no match falls back to 'default' and detects type violation.
    func testFallbackToDefault_invalidBody_returnsErrorString() {
        let schema = Schema(type: "string")
        let mediaType = MediaType(schema: SchemaRef(schema))
        let defaultResponse = OpenAPIResponse(
            description: "Default",
            headers: nil,
            content: ["application/json": mediaType],
            ref: nil
        )
        let operation = ARORuntime.Operation(
            operationId: "testOp",
            summary: nil,
            description: nil,
            tags: nil,
            parameters: nil,
            requestBody: nil,
            responses: ["default": defaultResponse],
            deprecated: nil,
            security: nil
        )
        // Sending an integer when schema expects string
        let result = SchemaBinding.validateResponseBody(
            99,
            forStatusCode: 503,
            operation: operation,
            components: nil
        )
        XCTAssertNotNil(result, "Expected an error string when body violates 'default' response schema")
    }

    /// Empty responses dict should return nil.
    func testEmptyResponses_returnsNil() {
        let operation = makeOperationEmptyResponses()
        let result = SchemaBinding.validateResponseBody(
            "anything",
            forStatusCode: 200,
            operation: operation,
            components: nil
        )
        XCTAssertNil(result, "Expected nil when operation has no responses defined")
    }

    /// Valid object body against object schema with required properties should return nil.
    func testValidObjectBody_returnsNil() {
        let operation = makeOperation(
            statusCode: "201",
            schemaType: "object",
            schemaProperties: [
                "id":   SchemaRef(Schema(type: "string")),
                "name": SchemaRef(Schema(type: "string"))
            ],
            required: ["id", "name"]
        )
        let body: [String: Any] = ["id": "abc", "name": "Alice"]
        let result = SchemaBinding.validateResponseBody(
            body,
            forStatusCode: 201,
            operation: operation,
            components: nil
        )
        XCTAssertNil(result, "Expected nil for valid object body")
    }

    /// Object body missing a required property should return an error string.
    func testObjectBodyMissingRequiredProperty_returnsErrorString() {
        let operation = makeOperation(
            statusCode: "201",
            schemaType: "object",
            schemaProperties: [
                "id":   SchemaRef(Schema(type: "string")),
                "name": SchemaRef(Schema(type: "string"))
            ],
            required: ["id", "name"]
        )
        let body: [String: Any] = ["id": "abc"]  // missing "name"
        let result = SchemaBinding.validateResponseBody(
            body,
            forStatusCode: 201,
            operation: operation,
            components: nil
        )
        XCTAssertNotNil(result, "Expected an error string when required property is missing")
    }
}
