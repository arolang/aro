// ============================================================
// DiagnosticsTests.swift
// SOLARO — failures that used to vanish (GitLab #755)
// ============================================================

import Testing
import Foundation
@testable import SOLARO

@Suite("Diagnostics", .serialized)
@MainActor
struct DiagnosticsTests {

    private struct DiskFull: Error {}

    @Test func aReportedFailureBecomesTheLatestWarning() {
        let diagnostics = SolaroDiagnostics.shared
        diagnostics.dismiss()
        #expect(diagnostics.latest == nil)

        diagnostics.report("the canvas layout", error: DiskFull())

        // The status bar reads this, so the user learns the app could
        // not write something instead of quietly losing it.
        #expect(diagnostics.latest != nil)
        #expect(diagnostics.latest?.message.contains("canvas layout") == true)
        diagnostics.dismiss()
    }

    @Test func dismissingClearsIt() {
        let diagnostics = SolaroDiagnostics.shared
        diagnostics.report("the recent projects list", error: DiskFull())
        diagnostics.dismiss()
        #expect(diagnostics.latest == nil)
    }

    @Test func aNewerFailureReplacesTheOlderOne() {
        let diagnostics = SolaroDiagnostics.shared
        diagnostics.report("the canvas layout", error: DiskFull())
        diagnostics.report("the recent projects list", error: DiskFull())
        #expect(diagnostics.latest?.message.contains("recent projects") == true)
        diagnostics.dismiss()
    }

    @Test func aFailureFromOffTheMainActorArrives() async throws {
        let diagnostics = SolaroDiagnostics.shared
        diagnostics.dismiss()
        // Several of these happen in plain static helpers with no actor.
        await Task.detached {
            SolaroDiagnostics.warn("the recent projects list",
                                   error: DiskFull())
        }.value
        for _ in 0..<50 where diagnostics.latest == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(diagnostics.latest?.message.contains("recent projects") == true)
        diagnostics.dismiss()
    }
}
