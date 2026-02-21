// ============================================================
// MetricsCollectorTests.swift
// ARO Runtime - Metrics Collector Unit Tests
// ============================================================

import Foundation
import Testing
@testable import ARORuntime

// MARK: - MetricsCollector Tests

@Suite("MetricsCollector Tests")
struct MetricsCollectorTests {

    @Test("Initial snapshot is empty")
    func testInitialSnapshotEmpty() {
        let collector = MetricsCollector()
        let snapshot = collector.snapshot()

        #expect(snapshot.featureSets.isEmpty)
        #expect(snapshot.totalExecutions == 0)
        #expect(snapshot.totalSuccesses == 0)
        #expect(snapshot.totalFailures == 0)
    }

    @Test("Snapshot includes uptime")
    func testSnapshotUptime() async throws {
        let collector = MetricsCollector()

        // Wait a bit
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms

        let snapshot = collector.snapshot()

        #expect(snapshot.uptimeSeconds >= 0.1)
        #expect(snapshot.applicationStartTime <= snapshot.collectedAt)
    }

    @Test("Feature set count updates")
    func testFeatureSetCount() {
        let collector = MetricsCollector()

        #expect(collector.featureSetCount == 0)
    }

    @Test("Reset clears metrics")
    func testReset() {
        let collector = MetricsCollector()
        collector.reset()

        let snapshot = collector.snapshot()
        #expect(snapshot.featureSets.isEmpty)
    }
}

// MARK: - FeatureSetMetrics Tests

@Suite("FeatureSetMetrics Tests")
struct FeatureSetMetricsTests {

    @Test("Initial values are correct")
    func testInitialValues() {
        let metrics = FeatureSetMetrics(name: "TestFeature", businessActivity: "Test Activity")

        #expect(metrics.name == "TestFeature")
        #expect(metrics.businessActivity == "Test Activity")
        #expect(metrics.executionCount == 0)
        #expect(metrics.successCount == 0)
        #expect(metrics.failureCount == 0)
        #expect(metrics.totalDurationMs == 0)
        #expect(metrics.maxDurationMs == 0)
        #expect(metrics.averageDurationMs == 0)
        #expect(metrics.successRate == 0)
    }

    @Test("Record successful execution")
    func testRecordSuccessfulExecution() {
        var metrics = FeatureSetMetrics(name: "Test", businessActivity: "Activity")
        metrics.recordExecution(success: true, durationMs: 10.0)

        #expect(metrics.executionCount == 1)
        #expect(metrics.successCount == 1)
        #expect(metrics.failureCount == 0)
        #expect(metrics.totalDurationMs == 10.0)
        #expect(metrics.averageDurationMs == 10.0)
        #expect(metrics.successRate == 100.0)
    }

    @Test("Record failed execution")
    func testRecordFailedExecution() {
        var metrics = FeatureSetMetrics(name: "Test", businessActivity: "Activity")
        metrics.recordExecution(success: false, durationMs: 5.0)

        #expect(metrics.executionCount == 1)
        #expect(metrics.successCount == 0)
        #expect(metrics.failureCount == 1)
        #expect(metrics.successRate == 0)
    }

    @Test("Average duration calculated correctly")
    func testAverageDuration() {
        var metrics = FeatureSetMetrics(name: "Test", businessActivity: "Activity")
        metrics.recordExecution(success: true, durationMs: 10.0)
        metrics.recordExecution(success: true, durationMs: 20.0)
        metrics.recordExecution(success: true, durationMs: 30.0)

        #expect(metrics.executionCount == 3)
        #expect(metrics.totalDurationMs == 60.0)
        #expect(metrics.averageDurationMs == 20.0)
    }

    @Test("Min and max duration tracked")
    func testMinMaxDuration() {
        var metrics = FeatureSetMetrics(name: "Test", businessActivity: "Activity")
        metrics.recordExecution(success: true, durationMs: 15.0)
        metrics.recordExecution(success: true, durationMs: 5.0)
        metrics.recordExecution(success: true, durationMs: 25.0)

        #expect(metrics.minDurationMs == 5.0)
        #expect(metrics.maxDurationMs == 25.0)
    }

    @Test("Success rate calculation")
    func testSuccessRate() {
        var metrics = FeatureSetMetrics(name: "Test", businessActivity: "Activity")
        metrics.recordExecution(success: true, durationMs: 1.0)
        metrics.recordExecution(success: true, durationMs: 1.0)
        metrics.recordExecution(success: false, durationMs: 1.0)
        metrics.recordExecution(success: true, durationMs: 1.0)

        #expect(metrics.executionCount == 4)
        #expect(metrics.successCount == 3)
        #expect(metrics.failureCount == 1)
        #expect(metrics.successRate == 75.0)
    }
}

// MARK: - MetricsSnapshot Tests

@Suite("MetricsSnapshot Tests")
struct MetricsSnapshotTests {

    func createTestProcessMetrics() -> ProcessMetrics {
        ProcessMetrics(
            cpuUserTime: 0.1,
            cpuSystemTime: 0.05,
            virtualMemoryBytes: 100_000_000,
            residentMemoryBytes: 50_000_000,
            openFileDescriptors: 10,
            maxFileDescriptors: 1024,
            processStartTime: Date().timeIntervalSince1970 - 5.0
        )
    }

    @Test("Empty snapshot totals")
    func testEmptySnapshot() {
        let snapshot = MetricsSnapshot(
            featureSets: [],
            processMetrics: createTestProcessMetrics(),
            collectedAt: Date(),
            applicationStartTime: Date()
        )

        #expect(snapshot.totalExecutions == 0)
        #expect(snapshot.totalSuccesses == 0)
        #expect(snapshot.totalFailures == 0)
        #expect(snapshot.averageDurationMs == 0)
        #expect(snapshot.maxDurationMs == 0)
    }

    @Test("Snapshot totals aggregate correctly")
    func testSnapshotTotals() {
        var fs1 = FeatureSetMetrics(name: "FS1", businessActivity: "Activity1")
        fs1.recordExecution(success: true, durationMs: 10.0)
        fs1.recordExecution(success: false, durationMs: 20.0)

        var fs2 = FeatureSetMetrics(name: "FS2", businessActivity: "Activity2")
        fs2.recordExecution(success: true, durationMs: 30.0)

        let snapshot = MetricsSnapshot(
            featureSets: [fs1, fs2],
            processMetrics: createTestProcessMetrics(),
            collectedAt: Date(),
            applicationStartTime: Date()
        )

        #expect(snapshot.totalExecutions == 3)
        #expect(snapshot.totalSuccesses == 2)
        #expect(snapshot.totalFailures == 1)
        #expect(snapshot.averageDurationMs == 20.0) // (10 + 20 + 30) / 3
        #expect(snapshot.maxDurationMs == 30.0)
    }

    @Test("Uptime calculation")
    func testUptimeCalculation() {
        let startTime = Date()
        let collectedAt = startTime.addingTimeInterval(5.5)

        let snapshot = MetricsSnapshot(
            featureSets: [],
            processMetrics: createTestProcessMetrics(),
            collectedAt: collectedAt,
            applicationStartTime: startTime
        )

        #expect(snapshot.uptimeSeconds == 5.5)
    }
}
