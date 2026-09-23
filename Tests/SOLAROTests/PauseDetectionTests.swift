// ============================================================
// PauseDetectionTests.swift
// SOLARO — the debugger pauses on a record, not an emoji (GitLab #752)
// ============================================================
//
// Pause detection used to be a scrape of the child's stdout: find a `⏸` in
// the line, then `" at "`, then `" — "`, then the integer after the last
// colon between them. The debugger's correctness therefore depended on the
// exact wording and emoji of a human-facing message in a different binary.
// The runtime already writes a structured `pause` record, and that is what
// drives the paused state now.

import Testing
import Foundation
@testable import SOLARO

@Suite("Pause detection")
@MainActor
struct PauseDetectionTests {

    private func pauseRecord(file: String = "main.aro",
                             line: Int) -> TimeTravelRecord {
        TimeTravelRecord(
            time: 1.0, kind: .pause, featureSet: "Application-Start",
            file: file, line: line, column: 5,
            statement: "Log \"hi\" to the <console>.",
            verb: "Log", reason: "step", symbols: []
        )
    }

    @Test func aPauseRecordEntersThePausedState() {
        let process = ConsoleProcess()
        #expect(!process.isPaused)

        process.applyLiveBatch([pauseRecord(line: 12)])

        #expect(process.isPaused)
        #expect(process.pausedLine == 12)
    }

    @Test func aRecordWithoutALineIsNotAPauseLocation() {
        let process = ConsoleProcess()
        let record = TimeTravelRecord(
            time: 1.0, kind: .pause, featureSet: "Application-Start",
            file: "main.aro", line: nil, column: nil,
            statement: nil, verb: nil, reason: "step", symbols: []
        )
        process.applyLiveBatch([record])
        #expect(!process.isPaused)
        #expect(process.pausedLine == nil)
    }

    @Test func nonPauseRecordsDoNotPause() {
        let process = ConsoleProcess()
        let event = TimeTravelRecord(
            time: 1.0, kind: .event, featureSet: "Application-Start",
            file: "main.aro", line: 7, column: 1,
            statement: nil, verb: nil, reason: nil, symbols: []
        )
        process.applyLiveBatch([event])
        #expect(!process.isPaused)
    }

    @Test func theLastPauseInABatchWins() {
        // A drain can carry several records; the program is stopped
        // wherever the newest one says it is.
        let process = ConsoleProcess()
        process.applyLiveBatch([pauseRecord(line: 3), pauseRecord(line: 9)])
        #expect(process.pausedLine == 9)
    }
}
