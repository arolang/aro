// ============================================================
// MetricsFormatterTests.swift
// ARO Runtime - Metrics Formatter Unit Tests
// ============================================================

import Foundation
import Testing
@testable import ARORuntime

// MARK: - MetricsFormatter Tests

@Suite("MetricsFormatter Tests")
struct MetricsFormatterTests {

    func createTestSnapshot() -> MetricsSnapshot {
        var fs1 = FeatureSetMetrics(name: "Application-Start", businessActivity: "Entry Point")
        fs1.recordExecution(success: true, durationMs: 12.5)

        var fs2 = FeatureSetMetrics(name: "listUsers", businessActivity: "User API")
        fs2.recordExecution(success: true, durationMs: 7.1)
        fs2.recordExecution(success: true, durationMs: 9.5)

        let startTime = Date().addingTimeInterval(-5.2)
        return MetricsSnapshot(
            featureSets: [fs1, fs2],
            collectedAt: Date(),
            applicationStartTime: startTime
        )
    }

    // MARK: - Format Detection

    @Test("Format detection defaults to plain")
    func testFormatDetectionDefault() {
        let snapshot = createTestSnapshot()
        let result = MetricsFormatter.format(snapshot, as: "unknown", context: .human)

        #expect(result.contains("Feature Set Metrics"))
    }

    @Test("Format detection case insensitive")
    func testFormatDetectionCaseInsensitive() {
        let snapshot = createTestSnapshot()

        let plain1 = MetricsFormatter.format(snapshot, as: "PLAIN", context: .human)
        let plain2 = MetricsFormatter.format(snapshot, as: "Plain", context: .human)

        #expect(plain1.contains("Feature Set Metrics"))
        #expect(plain2.contains("Feature Set Metrics"))
    }

    // MARK: - Short Format

    @Test("Short format produces one line")
    func testShortFormatOneLine() {
        let snapshot = createTestSnapshot()
        let result = MetricsFormatter.formatShort(snapshot)

        #expect(!result.contains("\n"))
        #expect(result.hasPrefix("metrics:"))
    }

    @Test("Short format contains key stats")
    func testShortFormatContents() {
        let snapshot = createTestSnapshot()
        let result = MetricsFormatter.formatShort(snapshot)

        #expect(result.contains("3 executions"))
        #expect(result.contains("2 featuresets"))
        #expect(result.contains("avg="))
        #expect(result.contains("uptime="))
    }

    @Test("Short format with empty snapshot")
    func testShortFormatEmpty() {
        let snapshot = MetricsSnapshot(
            featureSets: [],
            collectedAt: Date(),
            applicationStartTime: Date()
        )
        let result = MetricsFormatter.formatShort(snapshot)

        #expect(result.contains("0 executions"))
        #expect(result.contains("0 featuresets"))
    }

    // MARK: - Table Format

    @Test("Table format has header")
    func testTableFormatHeader() {
        let snapshot = createTestSnapshot()
        let result = MetricsFormatter.formatTable(snapshot)

        #expect(result.contains("Feature Set"))
        #expect(result.contains("Count"))
        #expect(result.contains("Success"))
        #expect(result.contains("Failed"))
        #expect(result.contains("Avg(ms)"))
    }

    @Test("Table format has separators")
    func testTableFormatSeparators() {
        let snapshot = createTestSnapshot()
        let result = MetricsFormatter.formatTable(snapshot)

        #expect(result.contains("+"))
        #expect(result.contains("-"))
        #expect(result.contains("|"))
    }

    @Test("Table format has TOTAL row")
    func testTableFormatTotalRow() {
        let snapshot = createTestSnapshot()
        let result = MetricsFormatter.formatTable(snapshot)

        #expect(result.contains("TOTAL"))
    }

    @Test("Table format with empty snapshot")
    func testTableFormatEmpty() {
        let snapshot = MetricsSnapshot(
            featureSets: [],
            collectedAt: Date(),
            applicationStartTime: Date()
        )
        let result = MetricsFormatter.formatTable(snapshot)

        #expect(result.contains("No metrics collected"))
    }

