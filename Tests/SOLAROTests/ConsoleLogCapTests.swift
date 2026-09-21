// ============================================================
// ConsoleLogCapTests.swift
// SOLARO — the console's log stays bounded (GitLab #751)
// ============================================================
//
// The cap used to exist because the console rendered its lines in a
// non-lazy `VStack`, so the list was the bottleneck. The list is lazy now
// and the cap is about memory instead — which makes it worth asserting,
// since nothing else stops a verbose run from growing without bound.

import Testing
import Foundation
@testable import SOLARO

@Suite("Console log cap")
@MainActor
struct ConsoleLogCapTests {

    private func entry(_ n: Int) -> ConsoleProcess.LogEntry {
        ConsoleProcess.LogEntry(kind: .stdout, text: "line \(n)",
                                timestamp: Date())
    }

    @Test func keepsEverythingBelowTheCap() {
        let process = ConsoleProcess()
        for n in 0..<100 { process.appendLog(entry(n)) }
        #expect(process.log.count == 100)
        #expect(process.log.first?.text == "line 0")
        #expect(process.log.last?.text == "line 99")
    }

    @Test func dropsTheOldestHalfOnOverflow() {
        let process = ConsoleProcess()
        let cap = ConsoleProcess.logCap
        for n in 0...cap { process.appendLog(entry(n)) }
        // Overflow keeps the newer half, so the log is bounded and each
        // append stays O(1) amortized rather than trimming every time.
        // The trim leaves exactly half the cap: the append that tipped it
        // over made it cap + 1, and it dropped cap + 1 - cap / 2 lines.
        #expect(process.log.count == cap / 2)
        #expect(process.log.last?.text == "line \(cap)")
        // The oldest line is gone; the newest is not.
        #expect(process.log.first?.text != "line 0")
    }

    @Test func theCapIsLargeEnoughToScrollBackThroughAVerboseRun() {
        // The lazy list is what lets this be generous (#751).
        #expect(ConsoleProcess.logCap >= 50_000)
    }
}
