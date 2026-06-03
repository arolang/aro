// ============================================================
// MetricsPanel.swift
// SOLARO — right-rail tab showing live ARO runtime metrics
// ============================================================
//
// Renders snapshots streamed by `MetricsClient` from the aro
// subprocess's `$TMPDIR/aro-metrics-<pid>.sock`. When the process
// is idle the panel shows a quiet empty state; when it's running
// the panel shows uptime, totals, a per-featureset table, and a
// process resource block (CPU/memory/FDs). Refreshes ~2× a second.

import SwiftUI

struct MetricsPanel: View {
    let process: ConsoleProcess
    @State private var client = MetricsClient()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SolaroSpace.m) {
                header
                if let snap = client.latest {
                    summaryCard(snap: snap)
                    featureSetsCard(snap: snap)
                    processCard(snap: snap)
                } else {
                    emptyState
                }
                Spacer(minLength: SolaroSpace.l)
            }
            .padding(.horizontal, SolaroSpace.m)
            .padding(.top, SolaroSpace.m)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SolaroColor.surface)
        // Disable implicit animations on the entire subtree. Without
        // this, the per-snapshot re-render bubbles transition
        // animations up to the right-rail HSplitView's hosting view,
        // which on macOS 26 hard-asserts when a hosting view
        // invalidates constraints mid-layout (SIGABRT in
        // SplitViewChildController.hostingView).
        .transaction { $0.animation = nil }
        .onAppear { sync(state: process.state) }
        .onChange(of: process.state) { _, newState in sync(state: newState) }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: SolaroSpace.xs) {
            HStack(spacing: SolaroSpace.s) {
                Text("METRICS")
                    .font(SolaroFont.sectionTitle)
                    .foregroundStyle(SolaroColor.textSecondary)
                    .tracking(2)
                Spacer()
                heartbeat
            }
            connectionLine
        }
    }

    /// Static state indicator — colour reflects connection state.
    /// Previously this flashed on every snapshot via a 150ms async
    /// flip + `.animation()`, but the resulting cascade of re-renders
    /// inside the right-rail HSplitView triggered macOS 26's
    /// constraint-update assertion (SIGABRT in
    /// `SplitViewChildController.hostingView(_:didUpdateMinSize:…)`).
    /// A non-animated dot conveys the same "live" signal — the
    /// connection line below already says `streaming · N snapshots`.
    @ViewBuilder
    private var heartbeat: some View {
        Circle()
            .fill(heartbeatColor)
            .frame(width: 6, height: 6)
    }

    private var heartbeatColor: Color {
        switch client.connectionState {
        case .streaming:           return SolaroColor.stateOK
        case .connecting:          return SolaroColor.stateWarn
        case .disconnected, .idle: return SolaroColor.textTertiary
        }
    }

    private var connectionLine: some View {
        HStack(spacing: SolaroSpace.xs) {
            Image(systemName: connectionSymbol)
                .font(.system(size: 10, weight: .medium))
            Text(connectionLabel)
                .font(SolaroFont.caption)
        }
        .foregroundStyle(connectionForeground)
    }

    private var connectionSymbol: String {
        switch client.connectionState {
        case .streaming:    return "dot.radiowaves.left.and.right"
        case .connecting:   return "hourglass"
        case .disconnected: return "antenna.radiowaves.left.and.right.slash"
        case .idle:         return "moon.zzz"
        }
    }

    private var connectionLabel: String {
        switch client.connectionState {
        case .streaming:
            return "streaming"
        case .connecting:
            return "connecting to aro…"
        case .disconnected(let reason):
            return "disconnected · \(reason)"
        case .idle:
            return "idle — press Run to start"
        }
    }

    private var connectionForeground: Color {
        switch client.connectionState {
        case .streaming:    return SolaroColor.textSecondary
        case .connecting:   return SolaroColor.stateWarn
        case .disconnected: return SolaroColor.textTertiary
        case .idle:         return SolaroColor.textTertiary
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: SolaroSpace.s) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(SolaroColor.textTertiary)
            Text("No metrics yet.")
                .font(SolaroFont.body)
                .foregroundStyle(SolaroColor.textPrimary)
            Text("Run the application to see feature-set execution counts, per-call timings, and process CPU/memory in real time.")
                .font(SolaroFont.caption)
                .foregroundStyle(SolaroColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(SolaroSpace.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .solaroCard()
    }

    // MARK: - Summary card

    private func summaryCard(snap: MetricsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: SolaroSpace.s) {
            Text("Summary")
                .font(SolaroFont.bodyBold)
                .foregroundStyle(SolaroColor.textPrimary)
            HStack(alignment: .top, spacing: SolaroSpace.m) {
                metricCell(label: "Uptime",
                           value: formatUptime(snap.uptimeSec))
                metricCell(label: "Executions",
                           value: "\(snap.totalExecutions)")
                metricCell(label: "Success",
                           value: snap.totalExecutions == 0
                               ? "—"
                               : String(format: "%.1f%%", snap.successRate),
                           valueColor: successColor(snap.successRate,
                                                    hasData: snap.totalExecutions > 0))
            }
            if snap.totalFailures > 0 {
                HStack(spacing: SolaroSpace.xs) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(SolaroColor.stateWarn)
                    Text("\(snap.totalFailures) failed execution\(snap.totalFailures == 1 ? "" : "s")")
                        .font(SolaroFont.caption)
                        .foregroundStyle(SolaroColor.textSecondary)
                }
            }
        }
        .padding(SolaroSpace.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .solaroCard()
    }

    private func metricCell(label: String,
                            value: String,
                            valueColor: Color = SolaroColor.textPrimary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(SolaroFont.caption)
                .tracking(1)
                .foregroundStyle(SolaroColor.textTertiary)
            Text(value)
                .font(SolaroFont.mono)
                .foregroundStyle(valueColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Feature-set table

    private func featureSetsCard(snap: MetricsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: SolaroSpace.s) {
            HStack {
                Text("Feature sets")
                    .font(SolaroFont.bodyBold)
                    .foregroundStyle(SolaroColor.textPrimary)
                Spacer()
                Text("\(snap.featureSets.count)")
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(SolaroColor.textTertiary)
            }
            if snap.featureSets.isEmpty {
                Text("Waiting for first feature-set execution…")
                    .font(SolaroFont.caption)
                    .foregroundStyle(SolaroColor.textTertiary)
            } else {
                featureSetsHeader
                Divider().background(SolaroColor.divider)
                ForEach(snap.featureSets.sorted { $0.count > $1.count }) { fs in
                    featureSetRow(fs)
                }
            }
        }
        .padding(SolaroSpace.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .solaroCard()
    }

    private var featureSetsHeader: some View {
        HStack(spacing: SolaroSpace.s) {
            Text("NAME")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("CALLS")
                .frame(width: 44, alignment: .trailing)
            Text("AVG ms")
                .frame(width: 56, alignment: .trailing)
            Text("OK%")
                .frame(width: 44, alignment: .trailing)
        }
        .font(SolaroFont.caption)
        .tracking(1)
        .foregroundStyle(SolaroColor.textTertiary)
    }

    private func featureSetRow(_ fs: FeatureSetMetric) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: SolaroSpace.s) {
                Text(fs.name)
                    .font(SolaroFont.mono)
                    .foregroundStyle(SolaroColor.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(fs.count)")
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(SolaroColor.textSecondary)
                    .frame(width: 44, alignment: .trailing)
                Text(formatMs(fs.avgMs))
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(SolaroColor.textSecondary)
                    .frame(width: 56, alignment: .trailing)
                Text(formatPercent(fs.successRate, hasData: fs.count > 0))
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(successColor(fs.successRate, hasData: fs.count > 0))
                    .frame(width: 44, alignment: .trailing)
            }
            Text("\(fs.businessActivity) · min \(formatMs(fs.minMs)) · max \(formatMs(fs.maxMs))")
                .font(SolaroFont.caption)
                .foregroundStyle(SolaroColor.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Process card

    private func processCard(snap: MetricsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: SolaroSpace.s) {
            Text("Process")
                .font(SolaroFont.bodyBold)
                .foregroundStyle(SolaroColor.textPrimary)
            HStack(alignment: .top, spacing: SolaroSpace.m) {
                metricCell(label: "CPU user",
                           value: formatSec(snap.process.cpuUserSec))
                metricCell(label: "CPU sys",
                           value: formatSec(snap.process.cpuSystemSec))
            }
            HStack(alignment: .top, spacing: SolaroSpace.m) {
                metricCell(label: "Resident",
                           value: formatMB(snap.process.residentMB))
                metricCell(label: "Virtual",
                           value: formatMB(snap.process.virtualMB))
                metricCell(label: "Open FDs",
                           value: "\(snap.process.openFDs)")
            }
        }
        .padding(SolaroSpace.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .solaroCard()
    }

    // MARK: - Lifecycle

    private func sync(state: ConsoleProcess.State) {
        if case .running(let pid) = state {
            client.connect(pid: pid)
        } else {
            client.disconnect()
        }
    }

    // MARK: - Formatting helpers

    private func formatUptime(_ sec: Double) -> String {
        if sec < 60 { return String(format: "%.1fs", sec) }
        let totalSec = Int(sec)
        let h = totalSec / 3600
        let m = (totalSec % 3600) / 60
        let s = totalSec % 60
        if h > 0 { return String(format: "%dh %02dm %02ds", h, m, s) }
        return String(format: "%dm %02ds", m, s)
    }

    private func formatMs(_ ms: Double) -> String {
        if ms == 0 { return "—" }
        if ms < 10 { return String(format: "%.2f", ms) }
        if ms < 100 { return String(format: "%.1f", ms) }
        return "\(Int(ms.rounded()))"
    }

    private func formatPercent(_ pct: Double, hasData: Bool) -> String {
        guard hasData else { return "—" }
        if pct == 100 { return "100" }
        return String(format: "%.1f", pct)
    }

    private func formatSec(_ sec: Double) -> String {
        String(format: "%.2fs", sec)
    }

    private func formatMB(_ mb: Double) -> String {
        if mb < 100 { return String(format: "%.1f MB", mb) }
        return "\(Int(mb.rounded())) MB"
    }

    private func successColor(_ pct: Double, hasData: Bool) -> Color {
        guard hasData else { return SolaroColor.textTertiary }
        if pct >= 99   { return SolaroColor.stateOK }
        if pct >= 90   { return SolaroColor.stateWarn }
        return SolaroColor.stateError
    }
}