    // MARK: - Plain Format

    @Test("Plain format human context")
    func testPlainFormatHuman() {
        let snapshot = createTestSnapshot()
        let result = MetricsFormatter.formatPlain(snapshot, context: .human)

        #expect(result.contains("Feature Set Metrics"))
        #expect(result.contains("Application-Start"))
        #expect(result.contains("Entry Point"))
        #expect(result.contains("Executions:"))
        #expect(result.contains("Duration:"))
    }

    @Test("Plain format machine context produces JSON")
    func testPlainFormatMachine() {
        let snapshot = createTestSnapshot()
        let result = MetricsFormatter.formatPlain(snapshot, context: .machine)

        #expect(result.hasPrefix("{"))
        #expect(result.hasSuffix("}"))
        #expect(result.contains("\"totalExecutions\""))
        #expect(result.contains("\"featureSets\""))
    }

    @Test("Plain format developer context")
    func testPlainFormatDeveloper() {
        let snapshot = createTestSnapshot()
        let result = MetricsFormatter.formatPlain(snapshot, context: .developer)

        // Developer context uses same text format as human
        #expect(result.contains("Feature Set Metrics"))
    }

    @Test("Plain format with empty snapshot")
    func testPlainFormatEmpty() {
        let snapshot = MetricsSnapshot(
            featureSets: [],
            collectedAt: Date(),
            applicationStartTime: Date()
        )
        let result = MetricsFormatter.formatPlain(snapshot, context: .human)

        #expect(result.contains("No feature sets executed"))
    }

    // MARK: - Prometheus Format

    @Test("Prometheus format has HELP comments")
    func testPrometheusFormatHelp() {
        let snapshot = createTestSnapshot()
        let result = MetricsFormatter.formatPrometheus(snapshot)

        #expect(result.contains("# HELP aro_featureset_executions_total"))
        #expect(result.contains("# HELP aro_featureset_duration_ms_avg"))
        #expect(result.contains("# HELP aro_application_uptime_seconds"))
    }

    @Test("Prometheus format has TYPE comments")
    func testPrometheusFormatType() {
        let snapshot = createTestSnapshot()
        let result = MetricsFormatter.formatPrometheus(snapshot)

        #expect(result.contains("# TYPE aro_featureset_executions_total counter"))
        #expect(result.contains("# TYPE aro_featureset_duration_ms_avg gauge"))
    }

    @Test("Prometheus format has labels")
    func testPrometheusFormatLabels() {
        let snapshot = createTestSnapshot()
        let result = MetricsFormatter.formatPrometheus(snapshot)

        #expect(result.contains("featureset=\"listUsers\""))
        #expect(result.contains("activity=\"User API\""))
    }

    @Test("Prometheus format has metric values")
    func testPrometheusFormatValues() {
        let snapshot = createTestSnapshot()
        let result = MetricsFormatter.formatPrometheus(snapshot)

        // Check that listUsers has 2 executions
        #expect(result.contains("aro_featureset_executions_total{featureset=\"listUsers\",activity=\"User API\"} 2"))
    }

    @Test("Prometheus format with empty snapshot")
    func testPrometheusFormatEmpty() {
        let snapshot = MetricsSnapshot(
            featureSets: [],
            collectedAt: Date(),
            applicationStartTime: Date()
        )
        let result = MetricsFormatter.formatPrometheus(snapshot)

        // Should still have uptime metric
        #expect(result.contains("aro_application_uptime_seconds"))
    }

    @Test("Prometheus label escaping")
    func testPrometheusLabelEscaping() {
        var fs = FeatureSetMetrics(name: "Test\"Feature", businessActivity: "Activity\\Name")
        fs.recordExecution(success: true, durationMs: 1.0)

        let snapshot = MetricsSnapshot(
            featureSets: [fs],
            collectedAt: Date(),
            applicationStartTime: Date()
        )
        let result = MetricsFormatter.formatPrometheus(snapshot)

        // Quotes and backslashes should be escaped
        #expect(result.contains("\\\""))
        #expect(result.contains("\\\\"))
    }
}
