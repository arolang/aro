// ============================================================
// DiagnosticHeadlineTests.swift
// AROCLI — the REPL's error headline names the root cause (#509)
// ============================================================
//
// `aro repl --json` (and the Jupyter kernel on top of it) turn the
// session's error message into ename/evalue/traceback, where evalue
// is the FIRST LINE. Before GitLab #509 that first line was
// "Variable 'x' is defined but never used" or "Feature set
// '_repl_temp_' has no Return or Throw statement" — fallout of the
// failed statement — while "Unknown Compute qualifier 'sparkle'"
// sat lower in the block. The notebook showed the noise.

import Testing
import Foundation
import ARORuntime
@testable import AROCLI

@Suite("REPL diagnostic headline (#509)", .serialized)
struct DiagnosticHeadlineTests {

    @Test("Unknown qualifier is the first line of the session error")
    func unknownQualifierIsHeadline() async throws {
        let session = REPLSession(suppressLogPrefix: true)
        _ = try await session.executeStatement("Create the <y> with \"text\".")
        let result = try await session.executeStatement(
            "Compute the <x: sparkle> from <y>.")

        guard case .error(let message) = result else {
            Issue.record("expected an error, got \(result)")
            return
        }

        let firstLine = message.split(separator: "\n").first.map(String.init) ?? ""
        #expect(firstLine.contains("Unknown Compute qualifier 'sparkle'"))
        #expect(!firstLine.contains("has no Return or Throw"))
        #expect(!firstLine.contains("is defined but never used"))
    }
}
