// ============================================================
// MetricsAppKitPanel.swift
// SOLARO — AppKit metrics panel (replaces the SwiftUI version
// inside the inspector column to avoid macOS 26's
// SplitViewChildController constraint-update assertion)
// ============================================================
//
// The SwiftUI MetricsPanel kept crashing because every snapshot
// caused `NSHostingView.setNeedsUpdate()` → `setNeedsUpdateConstraints:`
// → `_postWindowNeedsUpdateConstraints`, which macOS 26 aborts on
// when it fires inside an in-flight constraint pass. Removing the
// SwiftUI subtree from inside the hosting view eliminates the
// trigger entirely — text-field stringValue mutations don't call
// setNeedsUpdate on the hosting view.
//
// All numeric columns have fixed widths, feature-set rows are
// pre-allocated and just hidden when unused, so updating values
// never changes view sizes. SplitViewChildController never sees a
// size invalidation, never enqueues a layout update, never crashes.

import SwiftUI
import AppKit
import Combine

/// SwiftUI shim wrapping the AppKit panel into the existing
/// right-rail switch in Workspace.
struct MetricsAppKitPanel: NSViewRepresentable {
    let process: ConsoleProcess

    func makeNSView(context: Context) -> NSView {
        MetricsContentView(process: process,
                            client: context.coordinator.client)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // No-op: the content view drives itself via Combine
        // observation and a 1 Hz timer.
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        let client = MetricsClient()
    }
}

/// Self-contained AppKit subtree. Owns layout, observes the
/// `ConsoleProcess` state to start/stop streaming, polls the
/// `MetricsClient` on a 1 Hz timer to refresh text fields.
@MainActor
final class MetricsContentView: NSView {
    private let process: ConsoleProcess
    private let client: MetricsClient

    // Header
    private let stateLabel = MetricsContentView.makeCaption("idle — press Run")
    private let heartbeat = MetricsContentView.makeHeartbeat()

    // Summary card
    private let uptimeValue = MetricsContentView.makeMono("—")
    private let executionsValue = MetricsContentView.makeMono("—")
    private let successValue = MetricsContentView.makeMono("—")
    private let failureBanner = MetricsContentView.makeCaption("")

    // Feature-sets card
    private let featureSetsHeading = MetricsContentView.makeBold("Feature sets")
    private let featureSetsCount = MetricsContentView.makeMonoCaption("0")
    private let featureSetsGrid = NSGridView()
    private let featureSetsEmpty = MetricsContentView.makeCaption(
        "Waiting for first feature-set execution…"
    )
    /// Pre-allocated row pool — we update text in existing grid
    /// rows instead of adding/removing them so the grid's content
    /// size never changes.
    private var featureSetRows: [FeatureSetGridRow] = []
    private let maxFeatureSetRows = 32
    private static let callsColumnWidth: CGFloat = 50
    private static let avgColumnWidth: CGFloat = 60
    private static let okColumnWidth: CGFloat = 44

    // Process card
    private let cpuUserValue = MetricsContentView.makeMono("—")
    private let cpuSystemValue = MetricsContentView.makeMono("—")
    private let residentValue = MetricsContentView.makeMono("—")
    private let virtualValue = MetricsContentView.makeMono("—")
    private let openFDsValue = MetricsContentView.makeMono("—")

    // Charts (Swift Charts hosted via NSHostingController with
    // sizingOptions = [] and a fixed view frame, so the inner
    // SwiftUI subtree's size never bubbles up to the inspector).
    private let throughputHost = NSHostingController(
        rootView: ThroughputSparkline(samples: []))
    private let cpuHost = NSHostingController(
        rootView: CPUSparkline(samples: []))
    private let memoryHost = NSHostingController(
        rootView: MemorySparkline(samples: []))
    private let barsHost = NSHostingController(
        rootView: FeatureSetBars(bars: []))

    // History — last ~60 samples (60s at 1 Hz). Older are dropped.
    private var history: [MetricsHistoryPoint] = []
    private var lastSampleStartUptime: Double?
    private var lastSampleExecutions: Int = 0
    private var lastSampleCPUTotal: Double = 0
    private var lastSampleAtUptime: Double = 0
    private let maxHistorySamples = 60

