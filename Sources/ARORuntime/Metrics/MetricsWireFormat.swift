// ============================================================
// MetricsWireFormat.swift
// ARO Runtime - Push-socket snapshot encoding
// ============================================================
//
// JSON shape consumed by SOLARO's MetricsPanel over the
// `$TMPDIR/aro-metrics-<pid>.sock` Unix socket. Kept separate
// from MetricsFormatter (which targets CLI/Prometheus output)
// so that wire compatibility evolves on its own cadence.

import Foundation

enum MetricsWireFormat {
    /// Discriminator carried on every snapshot so clients can
    /// detect breaking schema changes without sniffing fields.
    static let kind = "metrics-snapshot.v1"

    /// Encode a snapshot into a single line of UTF-8 JSON
    /// (no trailing newline — the socket server adds it).
    static func encode(_ snap: MetricsSnapshot) -> Data {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var featureSets: [[String: Any]] = []
        featureSets.reserveCapacity(snap.featureSets.count)
        for fs in snap.featureSets {
            let minMs = fs.minDurationMs.isFinite ? fs.minDurationMs : 0
            featureSets.append([
                "name": fs.name,
                "businessActivity": fs.businessActivity,
                "count": fs.executionCount,
                "successes": fs.successCount,
                "failures": fs.failureCount,
                "totalMs": fs.totalDurationMs,
                "minMs": minMs,
                "maxMs": fs.maxDurationMs,
                "avgMs": fs.averageDurationMs,
                "successRate": fs.successRate
            ])
        }

        let pm = snap.processMetrics
        let process: [String: Any] = [
            "cpuUserSec": pm.cpuUserTime,
            "cpuSystemSec": pm.cpuSystemTime,
            "virtualMB": pm.virtualMemoryMB,
            "residentMB": pm.residentMemoryMB,
            "openFDs": pm.openFileDescriptors
        ]

        let payload: [String: Any] = [
            "kind": kind,
            "collectedAt": iso.string(from: snap.collectedAt),
            "uptimeSec": snap.uptimeSeconds,
            "totalExecutions": snap.totalExecutions,
            "totalSuccesses": snap.totalSuccesses,
            "totalFailures": snap.totalFailures,
            "featureSets": featureSets,
            "process": process
        ]

        // `.sortedKeys` keeps wire bytes deterministic, which
        // makes diffs and snapshot tests stable.
        if let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys]
        ) {
            return data
        }
        return Data("{}".utf8)
    }
}
