// ============================================================
// SessionActionCompositionTests.swift
// AROCLI — user-defined actions calling each other in sessions
// ============================================================
//
// GitLab #503: definitions used to be compiled ALONE, while
// statements compile with every session definition as a companion
// — so a statement could call any action, but an action could
// never call a sibling action. Definitions now compile with the
// same companions statements get.

import Testing
import Foundation
import ARORuntime
@testable import AROCLI

@Suite("Session action composition", .serialized)
struct SessionActionCompositionTests {

    private func define(_ session: REPLSession, _ name: String, _ statements: [String],
                        activity: String = "Action takes <n>") async throws -> REPLResult {
        try await session.defineFeatureSet(name: name, activity: activity, statements: statements)
    }

    private let doubleBody = [
        "Extract the <x> from the <input: n>.",
        "Compute the <doubled> from <x> * 2.",
        "Return an <OK: status> with { doubled: <doubled> }.",
    ]

    private let quadrupleBody = [
        "Extract the <x> from the <input: n>.",
        "Application.Double the <once> from <x>.",
        "Extract the <d1> from the <once: doubled>.",
        "Application.Double the <twice> from <d1>.",
        "Extract the <d2> from the <twice: doubled>.",
        "Return an <OK: status> with { result: <d2> }.",
    ]

    @Test("An action can call a previously defined action")
    func actionCallsSibling() async throws {
        let session = REPLSession()
        let first = try await define(session, "Double", doubleBody)
        #expect(first.isSuccess)

        // This definition failed on main: 'Unknown user-defined
        // action Application.Double'.
        let second = try await define(session, "Quadruple", quadrupleBody)
        #expect(second.isSuccess)

        let call = try await session.executeStatement(
            "Application.Quadruple the <res> from 5.\nExtract the <answer> from the <res: result>.",
            companions: Array(session.featureSetSources.values))
        #expect(call.isSuccess)
        #expect("\(session.getVariable("answer") ?? "nil")" == "20")
    }

    @Test("Redefining the callee flows through the caller")
    func redefinitionFlowsThrough() async throws {
        let session = REPLSession()
        _ = try await define(session, "Double", doubleBody)
        _ = try await define(session, "Quadruple", quadrupleBody)

        // Double now triples — the composition must pick it up.
        _ = try await define(session, "Double", [
            "Extract the <x> from the <input: n>.",
            "Compute the <doubled> from <x> * 3.",
            "Return an <OK: status> with { doubled: <doubled> }.",
        ])

        _ = try await session.executeStatement(
            "Application.Quadruple the <res2> from 5.\nExtract the <answer2> from the <res2: result>.",
            companions: Array(session.featureSetSources.values))
        #expect("\(session.getVariable("answer2") ?? "nil")" == "45")
    }

    @Test("A forward reference still errors clearly (define the callee first)")
    func forwardReferenceErrors() async throws {
        let session = REPLSession()
        let result = try await define(session, "Quadruple", quadrupleBody)
        guard case .error(let message) = result else {
            Issue.record("expected an error, got \(result)")
            return
        }
        #expect(message.contains("Double") || message.lowercased().contains("unknown"))
    }

    @Test("Self-recursion keeps working")
    func selfRecursion() async throws {
        let session = REPLSession()
        let result = try await define(session, "SumTo", [
            "Extract the <x> from the <input: n>.",
            "Return an <OK: status> with { sum: 0 } when <x> <= 0.",
            "Compute the <next-n> from <x> - 1.",
            "Application.SumTo the <inner> from <next-n>.",
            "Extract the <partial> from the <inner: sum>.",
            "Compute the <total> from <x> + <partial>.",
            "Return an <OK: status> with { sum: <total> }.",
        ])
        #expect(result.isSuccess)

        _ = try await session.executeStatement(
            "Application.SumTo the <r> from 4.\nExtract the <s> from the <r: sum>.",
            companions: Array(session.featureSetSources.values))
        #expect("\(session.getVariable("s") ?? "nil")" == "10")
    }
}