    // Observation — `nonisolated(unsafe)` so deinit can invalidate
    // the timer without an actor hop. Both fields are only mutated
    // on MainActor in practice (timer creation, never reassigned).
    nonisolated(unsafe) private var stateCancellable: AnyCancellable?
    nonisolated(unsafe) private var refreshTimer: Timer?
    private var lastConnectionState: MetricsClient.ConnectionState = .idle

    init(process: ConsoleProcess, client: MetricsClient) {
        self.process = process
        self.client = client
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor(SolaroColor.surface).cgColor
        buildLayout()
        observeProcessState()
        startRefreshTimer()
        applyConnectionState()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        refreshTimer?.invalidate()
        stateCancellable?.cancel()
    }

    // MARK: - Layout

    private func buildLayout() {
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        addSubview(scroll)

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = SolaroSpace.m
        content.edgeInsets = NSEdgeInsets(top: SolaroSpace.m,
                                          left: SolaroSpace.m,
                                          bottom: SolaroSpace.m,
                                          right: SolaroSpace.m)
        content.translatesAutoresizingMaskIntoConstraints = false
        content.setHuggingPriority(.defaultLow, for: .horizontal)
        content.setHuggingPriority(.defaultLow, for: .vertical)

        let flipper = FlippedView()
        flipper.translatesAutoresizingMaskIntoConstraints = false
        flipper.addSubview(content)
        scroll.documentView = flipper

        // Header
        let titleLabel = MetricsContentView.makeSectionTitle("METRICS")
        let headerRow = NSStackView(views: [titleLabel, NSView(), heartbeat])
        headerRow.orientation = .horizontal
        headerRow.spacing = SolaroSpace.s
        let header = NSStackView(views: [headerRow, stateLabel])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = SolaroSpace.xs

        // Cards
        let summaryCard = buildSummaryCard()
        let featureSetsCard = buildFeatureSetsCard()
        let processCard = buildProcessCard()

        for view in [header, summaryCard, featureSetsCard, processCard] {
            content.addArrangedSubview(view)
            view.widthAnchor.constraint(
                equalTo: content.widthAnchor,
                constant: -SolaroSpace.m * 2
            ).isActive = true
        }

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            flipper.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            flipper.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            flipper.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            flipper.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            content.topAnchor.constraint(equalTo: flipper.topAnchor),
            content.leadingAnchor.constraint(equalTo: flipper.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: flipper.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: flipper.bottomAnchor),
        ])
    }

    private func buildSummaryCard() -> NSView {
        let card = CardContainer()
        let title = MetricsContentView.makeBold("Summary")

        let uptimeCell = labeledCell("UPTIME", value: uptimeValue)
        let countCell = labeledCell("EXECUTIONS", value: executionsValue)
        let successCell = labeledCell("SUCCESS", value: successValue)
        let cells = NSStackView(views: [uptimeCell, countCell, successCell])
        cells.orientation = .horizontal
        cells.distribution = .fillEqually
        cells.spacing = SolaroSpace.m

        failureBanner.isHidden = true
        failureBanner.textColor = NSColor(SolaroColor.stateWarn)

        let chartLabel = MetricsContentView.makeCaption("THROUGHPUT · calls/s")
        chartLabel.textColor = NSColor(SolaroColor.textTertiary)
        let chartView = embedChart(throughputHost, width: 300, height: 56)

        let stack = NSStackView(views: [
            title, cells, failureBanner, chartLabel, chartView
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = SolaroSpace.s

        card.embed(stack)
        return card
    }

    private func buildFeatureSetsCard() -> NSView {
        let card = CardContainer()
        let headerRow = NSStackView(views: [
            featureSetsHeading, NSView(), featureSetsCount
        ])
        headerRow.orientation = .horizontal
        headerRow.spacing = SolaroSpace.s

        // Single NSGridView for both the column captions and the
        // per-feature-set rows — that way every cell shares one
        // column-width axis, and "4" lands directly under "CALLS"
        // regardless of how wide the name in the first column is.
        featureSetsGrid.translatesAutoresizingMaskIntoConstraints = false
        featureSetsGrid.rowSpacing = 4
        featureSetsGrid.columnSpacing = SolaroSpace.s

        let nameCaption = MetricsContentView.makeCaption("NAME")
        nameCaption.textColor = NSColor(SolaroColor.textTertiary)
        let callsCaption = MetricsContentView.makeCaption("CALLS")
        callsCaption.textColor = NSColor(SolaroColor.textTertiary)
        callsCaption.alignment = .right
        let avgCaption = MetricsContentView.makeCaption("AVG ms")
        avgCaption.textColor = NSColor(SolaroColor.textTertiary)
        avgCaption.alignment = .right
        let okCaption = MetricsContentView.makeCaption("OK%")
        okCaption.textColor = NSColor(SolaroColor.textTertiary)
        okCaption.alignment = .right
        featureSetsGrid.addRow(with: [
            nameCaption, callsCaption, avgCaption, okCaption
        ])

        // Pre-allocate feature-set rows. Each row contributes TWO
        // grid rows: one with the four numeric cells aligned to the
        // header columns, and one merged-across-all-columns row
        // underneath with the small activity caption.
        for _ in 0..<maxFeatureSetRows {
            let row = FeatureSetGridRow()
            let valuesGridRow = featureSetsGrid.addRow(with: [
                row.nameLabel, row.callsLabel, row.avgLabel, row.okLabel
            ])
            // Pad three empty cells so the merge target spans all 4.
            let activityGridRow = featureSetsGrid.addRow(with: [
                row.activityLabel, NSView(), NSView(), NSView()
            ])
            activityGridRow.mergeCells(in: NSRange(location: 0, length: 4))
            row.gridValuesRow = valuesGridRow
            row.gridActivityRow = activityGridRow
            row.isHidden = true
            featureSetRows.append(row)
        }

        // Fix the three numeric columns to constants so the headers
        // and the numbers below them stay glued; the first column
        // (NAME) absorbs all remaining width.
        let nameCol = featureSetsGrid.column(at: 0)
        nameCol.xPlacement = .leading

        let callsCol = featureSetsGrid.column(at: 1)
        callsCol.width = MetricsContentView.callsColumnWidth
        callsCol.xPlacement = .trailing

        let avgCol = featureSetsGrid.column(at: 2)
        avgCol.width = MetricsContentView.avgColumnWidth
        avgCol.xPlacement = .trailing

        let okCol = featureSetsGrid.column(at: 3)
        okCol.width = MetricsContentView.okColumnWidth
        okCol.xPlacement = .trailing

        let gridDivider = divider()
        let gridContainer = NSStackView(views: [
            featureSetsGrid, featureSetsEmpty
        ])
        gridContainer.orientation = .vertical
        gridContainer.alignment = .leading
        gridContainer.spacing = SolaroSpace.s

        let chartLabel = MetricsContentView.makeCaption("TOP BY CALL COUNT")
        chartLabel.textColor = NSColor(SolaroColor.textTertiary)
        let chartView = embedChart(barsHost, width: 300, height: 132)

        let stack = NSStackView(views: [
            headerRow, gridDivider, gridContainer, chartLabel, chartView
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = SolaroSpace.s

        card.embed(stack)
        return card
    }

    private func buildProcessCard() -> NSView {
        let card = CardContainer()
        let title = MetricsContentView.makeBold("Process")

        let cpuRow = NSStackView(views: [
            labeledCell("CPU USER", value: cpuUserValue),
            labeledCell("CPU SYS", value: cpuSystemValue),
        ])
        cpuRow.orientation = .horizontal
        cpuRow.distribution = .fillEqually
        cpuRow.spacing = SolaroSpace.m

        let cpuChartLabel = MetricsContentView.makeCaption("CPU% · trend")
        cpuChartLabel.textColor = NSColor(SolaroColor.textTertiary)
        let cpuChart = embedChart(cpuHost, width: 300, height: 36)

        let memRow = NSStackView(views: [
            labeledCell("RESIDENT", value: residentValue),
            labeledCell("VIRTUAL", value: virtualValue),
            labeledCell("OPEN FDs", value: openFDsValue),
        ])
        memRow.orientation = .horizontal
        memRow.distribution = .fillEqually
        memRow.spacing = SolaroSpace.m

        let memChartLabel = MetricsContentView.makeCaption("RESIDENT MB · trend")
        memChartLabel.textColor = NSColor(SolaroColor.textTertiary)
        let memChart = embedChart(memoryHost, width: 300, height: 36)

        let stack = NSStackView(views: [
            title, cpuRow, cpuChartLabel, cpuChart,
            memRow, memChartLabel, memChart
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = SolaroSpace.s

        card.embed(stack)
        return card
    }

    /// Pin a SwiftUI chart host's view to a fixed size and disable
    /// SwiftUI-driven size invalidation. The combination of
    /// `sizingOptions = []` and explicit width/height anchors makes
    /// the inner NSHostingView's intrinsic size effectively a
    /// no-op — its content can re-render without notifying the
    /// outer SplitView, which is what macOS 26's display-cycle
    /// assertion would otherwise pick up.
    private func embedChart<V: View>(
        _ host: NSHostingController<V>,
        width: CGFloat,
        height: CGFloat
    ) -> NSView {
        host.sizingOptions = []
        let view = host.view
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: width).isActive = true
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        return view
    }

    private func labeledCell(_ label: String, value: NSTextField) -> NSView {
        let lbl = MetricsContentView.makeCaption(label)
        lbl.textColor = NSColor(SolaroColor.textTertiary)
        let stack = NSStackView(views: [lbl, value])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        return stack
    }

    private func divider() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor(SolaroColor.divider).cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return v
    }

    // MARK: - Observation

    private func observeProcessState() {
        // Re-evaluate every render — the panel only needs to know
        // about transitions, and ConsoleProcess.state is part of
        // an @Observable. Use a Combine-style synthetic by
        // polling on the timer alongside snapshot refresh.
    }

    private func startRefreshTimer() {
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
        // First refresh immediately so connection state lands
        // before the user sees the empty defaults.
        refresh()
    }

    private func refresh() {
        syncConnectionToProcessState()
        applyConnectionState()
        // Prefer the embedded snapshot when present — short-lived
        // programs (e.g. ConstantFolding finishing in <50 ms) never
        // give the subprocess metrics socket a chance to stream
        // anything, so the in-process accumulator is the only path
        // that has real numbers. Falls back to `client.latest` for
        // normal (subprocess) Runs.
        if let snap = process.embeddedMetricsSnapshot ?? client.latest {
            applySnapshot(snap)
        }
    }

    private func syncConnectionToProcessState() {
        switch process.state {
        case .running(let pid):
            // Embedded runs use pid == -1 as a sentinel ("no
            // subprocess"). Don't try to open a socket against it
            // or the connection-state UI sticks in "connecting".
            if pid > 0 {
                client.connect(pid: pid)
            }
        case .idle, .exited, .failed:
            client.disconnect()
        }
    }

    private func applyConnectionState() {
        let s = client.connectionState
        guard s != lastConnectionState else { return }
        lastConnectionState = s

        let label: String
        let dotColor: NSColor
        switch s {
        case .idle:
            label = "idle — press Run"
            dotColor = NSColor(SolaroColor.textTertiary)
        case .connecting:
            label = "connecting to aro…"
            dotColor = NSColor(SolaroColor.stateWarn)
        case .streaming:
            label = "streaming"
            dotColor = NSColor(SolaroColor.stateOK)
        case .disconnected(let reason):
            label = "disconnected · \(reason)"
            dotColor = NSColor(SolaroColor.textTertiary)
        }
        stateLabel.stringValue = label
        heartbeat.layer?.backgroundColor = dotColor.cgColor
    }

    private func applySnapshot(_ snap: MetricsSnapshot) {
        uptimeValue.stringValue = formatUptime(snap.uptimeSec)
        executionsValue.stringValue = "\(snap.totalExecutions)"
        successValue.stringValue = snap.totalExecutions == 0
            ? "—"
            : String(format: "%.1f%%", snap.successRate)

        if snap.totalFailures > 0 {
            failureBanner.isHidden = false
            failureBanner.stringValue =
                "⚠ \(snap.totalFailures) failed execution"
                + (snap.totalFailures == 1 ? "" : "s")
        } else {
            failureBanner.isHidden = true
        }

        let sortedSets = snap.featureSets.sorted { $0.count > $1.count }
        featureSetsCount.stringValue = "\(sortedSets.count)"
        featureSetsEmpty.isHidden = !sortedSets.isEmpty
        let visible = min(sortedSets.count, maxFeatureSetRows)
        for i in 0..<featureSetRows.count {
            let row = featureSetRows[i]
            if i < visible {
                row.populate(with: sortedSets[i])
                row.isHidden = false
            } else {
                row.isHidden = true
            }
        }

        cpuUserValue.stringValue = String(format: "%.2fs",
                                          snap.process.cpuUserSec)
        cpuSystemValue.stringValue = String(format: "%.2fs",
                                            snap.process.cpuSystemSec)
        residentValue.stringValue = formatMB(snap.process.residentMB)
        virtualValue.stringValue = formatMB(snap.process.virtualMB)
        openFDsValue.stringValue = "\(snap.process.openFDs)"

        appendHistory(from: snap)
        updateCharts(snap: snap, sortedFeatureSets: sortedSets)
    }

    /// Append a derived sample to the rolling history. Throughput
    /// (calls/s) and CPU% are deltas between consecutive snapshots
    /// so we always have a fresh per-second rate even when uptime
    /// is hours.
    private func appendHistory(from snap: MetricsSnapshot) {
        let now = snap.uptimeSec
        if lastSampleStartUptime == nil {
            lastSampleStartUptime = now
            lastSampleExecutions = snap.totalExecutions
            lastSampleCPUTotal = snap.process.cpuTotalSec
            lastSampleAtUptime = now
            return
        }
        let dt = max(0.001, now - lastSampleAtUptime)
        let dExec = snap.totalExecutions - lastSampleExecutions
        let dCPU = snap.process.cpuTotalSec - lastSampleCPUTotal
        let callsPerSec = Double(dExec) / dt
        // CPU% across all cores: ratio of CPU-seconds consumed to
        // wall-clock-seconds elapsed. >100% means multi-core load.
        let cpuPct = (dCPU / dt) * 100.0

        let nextID = (history.last?.id ?? -1) + 1
        history.append(MetricsHistoryPoint(
            id: nextID,
            timeOffsetSec: now,
            callsPerSec: max(0, callsPerSec),
            cpuPercent: max(0, cpuPct),
            residentMB: snap.process.residentMB
        ))
        if history.count > maxHistorySamples {
            history.removeFirst(history.count - maxHistorySamples)
        }

        lastSampleExecutions = snap.totalExecutions
        lastSampleCPUTotal = snap.process.cpuTotalSec
        lastSampleAtUptime = now
    }

    /// Push fresh data into each chart's rootView. SwiftUI
    /// re-renders the chart contents but the host's view frame is
    /// pinned by widthAnchor/heightAnchor + `sizingOptions = []`,
    /// so no size invalidation propagates upward.
    private func updateCharts(
        snap: MetricsSnapshot,
        sortedFeatureSets: [FeatureSetMetric]
    ) {
        throughputHost.rootView = ThroughputSparkline(samples: history)
        cpuHost.rootView = CPUSparkline(samples: history)
        memoryHost.rootView = MemorySparkline(samples: history)
        let topBars = sortedFeatureSets.prefix(5).map {
            FeatureSetBars.Bar(id: $0.name, count: $0.count)
        }
        barsHost.rootView = FeatureSetBars(bars: Array(topBars))
    }

    // MARK: - Formatting helpers

    private func formatUptime(_ sec: Double) -> String {
        if sec < 60 { return String(format: "%.1fs", sec) }
        let total = Int(sec)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%dh %02dm %02ds", h, m, s) }
        return String(format: "%dm %02ds", m, s)
    }

    private func formatMB(_ mb: Double) -> String {
        if mb < 100 { return String(format: "%.1f MB", mb) }
        return "\(Int(mb.rounded())) MB"
    }

    // MARK: - Factories

    private static func makeSectionTitle(_ text: String) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        f.textColor = NSColor(SolaroColor.textSecondary)
        return f
    }

    private static func makeBold(_ text: String) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        f.textColor = NSColor(SolaroColor.textPrimary)
        return f
    }

    private static func makeCaption(_ text: String) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = NSFont.systemFont(ofSize: 11)
        f.textColor = NSColor(SolaroColor.textSecondary)
        return f
    }

    private static func makeMonoCaption(_ text: String) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        f.textColor = NSColor(SolaroColor.textTertiary)
        return f
    }

    private static func makeMono(_ text: String) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        f.textColor = NSColor(SolaroColor.textPrimary)
        return f
    }

    private static func makeCaptionFixed(
        _ text: String,
        width: CGFloat,
        align: NSTextAlignment
    ) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = NSFont.systemFont(ofSize: 11)
        f.textColor = NSColor(SolaroColor.textTertiary)
        f.alignment = align
        if width > 0 {
            f.widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        return f
    }

    private static func makeHeartbeat() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.cornerRadius = 3
        v.layer?.backgroundColor = NSColor(SolaroColor.textTertiary).cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: 6).isActive = true
        v.heightAnchor.constraint(equalToConstant: 6).isActive = true
        return v
    }
}

