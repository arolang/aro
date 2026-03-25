// ============================================================
// SchemaBindingDiscriminatorTests.swift
// ARO Runtime - Discriminator-based polymorphic schema tests
// ============================================================

import XCTest
@testable import ARORuntime

final class SchemaBindingDiscriminatorTests: XCTestCase {

    // MARK: - Helpers

    /// Build a minimal Components with Cat and Dog schemas.
    private func makeComponents() -> Components {
        let catSchema = Schema(
            type: "object",
            properties: [
                "type":   SchemaRef(Schema(type: "string")),
                "indoor": SchemaRef(Schema(type: "boolean"))
            ],
            required: ["type"]
        )
        let dogSchema = Schema(
            type: "object",
            properties: [
                "type": SchemaRef(Schema(type: "string")),
                "name": SchemaRef(Schema(type: "string"))
            ],
            required: ["type"]
        )
        return Components(
            schemas: [
                "Cat": SchemaRef(catSchema),
                "Dog": SchemaRef(dogSchema)
            ],
            responses: nil,
            parameters: nil,
            requestBodies: nil,
            headers: nil,
            securitySchemes: nil
        )
    }

    // MARK: - oneOf + discriminator with explicit mapping

    func testOneOf_discriminatorWithMapping_selectsCat() throws {
        let components = makeComponents()

        let petSchema = Schema(
            oneOf: [
                SchemaRef(Schema(ref: "#/components/schemas/Cat")),
                SchemaRef(Schema(ref: "#/components/schemas/Dog"))
            ],
            discriminator: Discriminator(
                propertyName: "type",
                mapping: [
                    "cat": "#/components/schemas/Cat",
                    "dog": "#/components/schemas/Dog"
                ]
            )
        )

        let payload: [String: Any] = ["type": "cat", "indoor": true]
        let result = try SchemaBinding.parseValue(json: payload, schema: petSchema, components: components)

        guard let dict = result as? [String: Any] else {
            return XCTFail("Expected [String: Any], got \(type(of: result))")
        }
        XCTAssertEqual(dict["type"] as? String, "cat")
        XCTAssertEqual(dict["indoor"] as? Bool, true)
    }

    func testOneOf_discriminatorWithMapping_selectsDog() throws {
        let components = makeComponents()

        let petSchema = Schema(
            oneOf: [
                SchemaRef(Schema(ref: "#/components/schemas/Cat")),
                SchemaRef(Schema(ref: "#/components/schemas/Dog"))
            ],
            discriminator: Discriminator(
                propertyName: "type",
                mapping: [
                    "cat": "#/components/schemas/Cat",
                    "dog": "#/components/schemas/Dog"
                ]
            )
        )

        let payload: [String: Any] = ["type": "dog", "name": "Rex"]
        let result = try SchemaBinding.parseValue(json: payload, schema: petSchema, components: components)

        guard let dict = result as? [String: Any] else {
            return XCTFail("Expected [String: Any], got \(type(of: result))")
        }
        XCTAssertEqual(dict["type"] as? String, "dog")
        XCTAssertEqual(dict["name"] as? String, "Rex")
    }

    // MARK: - oneOf + discriminator by convention (no mapping)

    func testOneOf_discriminatorByConvention_selectsDog() throws {
        let components = makeComponents()

        let petSchema = Schema(
            oneOf: [
                SchemaRef(Schema(ref: "#/components/schemas/Cat")),
                SchemaRef(Schema(ref: "#/components/schemas/Dog"))
            ],
            discriminator: Discriminator(propertyName: "type", mapping: nil)
        )

        // Convention: discriminator value "Dog" → "#/components/schemas/Dog"
        let payload: [String: Any] = ["type": "Dog", "name": "Rex"]
        let result = try SchemaBinding.parseValue(json: payload, schema: petSchema, components: components)

        guard let dict = result as? [String: Any] else {
            return XCTFail("Expected [String: Any], got \(type(of: result))")
        }
        XCTAssertEqual(dict["name"] as? String, "Rex")
    }

    // MARK: - anyOf + discriminator with mapping

