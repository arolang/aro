// ============================================================
// MetricsFormatter.swift
// ARO Runtime - Metrics Output Formatting
// ============================================================

import Foundation

/// Formats metrics snapshots into various output formats
public struct MetricsFormatter: Sendable {
    /// Available output formats
    public enum Format: String, Sendable {
        case plain
        case short
        case table
        case prometheus
    }

    /// Format metrics using the specified format
    /// - Parameters:
    ///   - snapshot: The metrics snapshot to format
    ///   - format: Output format (plain, short, table, prometheus)
    ///   - context: Output context for context-aware formatting
    /// - Returns: Formatted string
    public static func format(
        _ snapshot: MetricsSnapshot,
        as format: String,
        context: OutputContext = .human
    ) -> String {
        let formatEnum = Format(rawValue: format.lowercased()) ?? .plain

        switch formatEnum {
        case .plain:
            return formatPlain(snapshot, context: context)
        case .short:
            return formatShort(snapshot)
        case .table:
            return formatTable(snapshot)
        case .prometheus:
            return formatPrometheus(snapshot)
        }
    }

    // MARK: - Plain Format

    /// Format as detailed multi-line output (context-aware)
    public static func formatPlain(_ snapshot: MetricsSnapshot, context: OutputContext) -> String {
        switch context {
        case .machine:
            return formatPlainJSON(snapshot)
        case .human, .developer:
            return formatPlainText(snapshot)
        }
    }

    private static func formatPlainText(_ snapshot: MetricsSnapshot) -> String {
        var lines: [String] = []

        let uptimeStr = String(format: "%.1fs", snapshot.uptimeSeconds)
        lines.append("Feature Set Metrics (\(snapshot.totalExecutions) total executions, uptime: \(uptimeStr))")
        lines.append("")

        if snapshot.featureSets.isEmpty {
            lines.append("No feature sets executed yet.")
        } else {
            for fs in snapshot.featureSets {
                lines.append("\(fs.name) (\(fs.businessActivity))")
                lines.append("  Executions: \(fs.executionCount) (success: \(fs.successCount), failed: \(fs.failureCount))")

                let avgStr = String(format: "%.1fms", fs.averageDurationMs)
                let minStr = fs.minDurationMs.isFinite ? String(format: "%.1fms", fs.minDurationMs) : "N/A"
                let maxStr = String(format: "%.1fms", fs.maxDurationMs)
                lines.append("  Duration: avg=\(avgStr), min=\(minStr), max=\(maxStr)")
                lines.append("")
            }
        }

        return lines.joined(separator: "\n")
    }

