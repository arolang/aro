// ============================================================
// MapSchemaProjectionTests.swift
// ARO Runtime - Map projects onto a schema (GitLab #559)
// ============================================================
//
// `Map` is documented (ARO-0018, Chapter 34) as mapping a collection onto a
// target type from `components/schemas`, copying only the fields the target
// declares. It did neither:
//
//   * `Map the <summaries: List<UserSummary>> from the <users>.` took the
//     first specifier that is not a known *scalar* type name and treated it as
//     a **field name**. `List<UserSummary>` is not a field, so the lookup
//     missed and the result was `[]`.
//   * `Map the <summaries> as List<UserSummary> from the <users>.` sets
//     `asType` rather than a specifier, so there was no field specifier at all
//     and the rows passed through **untouched** — `password-hash` included.
//     That one looked like it worked, and Chapter 34 offers exactly it as the
//     way to keep sensitive fields out of a response.

import Foundation
import Testing
@testable import ARORuntime
@testable import AROParser

@Suite("Map schema projection (GitLab #559)")
struct MapSchemaProjectionTests {

    // MARK: - Fixtures

    private func spec(_ schemas: [String: Schema]) -> OpenAPISpec {
        OpenAPISpec(
            openapi: "3.0.3",
            info: OpenAPIInfo(title: "Test API", version: "1.0.0", description: nil),
            paths: [:],
            components: Components(
                schemas: schemas.mapValues { SchemaRef($0) },
                responses: nil, parameters: nil, requestBodies: nil,
                headers: nil, securitySchemes: nil
            ),
            servers: nil, security: nil
        )
    }

    private var userSummary: Schema {
        Schema(type: "object", properties: [
            "id": SchemaRef(Schema(type: "string")),
            "name": SchemaRef(Schema(type: "string")),
            "email": SchemaRef(Schema(type: "string")),
        ])
    }

    /// The issue's row: three declared fields and one that must not escape.
    private var users: [any Sendable] {
        [[
            "id": "1", "name": "a", "email": "a@x", "password-hash": "zz",
        ] as [String: any Sendable]]
    }

    private func context(_ schemas: [String: Schema]) -> RuntimeContext {
        let context = RuntimeContext(featureSetName: "Test")
        context.setSchemaRegistry(OpenAPISchemaRegistry(spec: spec(schemas)))
        context.bind("users", value: users)
        return context
    }

    private func descriptors(
        specifiers: [String] = [], asType: String? = nil
    ) -> (ResultDescriptor, ObjectDescriptor) {
        let span = SourceSpan(at: SourceLocation())
        return (
            ResultDescriptor(base: "summaries", specifiers: specifiers, span: span, asType: asType),
            ObjectDescriptor(preposition: .from, base: "users", specifiers: [], span: span)
        )
    }

    private func rows(_ value: any Sendable) -> [[String: any Sendable]] {
        (value as? [any Sendable])?.compactMap { $0 as? [String: any Sendable] } ?? []
    }

    // MARK: - The two spellings

    @Test("The qualifier form projects onto the schema")
    func qualifierFormProjects() async throws {
        let (result, object) = descriptors(specifiers: ["List<UserSummary>"])
        let value = try await MapAction().execute(
            result: result, object: object, context: context(["UserSummary": userSummary]))

        let projected = rows(value)
        #expect(projected.count == 1, "was [] — the schema name was read as a field")
        #expect(Set(projected[0].keys) == ["id", "name", "email"])
        #expect(projected[0]["password-hash"] == nil)
    }

    @Test("The `as` form projects too, instead of passing every field through")
    func asFormProjects() async throws {
        let (result, object) = descriptors(asType: "List<UserSummary>")
        let value = try await MapAction().execute(
            result: result, object: object, context: context(["UserSummary": userSummary]))

        let projected = rows(value)
        #expect(projected.count == 1)
        // This is the one that looked like it worked.
        #expect(projected[0]["password-hash"] == nil, "the sensitive field passed through")
        #expect(Set(projected[0].keys) == ["id", "name", "email"])
    }

    @Test("Both spellings give the same answer")
    func bothSpellingsAgree() async throws {
        let ctx = context(["UserSummary": userSummary])
        let (qResult, object) = descriptors(specifiers: ["List<UserSummary>"])
        let (aResult, _) = descriptors(asType: "List<UserSummary>")

        let viaQualifier = rows(try await MapAction().execute(
            result: qResult, object: object, context: ctx))
        let viaAs = rows(try await MapAction().execute(
            result: aResult, object: object, context: ctx))

        #expect(Set(viaQualifier[0].keys) == Set(viaAs[0].keys))
    }

