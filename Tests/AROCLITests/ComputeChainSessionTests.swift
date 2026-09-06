// ============================================================
// ComputeChainSessionTests.swift
// AROCLI — qualifier chains through a live session (GitLab #492)
// ============================================================
//
// ARO-0019 §3.3 names chains (`a|b`) as one of the four valid
// qualifier forms, and `aro check` accepted them — but the runtime
// handed the whole string to the plugin registry's resolveChain,
// which knows nothing about built-ins, so `trim|uppercase` died
// with "Unknown Compute qualifier: 'trim|uppercase'" at the worst
// possible time. These tests run the documented forms end to end
// through the same session the REPL and `aro repl --json` use.

import Testing
import Foundation
import ARORuntime
@testable import AROCLI

@Suite("Compute qualifier chains in a session (#492)", .serialized)
struct ComputeChainSessionTests {

    @Test("trim|uppercase applies left to right")
    func trimUppercase() async throws {
        let session = REPLSession(suppressLogPrefix: true)
        _ = try await session.executeStatement("Create the <t> with \"  hi  \".")
        let result = try await session.executeStatement(
            "Compute the <clean: trim|uppercase> from <t>.")
        #expect(result.isSuccess)
        #expect(session.getVariable("clean") as? String == "HI")
    }

    @Test("lines|length counts lines in one statement")
    func linesLength() async throws {
        // The chain observed failing in the wild: "Unknown Compute
        // qualifier: 'lines|length'".
        let session = REPLSession(suppressLogPrefix: true)
        _ = try await session.executeStatement(
            "Create the <content> with \"one\\ntwo\\nthree\\n\".")
        let result = try await session.executeStatement(
            "Compute the <n: lines|length> from <content>.")
        #expect(result.isSuccess)
        #expect(session.getVariable("n") as? Int == 3)
    }

    @Test("An unknown stage errors naming the stage, with the chain")
    func unknownStage() async throws {
        let session = REPLSession(suppressLogPrefix: true)
        _ = try await session.executeStatement("Create the <t> with \"  hi  \".")
        let result = try await session.executeStatement(
            "Compute the <clean: trim|bogus> from <t>.")
        guard case .error(let message) = result else {
            Issue.record("expected an error, got \(result)")
            return
        }
        #expect(message.contains("bogus"))
        #expect(message.contains("trim|bogus"))
    }
}
