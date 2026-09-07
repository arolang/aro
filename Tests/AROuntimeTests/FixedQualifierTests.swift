// ============================================================
// FixedQualifierTests.swift
// ARO Runtime — the `fixed` Compute qualifier (GitLab #517)
// ============================================================
//
// `Compute the <total> from <qty> * <price>.` with 3 and 2.40 yields
// 7.199999999999999. Console output has hidden that since GitLab #474
// (15 significant digits), but files do not and must not: `Write`
// serializes at full precision, so a gold-layer CSV shipped
// `99.94999999999999` in its revenue column.
//
// `fixed` moves the fix from the renderer to the value: round through
// the decimal spelling, so the stored Double is the one nearest to
// 99.95 and every downstream path — CSV, JSON, console, further
// arithmetic — agrees about it.

import Foundation
import Testing
@testable import ARORuntime
@testable import AROParser

@Suite("fixed qualifier (#517)")
struct FixedQualifierTests {

    private func fixed(
        _ input: any Sendable,
        with parameters: (any Sendable)? = nil
    ) async throws -> any Sendable {
        let span = SourceSpan(at: SourceLocation())
        let result = ResultDescriptor(base: "out", specifiers: ["fixed"], span: span)
        let object = ObjectDescriptor(preposition: .from, base: "input",
                                      specifiers: [], span: span)
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("input", value: input)
        if let parameters { context.bind("_with_", value: parameters) }
        return try await ComputeAction().execute(result: result, object: object,
                                                 context: context)
    }

    @Test("two decimal places by default")
    func defaultsToMoney() async throws {
        let value = try await fixed(7.199999999999999)
        #expect(value as? Double == 7.2)
    }

    @Test("the artifact from the issue's repro becomes the written number")
    func absorbsSummedArtifact() async throws {
        // 19.99 × 2 + 19.99 × 3 — the medallion book's EMEA revenue.
        let raw = 19.99 * 2 + 19.99 * 3
        #expect(raw != 99.95)                       // the defect
        let value = try await fixed(raw)
        #expect(value as? Double == 99.95)          // the fix
    }

    @Test("the result is a number, not a rendered string")
    func staysNumeric() async throws {
        // A string would render right and then quote itself into a JSON
        // data product, which is a different wrong answer.
        let value = try await fixed(1.005)
        #expect(value is Double)
        #expect(value is String == false)
    }

    @Test("places comes from the with clause")
    func honoursPlaces() async throws {
        let value = try await fixed(1.23456, with: ["places": 3] as [String: any Sendable])
        #expect(value as? Double == 1.235)
    }

    @Test("bare with is read as the place count")
    func honoursBarePlaces() async throws {
        let value = try await fixed(1.23456, with: 1)
        #expect(value as? Double == 1.2)
    }

    @Test("zero places rounds to a whole number")
    func zeroPlaces() async throws {
        let value = try await fixed(2.6, with: ["places": 0] as [String: any Sendable])
        #expect(value as? Double == 3.0)
    }

    @Test("integers widen rather than error")
    func acceptsIntegers() async throws {
        let value = try await fixed(7)
        #expect(value as? Double == 7.0)
    }

    @Test("a numeric string is read as a number")
    func acceptsNumericStrings() async throws {
        let value = try await fixed("19.987")
        #expect(value as? Double == 19.99)
    }

    @Test("a non-numeric input is an error, not a silent pass-through")
    func rejectsNonNumbers() async throws {
        await #expect(throws: (any Error).self) {
            _ = try await fixed("not a price")
        }
    }

    @Test("an out-of-range place count is an error")
    func rejectsSillyPlaces() async throws {
        await #expect(throws: (any Error).self) {
            _ = try await fixed(1.5, with: ["places": 99] as [String: any Sendable])
        }
    }

    @Test("non-finite values pass through rather than inventing a form")
    func passesThroughNonFinite() async throws {
        let value = try await fixed(Double.infinity)
        #expect((value as? Double)?.isInfinite == true)
    }

    @Test("check time knows the qualifier, and points `round` at it")
    func catalogAndRedirect() {
        #expect(ComputeQualifierCatalog.isBuiltIn("fixed"))
        let hint = ComputeQualifierCatalog.redirect(
            for: "round", result: "price", object: "raw")
        #expect(hint?.contains("fixed") == true)
        // `money` is the other name people reach for, and edit distance
        // will never find `fixed` from it.
        let money = ComputeQualifierCatalog.redirect(
            for: "money", result: "price", object: "raw")
        #expect(money?.contains("fixed") == true)
        // `Money` PascalCase is ARO-0014's domain type, not an
        // operation, and still belongs in the `as` clause.
        let type = ComputeQualifierCatalog.redirect(
            for: "Money", result: "price", object: "raw")
        #expect(type?.contains("as Money") == true)
    }
}
