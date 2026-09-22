// ============================================================
// QualifiedRefExpressionSessionTests.swift
// AROCLI — qualified refs in arithmetic, end to end (GitLab #496)
// ============================================================
//
// The parser fix (qualified variable references as expression operands)
// only matters if the runtime resolves them the way Extract would. These
// tests run the issue's repro through the same session the REPL and
// `aro repl --json` use, so both interpreter entry points are covered.

import Testing
import Foundation
import ARORuntime
@testable import AROCLI

@Suite("Qualified refs in expressions, live session (#496)", .serialized)
struct QualifiedRefExpressionSessionTests {

    @Test("The issue's repro: <item: qty> * <item: price>")
    func lineTotal() async throws {
        let session = REPLSession()
        _ = try await session.executeStatement(
            "Create the <item> with { qty: 3, price: 4 }.")
        let result = try await session.executeStatement(
            "Compute the <line-total> from <item: qty> * <item: price>.")
        #expect(result.isSuccess)
        #expect(session.getVariable("line-total") as? Int == 12)
    }

    @Test("Qualified ref against a literal")
    func qualifiedTimesLiteral() async throws {
        let session = REPLSession()
        _ = try await session.executeStatement(
            "Create the <item> with { qty: 5 }.")
        let result = try await session.executeStatement(
            "Compute the <doubled> from <item: qty> * 2.")
        #expect(result.isSuccess)
        #expect(session.getVariable("doubled") as? Int == 10)
    }

    @Test("Qualified ref mixed with a bare ref")
    func qualifiedMinusBare() async throws {
        let session = REPLSession()
        _ = try await session.executeStatement(
            "Create the <item> with { price: 100 }.")
        _ = try await session.executeStatement(
            "Create the <discount> with 15.")
        let result = try await session.executeStatement(
            "Compute the <net> from <item: price> - <discount>.")
        #expect(result.isSuccess)
        #expect(session.getVariable("net") as? Int == 85)
    }

    @Test("Nested property path operand")
    func nestedPathOperand() async throws {
        let session = REPLSession()
        _ = try await session.executeStatement(
            "Create the <order> with { customer: { credit: 200 }, total: 50 }.")
        let result = try await session.executeStatement(
            "Compute the <remaining> from <order: customer.credit> - <order: total>.")
        #expect(result.isSuccess)
        #expect(session.getVariable("remaining") as? Int == 150)
    }

    @Test("when guard reads a qualified ref")
    func whenGuardQualified() async throws {
        let session = REPLSession()
        _ = try await session.executeStatement(
            "Create the <record> with { active: true, value: 7 }.")
        let result = try await session.executeStatement(
            "Compute the <picked> from <record: value> * 2 when <record: active>.")
        #expect(result.isSuccess)
        #expect(session.getVariable("picked") as? Int == 14)
    }

    @Test("Extract boilerplate still works (both forms coexist)")
    func extractStillWorks() async throws {
        let session = REPLSession()
        _ = try await session.executeStatement(
            "Create the <item> with { qty: 3, price: 4 }.")
        _ = try await session.executeStatement(
            "Extract the <qty> from the <item: qty>.")
        _ = try await session.executeStatement(
            "Extract the <price> from the <item: price>.")
        let result = try await session.executeStatement(
            "Compute the <total> from <qty> * <price>.")
        #expect(result.isSuccess)
        #expect(session.getVariable("total") as? Int == 12)
    }
}