/// One feature-set row living inside the shared `NSGridView`.
/// Holds references to its grid rows so we can flip `isHidden`
/// without removing/inserting (which would reflow the grid).
@MainActor
private final class FeatureSetGridRow {
    let nameLabel = NSTextField(labelWithString: "")
    let callsLabel = NSTextField(labelWithString: "")
    let avgLabel = NSTextField(labelWithString: "")
    let okLabel = NSTextField(labelWithString: "")
    let activityLabel = NSTextField(labelWithString: "")

    weak var gridValuesRow: NSGridRow?
    weak var gridActivityRow: NSGridRow?

    init() {
        nameLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        nameLabel.textColor = NSColor(SolaroColor.textPrimary)
        nameLabel.lineBreakMode = .byTruncatingMiddle

        callsLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        callsLabel.textColor = NSColor(SolaroColor.textSecondary)
        callsLabel.alignment = .right

        avgLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        avgLabel.textColor = NSColor(SolaroColor.textSecondary)
        avgLabel.alignment = .right

        okLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        okLabel.alignment = .right

        activityLabel.font = NSFont.systemFont(ofSize: 10)
        activityLabel.textColor = NSColor(SolaroColor.textTertiary)
        activityLabel.lineBreakMode = .byTruncatingTail
    }

    var isHidden: Bool {
        get { gridValuesRow?.isHidden ?? true }
        set {
            gridValuesRow?.isHidden = newValue
            gridActivityRow?.isHidden = newValue
        }
    }

