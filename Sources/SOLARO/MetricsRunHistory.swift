// ============================================================
// MetricsRunHistory.swift
// SOLARO — per-run metrics buckets + back/forward navigation
// ============================================================
//
// Issue #375: the metrics panel used to keep one rolling buffer
// across application invocations, so every Run drew on top of the
// previous one. This model isolates each run into its own
// `RunMetrics` bucket:
//
//   • `beginRun()` — called by ConsoleProcess at the start of every
//     invocation (embedded, XPC, and subprocess paths all funnel
//     through it) — opens a fresh bucket and jumps the selection
//     to it, so the panel starts from an empty graph.
//   • `ingest(_:)` — appends derived chart samples + the latest
//     snapshot to the *current* bucket, regardless of which run
//     the user is looking at.
//   • ◂ / ▸ navigation selects an older bucket for display without
//     disturbing the live one.
//
// The stack is capped (default 20 runs, `SolaroPrefs.
// metricsHistoryDepth`); older runs fall off the back. Memory is
// bounded by `maxSamplesPerRun` × depth, well under a megabyte.

import Foundation

/// One application invocation's worth of metrics — the chart
/// samples accumulated while it ran plus the last snapshot seen
/// (which feeds the summary/feature-set/process cards).
struct RunMetrics: Identifiable, Equatable {
    /// Monotonic run number — unique for the lifetime of the
    /// owning `MetricsRunHistory`, survives trimming.
    let id: Int
    let startedAt: Date
    var samples: [MetricsHistoryPoint] = []
    var lastSnapshot: MetricsSnapshot?
}

@MainActor
final class MetricsRunHistory {
    static let defaultDepth = 20
    /// Same series cap the panel's old rolling buffer used —
    /// ~60 s of samples at the 1 Hz refresh cadence.
    static let maxSamplesPerRun = 60

    /// Oldest → newest. The last element is the live run.
    private(set) var runs: [RunMetrics] = []

    /// Run id the user navigated to, or `nil` to follow the
    /// latest run (the default — new runs auto-display).
    private(set) var selectedRunID: Int?

    /// History depth source — replaceable in tests. Reads the
    /// settings key on every trim so changes apply to the next Run
    /// without a restart.
    var depthProvider: () -> Int = {
        let configured = UserDefaults.standard
            .integer(forKey: SolaroPrefs.metricsHistoryDepth.rawValue)
        return configured > 0 ? configured : MetricsRunHistory.defaultDepth
    }

    private var nextRunID = 1

    // Delta bookkeeping for the live run — throughput and CPU% are
    // rates between consecutive snapshots, so the first snapshot of
    // a run only establishes the baseline.
    private var hasBaselineSample = false
    private var lastSampleExecutions = 0
    private var lastSampleCPUTotal: Double = 0
    private var lastSampleAtUptime: Double = 0
    /// Last snapshot fed to `ingest`. Deliberately NOT reset on
    /// `beginRun()` — a stale `MetricsClient.latest` from the
    /// previous subprocess can still be visible for one refresh
    /// tick after Run is pressed, and skipping equal snapshots
    /// keeps it out of the new bucket.
    private var lastIngested: MetricsSnapshot?

    // MARK: - Run lifecycle

    /// Open a fresh bucket for a new application invocation and
    /// jump the display to it. The previous run's data stays on
    /// the stack for ◂ navigation.
    func beginRun(at date: Date = Date()) {
        runs.append(RunMetrics(id: nextRunID, startedAt: date))
        nextRunID += 1
        hasBaselineSample = false
        selectedRunID = nil
        trim()
    }

    /// Feed the latest snapshot into the live run. Consecutive
    /// identical snapshots are skipped — after a process exits its
    /// last snapshot stays cached upstream and would otherwise
    /// append a flat tail forever.
    func ingest(_ snap: MetricsSnapshot) {
        guard snap != lastIngested else { return }
        lastIngested = snap
        if runs.isEmpty {
            // Defensive: snapshot arrived before any beginRun()
            // (shouldn't happen — every run path calls it). Open
            // an implicit bucket rather than dropping data.
            beginRun()
        }
        ingestIntoCurrent(snap)
    }

    private func ingestIntoCurrent(_ snap: MetricsSnapshot) {
        let idx = runs.count - 1
        runs[idx].lastSnapshot = snap

        let now = snap.uptimeSec
        guard hasBaselineSample else {
            hasBaselineSample = true
            lastSampleExecutions = snap.totalExecutions
            lastSampleCPUTotal = snap.process.cpuTotalSec
            lastSampleAtUptime = now
            return
        }

        let dt = max(0.001, now - lastSampleAtUptime)
        let dExec = snap.totalExecutions - lastSampleExecutions
        let dCPU = snap.process.cpuTotalSec - lastSampleCPUTotal
        // CPU% across all cores: CPU-seconds consumed over
        // wall-clock-seconds elapsed. >100% means multi-core load.
        let cpuPct = (dCPU / dt) * 100.0

        let nextSampleID = (runs[idx].samples.last?.id ?? -1) + 1
        runs[idx].samples.append(MetricsHistoryPoint(
            id: nextSampleID,
            timeOffsetSec: now,
            callsPerSec: max(0, Double(dExec) / dt),
            cpuPercent: max(0, cpuPct),
            residentMB: snap.process.residentMB
        ))
        if runs[idx].samples.count > Self.maxSamplesPerRun {
            runs[idx].samples.removeFirst(
                runs[idx].samples.count - Self.maxSamplesPerRun
            )
        }

        lastSampleExecutions = snap.totalExecutions
        lastSampleCPUTotal = snap.process.cpuTotalSec
        lastSampleAtUptime = now
    }

    private func trim() {
        let depth = max(1, depthProvider())
        if runs.count > depth {
            let dropped = runs.prefix(runs.count - depth).map(\.id)
            runs.removeFirst(runs.count - depth)
            if let selected = selectedRunID, dropped.contains(selected) {
                selectedRunID = nil
            }
        }
    }

    // MARK: - Display selection

    /// The run the panel should paint — the explicitly selected
    /// one, or the latest when following live.
    var displayedRun: RunMetrics? {
        if let id = selectedRunID,
           let run = runs.first(where: { $0.id == id }) {
            return run
        }
        return runs.last
    }

    /// 1-based position of the displayed run within the retained
    /// stack, for the "run #N of M" title.
    var displayedPosition: (index: Int, total: Int)? {
        guard let run = displayedRun,
              let idx = runs.firstIndex(where: { $0.id == run.id })
        else { return nil }
        return (idx + 1, runs.count)
    }

    var canGoBack: Bool {
        guard let pos = displayedPosition else { return false }
        return pos.index > 1
    }

    var canGoForward: Bool {
        guard let pos = displayedPosition else { return false }
        return pos.index < pos.total
    }

    /// Whether the panel is following the live (latest) run.
    var isAtLatest: Bool { !canGoForward }

    func goBack() {
        guard canGoBack,
              let run = displayedRun,
              let idx = runs.firstIndex(where: { $0.id == run.id })
        else { return }
        selectedRunID = runs[idx - 1].id
    }

    func goForward() {
        guard canGoForward,
              let run = displayedRun,
              let idx = runs.firstIndex(where: { $0.id == run.id })
        else { return }
        let next = idx + 1
        // Landing on the newest run resumes following live, so
        // the next Run auto-displays without another ▸ press.
        selectedRunID = next == runs.count - 1 ? nil : runs[next].id
    }

    func jumpToLatest() {
        selectedRunID = nil
    }
}
