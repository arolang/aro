// ============================================================
// ObjectFieldAccessTests.swift
// ARO Runtime — `<record: field>` in the object slot (GitLab #594)
// ============================================================
//
// `Compute` and `Create` resolved the object's *base* and dropped its
// specifiers, so `Compute the <doubled> from <item: price>.` bound the whole
// `item` record. Nothing said so: it checked clean and exited `[OK]`.
//
// The same statement with an operator — `<item: price> * 2` — always worked,
// because the parser makes that an expression and the expression evaluator
// resolves member access properly. So the two halves of one statement
// disagreed about what `<item: price>` meant, and which reading you got
// depended on whether you happened to write arithmetic after it.

import Foundation
import Testing
@testable import ARORuntime
@testable import AROParser

@Suite("Object-slot field access (#594)")
struct ObjectFieldAccessTests {

    private let item: [String: any Sendable] = [
        "price": 3,
        "name": "pen",
        "nested": ["deep": 7] as [String: any Sendable],
    ]

    private func run(
        _ action: any ActionImplementation,
        resultBase: String = "out",
        resultQualifier: String? = nil,
        objectBase: String = "item",
        objectSpecifiers: [String],
        preposition: Preposition = .from
    ) async throws -> any Sendable {
        let span = SourceSpan(at: SourceLocation())
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("item", value: item)
        return try await action.execute(
            result: ResultDescriptor(
                base: resultBase,
                specifiers: resultQualifier.map { [$0] } ?? [],
                span: span
            ),
            object: ObjectDescriptor(
                preposition: preposition,
                base: objectBase,
                specifiers: objectSpecifiers,
                span: span
            ),
            context: context
        )
    }

    // MARK: - Compute

    @Test("Compute reads the field, not the record")
    func computeReadsField() async throws {
        let value = try await run(ComputeAction(), objectSpecifiers: ["price"])
        #expect(value as? Int == 3)
    }

    @Test("A result qualifier applies to the field, not the record")
    func qualifierAppliesToField() async throws {
        // The sharpest form of the bug: `uppercase` over the whole record
        // returned every key and value uppercased, which looks enough like a
        // value to travel a long way before it fails.
        let value = try await run(
            ComputeAction(), resultQualifier: "uppercase", objectSpecifiers: ["name"]
        )
        #expect(value as? String == "PEN")
    }

    @Test("A nested path is followed all the way down")
    func nestedPath() async throws {
        let value = try await run(ComputeAction(), objectSpecifiers: ["nested", "deep"])
        #expect(value as? Int == 7)
    }

    @Test("No specifiers still means the whole record")
    func noSpecifiersYieldsRecord() async throws {
        let value = try await run(ComputeAction(), objectSpecifiers: [])
        #expect((value as? [String: any Sendable])?.count == 3)
    }

    @Test("A field the record does not have is an error, not a shrug")
    func missingFieldThrows() async throws {
        await #expect(throws: (any Error).self) {
            _ = try await run(ComputeAction(), objectSpecifiers: ["nope"])
        }
    }

    @Test("An undefined base is still an undefined base")
    func missingBaseThrows() async throws {
        await #expect(throws: (any Error).self) {
            _ = try await run(ComputeAction(), objectBase: "ghost", objectSpecifiers: ["price"])
        }
    }

    // MARK: - Create

    @Test("Create reads the field, not the record")
    func createReadsField() async throws {
        let value = try await run(
            CreateAction(), objectSpecifiers: ["name"], preposition: .with
        )
        #expect(value as? String == "pen")
    }

    @Test("Create without specifiers still takes the whole record")
    func createNoSpecifiers() async throws {
        let value = try await run(
            CreateAction(), objectSpecifiers: [], preposition: .with
        )
        #expect((value as? [String: any Sendable])?.count == 3)
    }
}
