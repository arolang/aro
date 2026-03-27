// ============================================================
// SchemaCompositionTests.swift
// ARO Runtime - OpenAPI Schema Composition Validation Tests
// ============================================================

import Foundation
import Testing
@testable import ARORuntime

// MARK: - allOf Tests

@Suite("Schema Composition - allOf")
struct SchemaAllOfTests {

    @Test("allOf with two object schemas merges properties from both")
    func testAllOfMergesObjectProperties() throws {
        let schemaA = Schema(type: "object", properties: [
            "name": SchemaRef(Schema(type: "string"))
        ])
        let schemaB = Schema(type: "object", properties: [
            "age": SchemaRef(Schema(type: "number"))
        ])
        let schema = Schema(allOf: [SchemaRef(schemaA), SchemaRef(schemaB)])

        let json: [String: Any] = ["name": "Alice", "age": 30.0]
        let result = try SchemaBinding.parseValue(json: json, schema: schema, components: nil)

        let dict = try #require(result as? [String: Any])
        #expect(dict["name"] as? String == "Alice")
        #expect(dict["age"] as? Double == 30.0)
    }

    @Test("allOf where one sub-schema fails throws an error")
    func testAllOfFailsWhenOneSubSchemaFails() throws {
        let schemaA = Schema(type: "object", properties: [
            "name": SchemaRef(Schema(type: "string"))
        ])
        // schemaB expects an integer; the value is a string — will fail type check
        let schemaB = Schema(type: "integer")
        let schema = Schema(allOf: [SchemaRef(schemaA), SchemaRef(schemaB)])

        let json: [String: Any] = ["name": "Alice"]
        #expect(throws: (any Error).self) {
            try SchemaBinding.parseValue(json: json, schema: schema, components: nil)
        }
    }
}

// MARK: - anyOf Tests

@Suite("Schema Composition - anyOf")
struct SchemaAnyOfTests {

    @Test("anyOf where first fails but second succeeds returns second result")
    func testAnyOfReturnsFirstMatch() throws {
        let schemaInt = Schema(type: "integer")
        let schemaStr = Schema(type: "string")
        let schema = Schema(anyOf: [SchemaRef(schemaInt), SchemaRef(schemaStr)])

        let result = try SchemaBinding.parseValue(json: "hello", schema: schema, components: nil)
        #expect(result as? String == "hello")
    }

    @Test("anyOf where all sub-schemas fail throws compositionFailed")
    func testAnyOfAllFailThrows() throws {
        let schemaInt = Schema(type: "integer")
        let schemaBool = Schema(type: "boolean")
        let schema = Schema(anyOf: [SchemaRef(schemaInt), SchemaRef(schemaBool)])

        #expect(throws: SchemaBindingError.compositionFailed("anyOf: value does not match any of the listed schemas")) {
            try SchemaBinding.parseValue(json: "not-a-number-or-bool", schema: schema, components: nil)
        }
    }
}

// MARK: - oneOf Tests

@Suite("Schema Composition - oneOf")
struct SchemaOneOfTests {

    @Test("oneOf where exactly one schema matches returns that result")
    func testOneOfExactlyOneMatch() throws {
        let schemaStr = Schema(type: "string")
        let schemaInt = Schema(type: "integer")
        let schema = Schema(oneOf: [SchemaRef(schemaStr), SchemaRef(schemaInt)])

        let result = try SchemaBinding.parseValue(json: "hello", schema: schema, components: nil)
        #expect(result as? String == "hello")
    }

    @Test("oneOf where no schema matches throws compositionFailed")
    func testOneOfNoMatchThrows() throws {
        let schemaStr = Schema(type: "string")
        let schemaInt = Schema(type: "integer")
        let schema = Schema(oneOf: [SchemaRef(schemaStr), SchemaRef(schemaInt)])

        #expect(throws: SchemaBindingError.compositionFailed("oneOf: value does not match any schema")) {
            try SchemaBinding.parseValue(json: true, schema: schema, components: nil)
        }
    }

    @Test("oneOf where two schemas both match throws compositionFailed for ambiguity")
    func testOneOfAmbiguousMatchThrows() throws {
        // Both schemas accept numbers; a Double will match both
        let schemaNumber = Schema(type: "number")
        let schemaNumber2 = Schema(type: "number")
        let schema = Schema(oneOf: [SchemaRef(schemaNumber), SchemaRef(schemaNumber2)])

        #expect(throws: (any Error).self) {
            let result = try SchemaBinding.parseValue(json: 42.0, schema: schema, components: nil)
            _ = result
        }
    }
}

// MARK: - not Tests

@Suite("Schema Composition - not")
struct SchemaNottTests {

    @Test("not where value matches the not-schema throws compositionFailed")
    func testNotMatchingThrows() throws {
        let notSchema = Schema(type: "string")
        let schema = Schema(not: SchemaRef(notSchema))

        #expect(throws: SchemaBindingError.compositionFailed("not: value must not match the 'not' schema")) {
            try SchemaBinding.parseValue(json: "forbidden-string", schema: schema, components: nil)
        }
    }

    @Test("not where value does NOT match the not-schema passes through unchanged")
    func testNotNonMatchingPasses() throws {
        let notSchema = Schema(type: "string")
        let schema = Schema(not: SchemaRef(notSchema))

        let result = try SchemaBinding.parseValue(json: 42.0, schema: schema, components: nil)
        #expect(result as? Double == 42.0)
    }
}

// MARK: - Schema Decoding Tests (not field)

@Suite("Schema Decoding - not field")
struct SchemaNotDecodingTests {

    @Test("Schema decodes 'not' field from JSON")
    func testDecodesNotField() throws {
        let json = """
        {
            "not": { "type": "string" }
        }
        """
        let data = json.data(using: .utf8)!
        let schema = try JSONDecoder().decode(Schema.self, from: data)
        #expect(schema.not != nil)
        #expect(schema.not?.value.type == "string")
    }

    @Test("Schema decodes 'allOf' field from JSON")
    func testDecodesAllOfField() throws {
        let json = """
        {
            "allOf": [
                { "type": "object", "properties": { "name": { "type": "string" } } },
                { "type": "object", "properties": { "age":  { "type": "number" } } }
            ]
        }
        """
        let data = json.data(using: .utf8)!
        let schema = try JSONDecoder().decode(Schema.self, from: data)
        #expect(schema.allOf?.count == 2)
    }
}
