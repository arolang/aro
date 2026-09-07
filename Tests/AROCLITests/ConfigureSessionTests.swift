// ============================================================
// ConfigureSessionTests.swift
// AROCLI — Configure semantics per ARO-0035 (GitLab #506)
// ============================================================

import Testing
import Foundation
import ARORuntime
@testable import AROCLI

@Suite("Configure semantics", .serialized)
struct ConfigureSessionTests {

    @Test("A category takes multiple Configure statements, merging settings")
    func repeatedConfigure() async throws {
        let session = REPLSession(suppressLogPrefix: true)
        let first = try await session.executeStatement(
            "Configure the <http-client: timeout> with 30.")
        let second = try await session.executeStatement(
            "Configure the <http-client: retries> with 3.")
        #expect(first.isSuccess)
        #expect(second.isSuccess)

        _ = try await session.executeStatement(
            "Extract the <t> from the <http-client: timeout>.")
        _ = try await session.executeStatement(
            "Extract the <r> from the <http-client: retries>.")
        #expect("\(session.getVariable("t") ?? "nil")" == "30")
        #expect("\(session.getVariable("r") ?? "nil")" == "3")
    }

    @Test("Reading an UNSET setting on a configured category answers nil (§3.2)")
    func unsetSettingIsNil() async throws {
        let session = REPLSession(suppressLogPrefix: true)
        _ = try await session.executeStatement(
            "Configure the <http-client: timeout> with 30.")

        // The documented idiom must work end to end.
        let result = try await session.executeStatement("""
            Extract the <proxy> from the <http-client: proxy>.
            Create the <effective-proxy> with "none" when <proxy> = nil.
            """)
        #expect(result.isSuccess)
        #expect(session.getVariable("effective-proxy") as? String == "none")

        // And the != nil side.
        let set = try await session.executeStatement("""
            Extract the <t2> from the <http-client: timeout>.
            Create the <have-timeout> with true when <t2> != nil.
            """)
        #expect(set.isSuccess)
        #expect(session.getVariable("have-timeout") as? Bool == true)
    }

    @Test("Data records keep the happy-path error for missing fields")
    func dataRecordsStillError() async throws {
        let session = REPLSession(suppressLogPrefix: true)
        _ = try await session.executeStatement(
            "Create the <order> with { id: 7 }.")
        let result = try await session.executeStatement(
            "Extract the <missing> from the <order: total>.")
        guard case .error(let message) = result else {
            Issue.record("expected the happy-path error, got \(result)")
            return
        }
        #expect(message.contains("total") || message.contains("extract"))
    }

    @Test("An unconfigured category still errors on any read")
    func unconfiguredCategoryErrors() async throws {
        let session = REPLSession(suppressLogPrefix: true)
        let result = try await session.executeStatement(
            "Extract the <x> from the <never-configured: setting>.")
        #expect(!result.isSuccess)
    }
}
