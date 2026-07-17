// ============================================================
// MetricsRunHistoryTests.swift
// SOLARO — per-run metrics buckets + navigation (#375)
// ============================================================

import Foundation
import Testing
@testable import SOLARO

@Suite("MetricsRunHistory")
@MainActor
struct MetricsRunHistoryTests {

    private func snapshot(
        uptime: Double,
        executions: Int,
        cpuUser: Double = 0.1,
        residentMB: Double = 42
    ) -> MetricsSnapshot {
        MetricsSnapshot(
            kind: "embedded",
            collectedAt: "2026-07-17T00:00:00Z",
            uptimeSec: uptime,
            totalExecutions: executions,
            totalSuccesses: executions,
            totalFailures: 0,
            featureSets: [],
            process: ProcessMetricsView(
                cpuUserSec: cpuUser,
                cpuSystemSec: 0,
                virtualMB: 100,
                residentMB: residentMB,
                openFDs: 8
            )
        )
    }

    @Test func beginRunOpensFreshEmptyBucket() {
        let history = MetricsRunHistory()
        history.beginRun()
        history.ingest(snapshot(uptime: 1, executions: 5))
        history.ingest(snapshot(uptime: 2, executions: 9))
        #expect(history.displayedRun?.samples.count == 1)

        history.beginRun()
        // The new run displays immediately and starts empty.
        #expect(history.displayedRun?.id == 2)
        #expect(history.displayedRun?.samples.isEmpty == true)
        #expect(history.displayedRun?.lastSnapshot == nil)
        // The previous run is preserved, not discarded.
        #expect(history.runs.count == 2)
        #expect(history.runs[0].samples.count == 1)
    }

    @Test func firstSnapshotOnlyEstablishesBaseline() {
        let history = MetricsRunHistory()
        history.beginRun()
        history.ingest(snapshot(uptime: 1, executions: 5))
        #expect(history.displayedRun?.samples.isEmpty == true)
        // …but the cards still have data to show.
        #expect(history.displayedRun?.lastSnapshot?.totalExecutions == 5)
    }

    @Test func deltaMathBetweenConsecutiveSnapshots() throws {
        let history = MetricsRunHistory()
        history.beginRun()
        history.ingest(snapshot(uptime: 1, executions: 10, cpuUser: 0.1))
        history.ingest(snapshot(uptime: 3, executions: 20, cpuUser: 0.5))
        let sample = try #require(history.displayedRun?.samples.first)
        // 10 executions over 2 s.
        #expect(abs(sample.callsPerSec - 5.0) < 0.001)
        // 0.4 CPU-sec over 2 wall-sec = 20%.
        #expect(abs(sample.cpuPercent - 20.0) < 0.001)
    }

    @Test func identicalConsecutiveSnapshotsAreSkipped() {
        let history = MetricsRunHistory()
        history.beginRun()
        let frozen = snapshot(uptime: 2, executions: 7)
        history.ingest(snapshot(uptime: 1, executions: 3))
        history.ingest(frozen)
        history.ingest(frozen)
        history.ingest(frozen)
        #expect(history.displayedRun?.samples.count == 1)
    }

    @Test func staleSnapshotFromPreviousRunStaysOutOfNewBucket() {
        let history = MetricsRunHistory()
        history.beginRun()
        let lastOfRun1 = snapshot(uptime: 5, executions: 50)
        history.ingest(snapshot(uptime: 1, executions: 10))
        history.ingest(lastOfRun1)

        history.beginRun()
        // The upstream cache can replay the previous run's frozen
        // snapshot for one refresh tick after Run is pressed.
        history.ingest(lastOfRun1)
        #expect(history.displayedRun?.lastSnapshot == nil)
        #expect(history.displayedRun?.samples.isEmpty == true)
    }

    @Test func navigationStepsAndBoundaries() {
        let history = MetricsRunHistory()
        for i in 1...3 {
            history.beginRun()
            history.ingest(snapshot(uptime: 1, executions: i))
            history.ingest(snapshot(uptime: 2, executions: i * 2))
        }
        #expect(history.displayedPosition?.index == 3)
        #expect(history.displayedPosition?.total == 3)
        #expect(history.isAtLatest)
        #expect(!history.canGoForward)
        #expect(history.canGoBack)

        history.goBack()
        #expect(history.displayedPosition?.index == 2)
        history.goBack()
        #expect(history.displayedPosition?.index == 1)
        #expect(!history.canGoBack)
        history.goBack() // no-op at the boundary
        #expect(history.displayedPosition?.index == 1)

        history.goForward()
        #expect(history.displayedPosition?.index == 2)
        history.goForward()
        #expect(history.displayedPosition?.index == 3)
        #expect(history.isAtLatest)
        history.goForward() // no-op at the boundary
        #expect(history.displayedPosition?.index == 3)
    }

    @Test func jumpToLatestFromDeepInHistory() {
        let history = MetricsRunHistory()
        for _ in 1...5 { history.beginRun() }
        history.goBack()
        history.goBack()
        history.goBack()
        #expect(history.displayedPosition?.index == 2)
        history.jumpToLatest()
        #expect(history.displayedPosition?.index == 5)
        #expect(history.isAtLatest)
    }

    @Test func forwardToNewestResumesFollowingLive() {
        let history = MetricsRunHistory()
        history.beginRun()
        history.beginRun()
        history.goBack()
        history.goForward()
        #expect(history.isAtLatest)
        // A new run must auto-display without pressing ▸ again.
        history.beginRun()
        #expect(history.displayedRun?.id == 3)
    }

    @Test func depthCapDropsOldestRuns() {
        let history = MetricsRunHistory()
        history.depthProvider = { 3 }
        for _ in 1...5 { history.beginRun() }
        #expect(history.runs.count == 3)
        #expect(history.runs.map(\.id) == [3, 4, 5])
        // Run ids stay monotonic across trimming.
        history.beginRun()
        #expect(history.runs.map(\.id) == [4, 5, 6])
    }

    @Test func selectionFallsBackToLatestWhenSelectedRunIsTrimmed() {
        let history = MetricsRunHistory()
        history.depthProvider = { 2 }
        history.beginRun()
        history.beginRun()
        history.goBack() // select run 1
        #expect(history.displayedRun?.id == 1)
        history.beginRun() // trims run 1
        #expect(history.displayedRun?.id == 3)
        #expect(history.isAtLatest)
    }

    @Test func newRunJumpsSelectionToLatest() {
        let history = MetricsRunHistory()
        history.beginRun()
        history.beginRun()
        history.goBack()
        #expect(history.displayedRun?.id == 1)
        history.beginRun()
        #expect(history.displayedRun?.id == 3)
    }

    @Test func samplesPerRunAreCapped() {
        let history = MetricsRunHistory()
        history.beginRun()
        for i in 0...(MetricsRunHistory.maxSamplesPerRun + 10) {
            history.ingest(snapshot(uptime: Double(i + 1),
                                    executions: i * 2))
        }
        #expect(history.displayedRun?.samples.count
                == MetricsRunHistory.maxSamplesPerRun)
    }

    @Test func ingestBeforeAnyRunOpensImplicitBucket() {
        let history = MetricsRunHistory()
        history.ingest(snapshot(uptime: 1, executions: 1))
        #expect(history.runs.count == 1)
        #expect(history.displayedRun?.lastSnapshot?.totalExecutions == 1)
    }
}