    func testAnyOf_discriminatorWithMapping_selectsCat() throws {
        let components = makeComponents()

        let petSchema = Schema(
            anyOf: [
                SchemaRef(Schema(ref: "#/components/schemas/Cat")),
                SchemaRef(Schema(ref: "#/components/schemas/Dog"))
            ],
            discriminator: Discriminator(
                propertyName: "type",
                mapping: [
                    "cat": "#/components/schemas/Cat",
                    "dog": "#/components/schemas/Dog"
                ]
            )
        )

        let payload: [String: Any] = ["type": "cat", "indoor": false]
        let result = try SchemaBinding.parseValue(json: payload, schema: petSchema, components: components)

        guard let dict = result as? [String: Any] else {
            return XCTFail("Expected [String: Any], got \(type(of: result))")
        }
        XCTAssertEqual(dict["type"] as? String, "cat")
        XCTAssertEqual(dict["indoor"] as? Bool, false)
    }

    // MARK: - Unknown discriminator value throws invalidReference

    func testOneOf_discriminatorUnknownValue_throwsInvalidReference() throws {
        let components = makeComponents()

        let petSchema = Schema(
            oneOf: [
                SchemaRef(Schema(ref: "#/components/schemas/Cat")),
                SchemaRef(Schema(ref: "#/components/schemas/Dog"))
            ],
            discriminator: Discriminator(
                propertyName: "type",
                mapping: [
                    "cat": "#/components/schemas/Cat",
                    "dog": "#/components/schemas/Dog"
                ]
            )
        )

        // "fish" is not in the mapping → invalidReference
        let payload: [String: Any] = ["type": "fish", "fins": 2]
        XCTAssertThrowsError(
            try SchemaBinding.parseValue(json: payload, schema: petSchema, components: components)
        ) { error in
            guard case SchemaBindingError.invalidReference(let ref) = error else {
                return XCTFail("Expected .invalidReference, got \(error)")
            }
            XCTAssertEqual(ref, "#/components/schemas/fish")
        }
    }

    func testAnyOf_discriminatorUnknownValue_throwsInvalidReference() throws {
        let components = makeComponents()

        let petSchema = Schema(
            anyOf: [
                SchemaRef(Schema(ref: "#/components/schemas/Cat")),
                SchemaRef(Schema(ref: "#/components/schemas/Dog"))
            ],
            discriminator: Discriminator(propertyName: "type", mapping: nil)
        )

        let payload: [String: Any] = ["type": "Parrot"]
        XCTAssertThrowsError(
            try SchemaBinding.parseValue(json: payload, schema: petSchema, components: components)
        ) { error in
            guard case SchemaBindingError.invalidReference(let ref) = error else {
                return XCTFail("Expected .invalidReference, got \(error)")
            }
            XCTAssertEqual(ref, "#/components/schemas/Parrot")
        }
    }

    // MARK: - Missing discriminator property falls through to normal handling

    func testOneOf_missingDiscriminatorProperty_fallsThroughToNormalHandling() throws {
        let components = makeComponents()

        let petSchema = Schema(
            oneOf: [
                SchemaRef(Schema(ref: "#/components/schemas/Cat")),
                SchemaRef(Schema(ref: "#/components/schemas/Dog"))
            ],
            discriminator: Discriminator(
                propertyName: "type",
                mapping: [
                    "cat": "#/components/schemas/Cat",
                    "dog": "#/components/schemas/Dog"
                ]
            )
        )

        // Payload has no "type" field → discriminator fast path is skipped.
        // Cat requires "type" (required), Dog requires "type" (required) → neither matches → compositionFailed.
        let payload: [String: Any] = ["indoor": true]
        XCTAssertThrowsError(
            try SchemaBinding.parseValue(json: payload, schema: petSchema, components: components)
        ) { error in
            guard case SchemaBindingError.compositionFailed = error else {
                return XCTFail("Expected .compositionFailed, got \(error)")
            }
        }
    }

    // MARK: - Discriminator struct Codable round-trip

    func testDiscriminator_codableRoundTrip_withMapping() throws {
        let json = """
        {
            "propertyName": "type",
            "mapping": {
                "cat": "#/components/schemas/Cat",
                "dog": "#/components/schemas/Dog"
            }
        }
        """
        let data = Data(json.utf8)
        let disc = try JSONDecoder().decode(Discriminator.self, from: data)
        XCTAssertEqual(disc.propertyName, "type")
        XCTAssertEqual(disc.mapping?["cat"], "#/components/schemas/Cat")
        XCTAssertEqual(disc.mapping?["dog"], "#/components/schemas/Dog")
    }

    func testDiscriminator_codableRoundTrip_withoutMapping() throws {
        let json = """
        {
            "propertyName": "kind"
        }
        """
        let data = Data(json.utf8)
        let disc = try JSONDecoder().decode(Discriminator.self, from: data)
        XCTAssertEqual(disc.propertyName, "kind")
        XCTAssertNil(disc.mapping)
    }
}
