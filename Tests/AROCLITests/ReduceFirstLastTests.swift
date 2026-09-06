// ============================================================
// ReduceFirstLastTests.swift
// AROCLI — Reduce with first()/last() (ARO-0018 §5, GitLab #499)
// ============================================================

import Testing
import Foundation
import ARORuntime
@testable import AROCLI

@Suite("Reduce first/last", .serialized)
struct ReduceFirstLastTests {

    private func session(_ statements: String...) async throws -> (REPLSession, [REPLResult]) {
        let session = REPLSession(suppressLogPrefix: true)
        var results: [REPLResult] = []
        for statement in statements {
            results.append(try await session.executeStatement(statement))
        }
        return (session, results)
    }

    private let seed = "Create the <orders> with [{ id: 1, cents: 480 }, { id: 2, cents: 260 }, { id: 3, cents: 720 }]."

    @Test("first() returns the first ELEMENT, unprojected")
    func firstElement() async throws {
        let (s, results) = try await session(
            seed,
            "Reduce the <head> from the <orders> with first().")
        #expect(results.allSatisfy { $0.isSuccess })
        let element = s.getVariable("head") as? [String: any Sendable]
        #expect("\(element?["id"] ?? "nil")" == "1")
        #expect("\(element?["cents"] ?? "nil")" == "480")
    }

    @Test("last(<field>) projects the field, like sum(<field>)")
    func lastField() async throws {
        let (s, results) = try await session(
            seed,
            "Reduce the <last-id> from the <orders> with last(<id>).")
        #expect(results.allSatisfy { $0.isSuccess })
        #expect("\(s.getVariable("last-id") ?? "nil")" == "3")
    }

    @Test("Scalar lists work without a field")
    func scalarList() async throws {
        let (s, results) = try await session(
            "Create the <nums> with [7, 8, 9].",
            "Reduce the <head> from the <nums> with first().",
            "Reduce the <tail> from the <nums> with last().")
        #expect(results.allSatisfy { $0.isSuccess })
        #expect("\(s.getVariable("head") ?? "nil")" == "7")
        #expect("\(s.getVariable("tail") ?? "nil")" == "9")
    }

    @Test("An empty collection errors — there is no element to invent")
    func emptyErrors() async throws {
        let (_, results) = try await session(
            "Create the <no-orders> with [].",
            "Reduce the <nope> from the <no-orders> with first().")
        #expect(!results[1].isSuccess)
    }

    @Test("A missing projection field errors per the happy path")
    func missingFieldErrors() async throws {
        let (_, results) = try await session(
            seed,
            "Reduce the <x> from the <orders> with first(<sparkle>).")
        #expect(!results[1].isSuccess)
    }

    @Test("The numeric aggregations are untouched")
    func numericRegression() async throws {
        let (s, results) = try await session(
            seed,
            "Reduce the <total> from the <orders> with sum(<cents>).",
            "Reduce the <n> from the <orders> with count().")
        #expect(results.allSatisfy { $0.isSuccess })
        #expect("\(s.getVariable("total") ?? "nil")" == "1460.0")
        #expect("\(s.getVariable("n") ?? "nil")" == "3")
    }
}
