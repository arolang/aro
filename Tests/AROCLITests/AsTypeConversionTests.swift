// ============================================================
// AsTypeConversionTests.swift
// AROCLI — `as <Type>` converts on the fast path too (GitLab #501)
// ============================================================

import Testing
import Foundation
import ARORuntime
@testable import AROCLI

@Suite("as-Type conversion", .serialized)
struct AsTypeConversionTests {

    private func run(_ statements: String...) async throws -> REPLSession {
        let session = REPLSession()
        for statement in statements {
            let result = try await session.executeStatement(statement)
            #expect(result.isSuccess, "failed: \(statement) → \(result)")
        }
        return session
    }

    @Test("as Float converts a numeric string — arithmetic multiplies, never repeats")
    func floatFromString() async throws {
        let session = try await run(
            #"Create the <s> with "21"."#,
            "Compute the <n> as Float from <s>.",
            "Compute the <double-n> from <n> * 2.")
        // The issue's symptom: "21" stayed a string and * 2 repeated it
        // into "2121".
        #expect("\(session.getVariable("double-n") ?? "nil")" == "42.0"
             || "\(session.getVariable("double-n") ?? "nil")" == "42")
        #expect(session.getVariable("n") is Double)
    }

    @Test("as Integer converts a numeric string to Int")
    func integerFromString() async throws {
        let session = try await run(
            #"Create the <s> with "4"."#,
            "Compute the <i> as Integer from <s>.",
            "Compute the <next> from <i> + 1.")
        #expect(session.getVariable("i") as? Int == 4)
        #expect("\(session.getVariable("next") ?? "nil")" == "5")
    }

    @Test("as Integer refuses lossy narrowing")
    func integerRefusesLossy() async throws {
        let session = try await run(
            #"Create the <s> with "3.5"."#,
            "Compute the <i> as Integer from <s>.")
        // 3.5 must not silently truncate to 3 under an annotation —
        // the value stays as-is (documented ResultTypeCoercion rule).
        #expect(session.getVariable("i") as? Int == nil)
    }

    @Test("Unannotated fast-path binds are untouched")
    func unannotatedUntouched() async throws {
        let session = try await run(
            #"Create the <s> with "21"."#,
            "Compute the <copy> from <s>.")
        #expect(session.getVariable("copy") as? String == "21")
    }

    @Test("as Float division stays fractional (the #475 behavior still holds)")
    func floatDivision() async throws {
        let session = try await run(
            "Create the <seven> with 7.",
            "Compute the <half> as Float from <seven> / 2.")
        #expect(session.getVariable("half") as? Double == 3.5)
    }
}