    func populate(with fs: FeatureSetMetric) {
        nameLabel.stringValue = fs.name
        callsLabel.stringValue = "\(fs.count)"
        avgLabel.stringValue = formatMs(fs.avgMs)
        okLabel.stringValue = fs.count == 0
            ? "—"
            : String(format: "%.0f", fs.successRate)
        okLabel.textColor = NSColor(successColor(fs.successRate,
                                                  hasData: fs.count > 0))
        activityLabel.stringValue =
            "\(fs.businessActivity) · min \(formatMs(fs.minMs)) · max \(formatMs(fs.maxMs))"
    }

    private func formatMs(_ ms: Double) -> String {
        if ms == 0 { return "—" }
        if ms < 10 { return String(format: "%.2f", ms) }
        if ms < 100 { return String(format: "%.1f", ms) }
        return "\(Int(ms.rounded()))"
    }

    private func successColor(_ pct: Double, hasData: Bool) -> Color {
        guard hasData else { return SolaroColor.textTertiary }
        if pct >= 99 { return SolaroColor.stateOK }
        if pct >= 90 { return SolaroColor.stateWarn }
        return SolaroColor.stateError
    }
}

/// Rounded surface card. Constant size — content inside changes
/// via text mutation only, so the card's frame stays put.
@MainActor
private final class CardContainer: NSView {
    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor(SolaroColor.surfaceRaised).cgColor
        layer?.cornerRadius = SolaroRadius.m
        layer?.borderColor = NSColor(SolaroColor.divider).cgColor
        layer?.borderWidth = 1
    }
    required init?(coder: NSCoder) { nil }

    func embed(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: topAnchor,
                                       constant: SolaroSpace.m),
            view.leadingAnchor.constraint(equalTo: leadingAnchor,
                                           constant: SolaroSpace.m),
            view.trailingAnchor.constraint(equalTo: trailingAnchor,
                                            constant: -SolaroSpace.m),
            view.bottomAnchor.constraint(equalTo: bottomAnchor,
                                          constant: -SolaroSpace.m),
        ])
    }
}

/// NSScrollView lays out documentView from the top by default
/// only when isFlipped is true on the document view.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