    @Test("A bare schema name, with no List wrapper, projects as well")
    func bareSchemaName() async throws {
        let (result, object) = descriptors(specifiers: ["UserSummary"])
        let value = try await MapAction().execute(
            result: result, object: object, context: context(["UserSummary": userSummary]))
        #expect(Set(rows(value)[0].keys) == ["id", "name", "email"])
    }

    // MARK: - Nesting

    @Test("A nested record is projected too, not only the top level")
    func nestedProjection() async throws {
        // Projecting only the top level would leave a sensitive field one
        // nesting away from the response.
        let address = Schema(type: "object", properties: [
            "city": SchemaRef(Schema(type: "string")),
        ])
        let deep = Schema(type: "object", properties: [
            "id": SchemaRef(Schema(type: "string")),
            "address": SchemaRef(Schema(ref: "#/components/schemas/Address")),
        ])

        let context = RuntimeContext(featureSetName: "Test")
        context.setSchemaRegistry(OpenAPISchemaRegistry(
            spec: spec(["Address": address, "Deep": deep])))
        context.bind("users", value: [[
            "id": "1",
            "secret": "s",
            "address": ["city": "X", "zip": "9"] as [String: any Sendable],
        ] as [String: any Sendable]] as [any Sendable])

        let (result, object) = descriptors(specifiers: ["List<Deep>"])
        let value = try await MapAction().execute(
            result: result, object: object, context: context)

        let row = rows(value)[0]
        #expect(Set(row.keys) == ["id", "address"])
        #expect(row["secret"] == nil)
        let nested = row["address"] as? [String: any Sendable]
        #expect(nested?["city"] as? String == "X")
        #expect(nested?["zip"] == nil, "an undeclared nested field survived")
    }

    // MARK: - An annotation that names no schema is an error, not a wrong answer

    @Test("An unknown schema name is reported rather than read as a field")
    func unknownSchemaThrows() async {
        let (result, object) = descriptors(specifiers: ["List<NoSuchSchema>"])
        let ctx = context(["UserSummary": userSummary])

        await #expect(throws: SchemaValidationError.self) {
            _ = try await MapAction().execute(result: result, object: object, context: ctx)
        }
    }

    @Test("A schema annotation with no registry at all is reported")
    func noRegistryThrows() async {
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("users", value: users)
        let (result, object) = descriptors(specifiers: ["List<UserSummary>"])

        await #expect(throws: SchemaValidationError.self) {
            _ = try await MapAction().execute(result: result, object: object, context: context)
        }
    }

    // MARK: - What must not change

    @Test("A lowercase specifier is still a field name")
    func fieldSpecifierUnchanged() async throws {
        let (result, object) = descriptors(specifiers: ["name"])
        let value = try await MapAction().execute(
            result: result, object: object, context: context(["UserSummary": userSummary]))

        #expect((value as? [any Sendable])?.compactMap { $0 as? String } == ["a"])
    }

    @Test("A bare scalar type annotation is not a schema lookup")
    func scalarTypesAreNotSchemas() {
        for name in ["List", "String", "Integer", "Boolean", "Object", "Map"] {
            #expect(MapAction.schemaName(fromAnnotation: name) == nil, "\(name) was read as a schema")
        }
    }

    @Test("No annotation still passes the rows through untouched")
    func noAnnotationPassesThrough() async throws {
        let (result, object) = descriptors()
        let value = try await MapAction().execute(
            result: result, object: object, context: context(["UserSummary": userSummary]))

        // No projection was asked for, so nothing is dropped — including the
        // sensitive field. That is why the annotation has to work.
        #expect(rows(value)[0]["password-hash"] as? String == "zz")
    }

    // MARK: - Annotation parsing

    @Test("Every wrapper the annotation may use is unwrapped")
    func wrappersUnwrap() {
        #expect(MapAction.schemaName(fromAnnotation: "List<UserSummary>") == "UserSummary")
        #expect(MapAction.schemaName(fromAnnotation: "Array<UserSummary>") == "UserSummary")
        #expect(MapAction.schemaName(fromAnnotation: "Set<UserSummary>") == "UserSummary")
        #expect(MapAction.schemaName(fromAnnotation: "UserSummary") == "UserSummary")
    }

    @Test("A lowercase annotation names no schema")
    func lowercaseIsNotASchema() {
        #expect(MapAction.schemaName(fromAnnotation: "name") == nil)
        #expect(MapAction.schemaName(fromAnnotation: "password-hash") == nil)
        #expect(MapAction.schemaName(fromAnnotation: "List<name>") == nil)
    }
}
