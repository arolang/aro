// ============================================================
// SessionTallyTests.swift
// AROAsk — what the harness had to fix (GitLab #878)
// ============================================================

import Testing
import Foundation
@testable import AROAsk

@Suite("Session tally (#878)")
struct SessionTallyTests {

    @Test("A clean run reports no corrections")
    func cleanRunHasNothingToConfess() async {
        let tally = SessionTally()
        await tally.record(turn: true)
        await tally.record(toolCall: true)
        await tally.record(toolCall: true)
        let s = await tally.current()
        #expect(s.turns == 1)
        #expect(s.toolCalls == 2)
        #expect(!s.hadToCorrect)
    }

    /// The question the tally exists to answer: did the harness have to make
    /// up for the model?
    @Test("A retry, a repair or a forced call all count as correcting")
    func correctionsAreVisible() async {
        for setup in [
            { (t: SessionTally) in { await t.recordRetry("no-think") } },
            { (t: SessionTally) in { await t.recordRepair("aro-check") } },
            { (t: SessionTally) in { await t.record(forcedCall: true) } },
        ] {
            let tally = SessionTally()
            await setup(tally)()
            #expect(await tally.current().hadToCorrect)
        }
    }

    @Test("Retries and repairs are counted by cause")
    func causesAreKept() async {
        let tally = SessionTally()
        await tally.recordRetry("no-think")
        await tally.recordRetry("no-think")
        await tally.recordRetry("bail-out")
        await tally.recordRepair("aro-whitespace")
        let s = await tally.current()
        #expect(s.retries == ["no-think": 2, "bail-out": 1])
        #expect(s.repairs == ["aro-whitespace": 1])
    }

    /// A forced call is a recorded admission that asking nicely did not
    /// work, which is exactly what the training pipeline wants to see fall.
    @Test("Forced calls are counted separately")
    func forcedCallsAreCounted() async {
        let tally = SessionTally()
        await tally.record(forcedCall: true)
        await tally.record(forcedCall: true)
        #expect(await tally.current().forcedCalls == 2)
    }

    @Test("The summary names what happened and omits what did not")
    func summaryIsReadable() async {
        let tally = SessionTally()
        await tally.record(turn: true)
        await tally.record(toolCall: true)
        await tally.recordRetry("no-think")
        await tally.recordRepair("aro-check")
        let line = await tally.summary()
        #expect(line.contains("turns 1"))
        #expect(line.contains("tool calls 1"))
        #expect(line.contains("retries 1 (no-think 1)"))
        #expect(line.contains("repairs 1 (aro-check 1)"))
        // Nothing was forced or elided, so neither is mentioned.
        #expect(!line.contains("forced"))
        #expect(!line.contains("elided"))
    }

    @Test("The snapshot survives a round trip, for the training pipeline")
    func snapshotIsCodable() throws {
        var s = SessionTally.Snapshot()
        s.turns = 3
        s.retries = ["no-think": 2]
        s.forcedCalls = 1
        let decoded = try JSONDecoder().decode(
            SessionTally.Snapshot.self, from: try JSONEncoder().encode(s))
        #expect(decoded == s)
    }

    @Test("Compaction and withheld repeats are tallied")
    func contextWorkIsTallied() async {
        let tally = SessionTally()
        await tally.record(compacted: 3, duplicatesWithheld: 5)
        let s = await tally.current()
        #expect(s.resultsCompacted == 3)
        #expect(s.duplicatesWithheld == 5)
        // Neither is a correction — they are the harness doing its job, not
        // making up for the model.
        #expect(!s.hadToCorrect)
    }
}