    private static func formatPlainJSON(_ snapshot: MetricsSnapshot) -> String {
        var dict: [String: Any] = [
            "totalExecutions": snapshot.totalExecutions,
            "totalSuccesses": snapshot.totalSuccesses,
            "totalFailures": snapshot.totalFailures,
            "uptimeSeconds": snapshot.uptimeSeconds,
            "collectedAt": ISO8601DateFormatter().string(from: snapshot.collectedAt)
        ]

        var featureSetsArray: [[String: Any]] = []
        for fs in snapshot.featureSets {
            featureSetsArray.append([
                "name": fs.name,
                "businessActivity": fs.businessActivity,
                "executionCount": fs.executionCount,
                "successCount": fs.successCount,
                "failureCount": fs.failureCount,
                "averageDurationMs": fs.averageDurationMs,
                "minDurationMs": fs.minDurationMs.isFinite ? fs.minDurationMs : 0,
                "maxDurationMs": fs.maxDurationMs
            ])
        }
        dict["featureSets"] = featureSetsArray

        if let jsonData = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            return jsonString
        }
        return "{}"
    }

    // MARK: - Short Format

    /// Format as a single-line summary
    public static func formatShort(_ snapshot: MetricsSnapshot) -> String {
        let executions = snapshot.totalExecutions
        let featuresets = snapshot.featureSets.count
        let avgMs = String(format: "%.1fms", snapshot.averageDurationMs)
        let uptime = String(format: "%.1fs", snapshot.uptimeSeconds)

        return "metrics: \(executions) executions, \(featuresets) featuresets, avg=\(avgMs), uptime=\(uptime)"
    }

    // MARK: - Table Format

    /// Format as an ASCII table
    public static func formatTable(_ snapshot: MetricsSnapshot) -> String {
        if snapshot.featureSets.isEmpty {
            return "No metrics collected yet."
        }

        // Calculate column widths
        let nameWidth = max(13, snapshot.featureSets.map { $0.name.count }.max() ?? 13)
        let countWidth = 7
        let successWidth = 9
        let failedWidth = 8
        let avgWidth = 9
        let maxWidth = 9

        var lines: [String] = []

        // Header separator
        let separator = "+" + String(repeating: "-", count: nameWidth + 2) +
                       "+" + String(repeating: "-", count: countWidth + 2) +
                       "+" + String(repeating: "-", count: successWidth + 2) +
                       "+" + String(repeating: "-", count: failedWidth + 2) +
                       "+" + String(repeating: "-", count: avgWidth + 2) +
                       "+" + String(repeating: "-", count: maxWidth + 2) + "+"

        lines.append(separator)

        // Header
        lines.append("| " + "Feature Set".padding(toLength: nameWidth, withPad: " ", startingAt: 0) +
                    " | " + "Count".padding(toLength: countWidth, withPad: " ", startingAt: 0) +
                    " | " + "Success".padding(toLength: successWidth, withPad: " ", startingAt: 0) +
                    " | " + "Failed".padding(toLength: failedWidth, withPad: " ", startingAt: 0) +
                    " | " + "Avg(ms)".padding(toLength: avgWidth, withPad: " ", startingAt: 0) +
                    " | " + "Max(ms)".padding(toLength: maxWidth, withPad: " ", startingAt: 0) + " |")

        lines.append(separator)

        // Data rows
        for fs in snapshot.featureSets {
            let name = fs.name.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
            let count = String(fs.executionCount).leftPadded(toLength: countWidth)
            let success = String(fs.successCount).leftPadded(toLength: successWidth)
            let failed = String(fs.failureCount).leftPadded(toLength: failedWidth)
            let avg = String(format: "%.\(2)f", fs.averageDurationMs).leftPadded(toLength: avgWidth)
            let maxVal = String(format: "%.\(2)f", fs.maxDurationMs).leftPadded(toLength: maxWidth)

            lines.append("| \(name) | \(count) | \(success) | \(failed) | \(avg) | \(maxVal) |")
        }

        lines.append(separator)

        // Total row
        let totalName = "TOTAL".padding(toLength: nameWidth, withPad: " ", startingAt: 0)
        let totalCount = String(snapshot.totalExecutions).leftPadded(toLength: countWidth)
        let totalSuccess = String(snapshot.totalSuccesses).leftPadded(toLength: successWidth)
        let totalFailed = String(snapshot.totalFailures).leftPadded(toLength: failedWidth)
        let totalAvg = String(format: "%.\(2)f", snapshot.averageDurationMs).leftPadded(toLength: avgWidth)
        let totalMax = String(format: "%.\(2)f", snapshot.maxDurationMs).leftPadded(toLength: maxWidth)

        lines.append("| \(totalName) | \(totalCount) | \(totalSuccess) | \(totalFailed) | \(totalAvg) | \(totalMax) |")
        lines.append(separator)

        return lines.joined(separator: "\n")
    }

    // MARK: - Prometheus Format

    /// Format as Prometheus text format
    public static func formatPrometheus(_ snapshot: MetricsSnapshot) -> String {
        var lines: [String] = []

        // Executions total
        lines.append("# HELP aro_featureset_executions_total Total number of feature set executions")
        lines.append("# TYPE aro_featureset_executions_total counter")
        for fs in snapshot.featureSets {
            let labels = prometheusLabels(fs)
            lines.append("aro_featureset_executions_total{\(labels)} \(fs.executionCount)")
        }
        lines.append("")

        // Success total
        lines.append("# HELP aro_featureset_success_total Total successful executions")
        lines.append("# TYPE aro_featureset_success_total counter")
        for fs in snapshot.featureSets {
            let labels = prometheusLabels(fs)
            lines.append("aro_featureset_success_total{\(labels)} \(fs.successCount)")
        }
        lines.append("")

        // Failures total
        lines.append("# HELP aro_featureset_failures_total Total failed executions")
        lines.append("# TYPE aro_featureset_failures_total counter")
        for fs in snapshot.featureSets {
            let labels = prometheusLabels(fs)
            lines.append("aro_featureset_failures_total{\(labels)} \(fs.failureCount)")
        }
        lines.append("")

        // Average duration
        lines.append("# HELP aro_featureset_duration_ms_avg Average execution duration in milliseconds")
        lines.append("# TYPE aro_featureset_duration_ms_avg gauge")
        for fs in snapshot.featureSets {
            let labels = prometheusLabels(fs)
            lines.append("aro_featureset_duration_ms_avg{\(labels)} \(String(format: "%.2f", fs.averageDurationMs))")
        }
        lines.append("")

        // Max duration
        lines.append("# HELP aro_featureset_duration_ms_max Maximum execution duration in milliseconds")
        lines.append("# TYPE aro_featureset_duration_ms_max gauge")
        for fs in snapshot.featureSets {
            let labels = prometheusLabels(fs)
            lines.append("aro_featureset_duration_ms_max{\(labels)} \(String(format: "%.2f", fs.maxDurationMs))")
        }
        lines.append("")

        // Min duration
        lines.append("# HELP aro_featureset_duration_ms_min Minimum execution duration in milliseconds")
        lines.append("# TYPE aro_featureset_duration_ms_min gauge")
        for fs in snapshot.featureSets {
            let labels = prometheusLabels(fs)
            let minVal = fs.minDurationMs.isFinite ? fs.minDurationMs : 0
            lines.append("aro_featureset_duration_ms_min{\(labels)} \(String(format: "%.2f", minVal))")
        }
        lines.append("")

        // Application uptime
        lines.append("# HELP aro_application_uptime_seconds Application uptime in seconds")
        lines.append("# TYPE aro_application_uptime_seconds gauge")
        lines.append("aro_application_uptime_seconds \(String(format: "%.2f", snapshot.uptimeSeconds))")

        return lines.joined(separator: "\n")
    }

    private static func prometheusLabels(_ fs: FeatureSetMetrics) -> String {
        let escapedName = escapePrometheusLabel(fs.name)
        let escapedActivity = escapePrometheusLabel(fs.businessActivity)
        return "featureset=\"\(escapedName)\",activity=\"\(escapedActivity)\""
    }

    private static func escapePrometheusLabel(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}

// MARK: - String Extension

private extension String {
    func leftPadded(toLength length: Int) -> String {
        if count >= length {
            return self
        }
        return String(repeating: " ", count: length - count) + self
    }
}
