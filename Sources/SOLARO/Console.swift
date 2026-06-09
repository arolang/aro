// ============================================================
// Console.swift
// SOLARO — bottom run console + `aro run` process driver (Phase 16)
// ============================================================
//
// Xcode-style captured-output panel that slides up from the bottom
// when the user clicks the toolbar Play button. Spawns
// `aro run <project>` via `/usr/bin/env`, captures stdout+stderr
// into an attributed log, and streams it into a monospaced view.
//
// ANSI escape sequences are stripped (a real SGR parser is a
// follow-up — for now we just keep the text legible).

import SwiftUI
import AppKit
import Foundation
import ARORuntime

@MainActor
@Observable
final class ConsoleProcess {
    enum State: Equatable {
        case idle
        case running(pid: Int32)
        case exited(code: Int32)
        case failed(String)
        /// XPC service died mid-run (#282 phase 3). Distinct from
        /// `.failed` so the UI can offer a "Reload" affordance —
        /// SOLARO is alive, the user's project is still loaded,
        /// the next click of Run restarts a fresh service.
        case serviceCrashed(message: String)
    }

    /// Append-only log of captured stdout+stderr lines.
    var log: [LogEntry] = []
    var state: State = .idle

    /// True when the last XPC service died unexpectedly — drives
    /// the toolbar's Run → Reload swap.
    var didServiceCrash: Bool {
        if case .serviceCrashed = state { return true }
        return false
    }
    /// 1-indexed line of the most recent `⏸  paused (…) at file:LINE`
    /// notice from the debugger. SwiftUI binds to this so the editor
    /// caret can jump to the pause point automatically.
    var pausedLine: Int?

    /// `true` between a `⏸  paused` notice and the next command
    /// the user sends. Drives the debug-button bar's enablement.
    var isPaused: Bool = false

    /// Symbols visible at the most recent pause. Cleared on
    /// continue/step/next/finish. Used by the canvas + editor for
    /// hover tooltips that show live variable values.
    var pauseSymbols: [String: SymbolValue] = [:]

    /// Wall-clock time each source line was most recently executed
    /// (per the JSONL event stream). Drives the canvas's "executing
    /// now" pulse — node cards whose `lineHint` shows up here recent
    /// enough light up a colored left border that fades out over
    /// ~600 ms. Reset at the start of every new run.
    var lastExecutedAt: [Int: Date] = [:]
    /// Wall-clock time each feature set was most recently observed
    /// to be running (any statement inside it fired). Drives the
    /// container-level glow so concurrent feature sets are visually
    /// distinct in the canvas. Reset at run start.
    var lastExecutedAtPerFeatureSet: [String: Date] = [:]
    /// Source line → runtime error message. Populated when an
    /// embedded-mode `errorCheckpoint` fires for that line; drives
    /// the red border + tooltip on the failing canvas node. Reset
    /// at the start of every new run.
    var errorLines: [Int: String] = [:]
    /// PASS/FAIL outcome per test feature-set name, parsed from the
    /// runner's stdout. Cleared at the start of each `aro test` run
    /// and read by the canvas / inspector to badge containers.
    var testResults: [String: TestNodeResult] = [:]
    /// Monotonically increases each time `lastExecutedAt` is updated.
    /// SwiftUI watches this so TimelineView-driven animations keep
    /// scheduling refreshes even when the same line fires twice in
    /// a row (and the dict value stays nominally equal).
    var executionTick: UInt64 = 0
    /// Latest value the runtime wrote into / read from each
    /// repository, keyed by repository object name (`"user-repository"`,
    /// `"sessions-store"`, …). Surfaced by the canvas's repository
    /// cards so the user sees the live payload alongside the wires.
    var repositoryValues: [String: SymbolValue] = [:]
    /// Rolling history (newest first) of the last few payloads per
    /// repository — exposed in the repository card's hover popover
    /// so the user can see the recent write sequence. Capped so a
    /// hot loop doesn't grow memory without bound.
    var repositoryHistory: [String: [SymbolValue]] = [:]
    /// Current rows held by each repository, projected to flat
    /// `[field: rendered-value]` dictionaries (#284 step 3).
    /// Surfaced by `RepoCard` as a live table during a run. Reset
    /// alongside `repositoryValues` on every fresh start.
    var repositoryRecords: [String: [[String: String]]] = [:]
    private static let repositoryHistoryDepth = 5

    /// Shared metrics client read by `MetricsPanel`. Owned here so
    /// both transports — the push socket the subprocess opens, and
    /// the synthetic snapshots the embedded runtime publishes —
    /// converge on a single observable target. Created once per
    /// process; runs reset it via `connect()` or
    /// `publishSynthetic()`.
    let metricsClient = MetricsClient()
    /// Synthetic snapshot produced by the embedded runtime path.
    /// Held directly on ConsoleProcess (an `@Observable` class) so
    /// SwiftUI re-renders MetricsPanel deterministically on every
    /// update — the previous `metricsClient.latest` route went
    /// through a nested @Observable whose change notifications
    /// weren't reliably propagating through MetricsPanel's
    /// computed-property accessor.
    var embeddedMetricsSnapshot: MetricsSnapshot?

    /// In-flight metrics aggregation for the current embedded run.
    /// Populated by `applyLiveBatch` while `embeddedHost != nil`,
    /// snapshotted to `metricsClient` on a 1s timer (and on
    /// completion) so the panel still shows numbers even when the
    /// run finishes inside a single SwiftUI frame.
    private struct EmbeddedAccumulator {
        var startedAt: Date
        var perFS: [String: (count: Int, firstAt: Date, lastAt: Date)] = [:]
        var totalEvents: Int = 0
    }
    private var embeddedAccumulator: EmbeddedAccumulator?
    private var embeddedMetricsTimer: Timer?

    struct SymbolValue: Equatable, Hashable {
        let name: String
        let typeName: String
        let value: String
        /// Current rows of a repository symbol (#284 step 3). Nil
        /// for non-repository symbols.
        let records: [[String: String]]?

        init(name: String, typeName: String, value: String,
             records: [[String: String]]? = nil) {
            self.name = name
            self.typeName = typeName
            self.value = value
            self.records = records
        }
    }

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdinPipe: Pipe?
    private var liveStream: LiveEventStream?
    /// In-process runtime host (issue #282 phase 1). Used in place of
    /// the subprocess when `SOLARO_EMBEDDED_RUNTIME=1`.
    private var embeddedHost: EmbeddedRuntimeHost?
    /// Active XPC proxy when the project is running under the
    /// isolated backend (#282 phase 3). Same role as
    /// `embeddedHost` for the in-process path.
    private var xpcProxy: AROXPCRuntimeProxy?
    /// True while we're running an `aro debug` session — the
    /// console exposes a stdin input field so the user can type
    /// debugger commands (continue, step, etc).
    private(set) var acceptsStdin: Bool = false

    struct LogEntry: Identifiable, Equatable {
        let id = UUID()
        let kind: Kind
        let text: String
        let timestamp: Date

        enum Kind { case stdout, stderr, info, error }
    }

    /// Spawn `aro run <project>` (or `aro debug …` when breakpoints
    /// are set). No-op when a process is already running.
    enum Mode {
        case run
        case debug
        case test(filter: String?)
    }

    init() {
        // Terminate any spawned `aro` subprocess when SOLARO quits.
        // Without this the child keeps running and holds onto its
        // listening ports (e.g. 8080) — surprising the user the
        // next launch and forcing them to `lsof | kill -9`.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.stop()
            }
        }
    }

    /// Convenience for the Play button — plain `aro run` by default,
    /// or the in-process embedded runtime when
    /// `SOLARO_EMBEDDED_RUNTIME=1` (issue #282 phase 1).
    ///
    /// `parameters` carries CLI-style key/value pairs collected by
    /// the run-parameters sheet (see `RunParameters.swift`). Embedded
    /// path writes them into `ParameterStorage.shared` before the run
    /// begins; subprocess path appends them as `--key value` to argv.
    func startRun(project: Project, parameters: [String: String] = [:]) {
        switch RuntimeBackend.current {
        case .embedded:
            startEmbeddedRun(project: project, parameters: parameters)
        case .xpc:
            startXPCRun(project: project, parameters: parameters)
        case .external:
            start(project: project, mode: .run,
                  breakpointsByFile: [:],
                  parameters: parameters)
        }
    }

    /// XPC-isolated variant (#282 phase 3). Mirrors
    /// `startEmbeddedRun` but routes through `AROXPCRuntimeProxy`
    /// so the runtime lives in the AROXPCService process. A
    /// crash there shows up as a non-zero termination status
    /// instead of dragging the whole IDE down.
    private func startXPCRun(project: Project,
                             parameters: [String: String] = [:]) {
        if case .running = state { return }
        log.removeAll()
        pausedLine = nil
        isPaused = false
        pauseSymbols.removeAll(keepingCapacity: true)
        lastExecutedAt.removeAll(keepingCapacity: true)
        lastExecutedAtPerFeatureSet.removeAll(keepingCapacity: true)
        errorLines.removeAll(keepingCapacity: true)
        testResults.removeAll(keepingCapacity: true)
        repositoryValues.removeAll(keepingCapacity: true)
        repositoryHistory.removeAll(keepingCapacity: true)
        repositoryRecords.removeAll(keepingCapacity: true)
        executionTick = 0
        lastProject = project
        breakpointLines = []
        didAutoContinueFirstPause = false

        ParameterStorage.shared.clear()
        for (key, value) in parameters {
            ParameterStorage.shared.set(key, value: value)
        }

        let proxy = AROXPCRuntimeProxy()
        proxy.onRecords = { [weak self] batch in
            self?.applyLiveBatch(batch)
        }
        proxy.onEnded = { [weak self] error in
            guard let self else { return }
            if let error {
                let ns = error as NSError
                self.appendError("[xpc] \(error.localizedDescription)")
                // Code 3 = the service process exited non-zero
                // mid-run. Surface a dedicated state so the
                // toolbar can swap Run → Reload.
                if ns.domain == "AROXPCRuntimeProxy", ns.code == 3 {
                    self.state = .serviceCrashed(
                        message: error.localizedDescription
                    )
                } else {
                    self.state = .exited(code: 1)
                }
            } else {
                self.state = .exited(code: 0)
            }
            self.appendInfo("[xpc run complete]")
            self.xpcProxy = nil
        }
        proxy.onLog = { [weak self] message in
            self?.appendInfo(message)
        }
        xpcProxy = proxy
        appendInfo("$ xpc-service \(project.rootPath.lastPathComponent)")
        state = .running(pid: -1)
        proxy.start(project: project)
    }

    /// In-process variant of `startRun`. Reuses every downstream
    /// pipeline the subprocess path feeds — `applyLiveBatch`,
    /// `lastExecutedAt`, the per-FS glow, the repo card history —
    /// just with records arriving through `EmbeddedRuntimeHost`
    /// instead of `LiveEventStream`.
    private func startEmbeddedRun(project: Project,
                                  parameters: [String: String] = [:]) {
        if case .running = state { return }
        log.removeAll()
        pausedLine = nil
        isPaused = false
        pauseSymbols.removeAll(keepingCapacity: true)
        lastExecutedAt.removeAll(keepingCapacity: true)
        lastExecutedAtPerFeatureSet.removeAll(keepingCapacity: true)
        errorLines.removeAll(keepingCapacity: true)
        testResults.removeAll(keepingCapacity: true)
        repositoryValues.removeAll(keepingCapacity: true)
        repositoryHistory.removeAll(keepingCapacity: true)
        repositoryRecords.removeAll(keepingCapacity: true)
        executionTick = 0
        lastProject = project
        breakpointLines = []
        didAutoContinueFirstPause = false
        acceptsStdin = false

        let host = EmbeddedRuntimeHost()
        host.onRecords = { [weak self] batch in
            self?.applyLiveBatch(batch)
        }
        host.onEnded = { [weak self] error in
            guard let self else { return }
            // Final snapshot before tearing down — short-lived
            // programs (e.g. ConstantFolding finishing in 5 ms)
            // never give the 1 s timer a chance to fire, so this
            // publish is what populates the panel.
            self.publishEmbeddedMetricsSnapshot()
            self.embeddedMetricsTimer?.invalidate()
            self.embeddedMetricsTimer = nil
            if let error {
                self.appendError("[embedded] \(error.localizedDescription)")
                self.state = .exited(code: 1)
            } else {
                self.state = .exited(code: 0)
            }
            self.appendInfo("[embedded run complete]")
            self.embeddedHost = nil
        }
        host.onLog = { [weak self] message in
            self?.appendInfo(message)
        }
        // Application Log output goes through the stdout path so
        // the console panel renders it in the foreground colour
        // (matches what the user sees in external `aro run` mode).
        host.onAppOutput = { [weak self] line in
            self?.appendLine(line, kind: .stdout)
        }
        embeddedHost = host
        appendInfo("$ embedded-runtime \(project.rootPath.lastPathComponent)")
        // Synthesize a fake PID — there's no subprocess to mark, but
        // downstream observers expect `State.running` with *some*
        // integer so they can flip UI affordances.
        state = .running(pid: -1)
        // Start metrics aggregation. Embedded runs don't have a push
        // socket to read from, so we synthesise snapshots from our
        // own per-statement bookkeeping and publish them on a 1 s
        // cadence + once at completion. Short-lived programs
        // (HelloWorld, ConstantFolding) finish before the cadence
        // ticks, so the completion publish is what they rely on.
        embeddedAccumulator = EmbeddedAccumulator(startedAt: Date())
        embeddedMetricsSnapshot = nil
        metricsClient.resetIdle()
        embeddedMetricsTimer?.invalidate()
        embeddedMetricsTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.publishEmbeddedMetricsSnapshot() }
        }
        // Inject scanned run parameters into the shared storage so
        // `<parameter: NAME>` extracts resolve. The embedded runtime
        // reads from `ParameterStorage.shared` directly; clear first
        // so a previous run's values don't leak into an empty form.
        ParameterStorage.shared.clear()
        for (key, value) in parameters {
            ParameterStorage.shared.set(key, value: value)
        }
        host.start(project: project)
    }

    /// Convenience for the Debug button — `aro debug` with whatever
    /// breakpoints the workspace has accumulated, plus optional
    /// `<parameter: NAME>` values collected by the pre-run sheet.
    func startDebug(project: Project,
                    breakpointsByFile: [URL: Set<Int>],
                    parameters: [String: String] = [:]) {
        start(project: project,
              mode: .debug,
              breakpointsByFile: breakpointsByFile,
              parameters: parameters)
    }

    /// Convenience for the Tests command — runs `aro test` with an
    /// optional --filter pattern. Output streams into the same
    /// console panel as run/debug.
    func startTests(project: Project, filter: String? = nil) {
        start(project: project, mode: .test(filter: filter),
              breakpointsByFile: [:])
    }

    /// Lower-level entry that both convenience helpers funnel through.
    func start(project: Project,
               mode: Mode,
               breakpointsByFile: [URL: Set<Int>] = [:],
               parameters: [String: String] = [:]) {
        if case .running = state { return }
        log.removeAll()
        pausedLine = nil
        isPaused = false
        pauseSymbols.removeAll(keepingCapacity: true)
        lastExecutedAt.removeAll(keepingCapacity: true)
        lastExecutedAtPerFeatureSet.removeAll(keepingCapacity: true)
        errorLines.removeAll(keepingCapacity: true)
        testResults.removeAll(keepingCapacity: true)
        repositoryValues.removeAll(keepingCapacity: true)
        repositoryHistory.removeAll(keepingCapacity: true)
        repositoryRecords.removeAll(keepingCapacity: true)
        executionTick = 0
        lastProject = project
        breakpointLines = Set(breakpointsByFile.values.flatMap { $0 })
        didAutoContinueFirstPause = false

        let lines = breakpointsByFile.values.flatMap { $0 }.sorted()
        let useDebugger: Bool
        if case .debug = mode { useDebugger = true } else { useDebugger = false }

        let aro = Self.resolveAroBinary(near: project)
        appendInfo("[aro] \(aro)")

        // Build the subcommand portion of the argv.
        var subArgs: [String]
        switch mode {
        case .debug:
            subArgs = ["debug", project.rootPath.path,
                       "--record", recordPath(for: project)]
            for line in lines {
                subArgs.append("--breakpoint")
                subArgs.append(String(line))
            }
            // Forward `<parameter: NAME>` values exactly the same
            // way `.run` does so the Debug button can prompt for
            // them too (parity with the Play button).
            for (key, value) in parameters.sorted(by: { $0.key < $1.key }) {
                subArgs.append("--\(key)")
                subArgs.append(value)
            }
            appendInfo("$ aro debug \(project.rootPath.lastPathComponent)  (breakpoints: \(lines))")
        case .run:
            // `--debug-record` is on by default so SOLARO's canvas
            // can light up executing nodes and surface live values
            // without a separate "debug" mode. Distinct from
            // `--record`, which is reserved for the
            // EventRecorder/EventReplayer pair.
            subArgs = ["run", project.rootPath.path,
                       "--debug-record", recordPath(for: project)]
            // Append `--name value` for each parameter collected by
            // the run-parameters sheet so the child process's
            // `ParameterStorage` picks them up.
            for (key, value) in parameters.sorted(by: { $0.key < $1.key }) {
                subArgs.append("--\(key)")
                subArgs.append(value)
            }
            appendInfo("$ aro run \(project.rootPath.lastPathComponent)")
        case .test(let filter):
            // `--record` so the canvas pulse / executed-line tint
            // light up while a test run is in progress (#?). The
            // same JSONL file the run path tails fans events out
            // through `LiveEventStream`.
            subArgs = ["test", project.rootPath.path,
                       "--record", recordPath(for: project)]
            if let filter, !filter.isEmpty {
                subArgs.append(contentsOf: ["--filter", filter])
                appendInfo("$ aro test \(project.rootPath.lastPathComponent) --filter \(filter)")
            } else {
                appendInfo("$ aro test \(project.rootPath.lastPathComponent)")
            }
        }

        let task = Process()
        if aro == "/usr/bin/env" {
            // Fallback path — let env resolve `aro` from $PATH.
            task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            task.arguments = ["aro"] + subArgs
        } else {
            task.executableURL = URL(fileURLWithPath: aro)
            task.arguments = subArgs
        }
        task.currentDirectoryURL = project.rootPath

        // Tell the runtime to open its metrics push socket so the
        // Metrics tab can stream live snapshots. Inherit the rest
        // of the env so PATH/TMPDIR/etc. stay intact — the client
        // resolves the socket path from the child's TMPDIR.
        var env = ProcessInfo.processInfo.environment
        env["ARO_METRICS_SOCKET"] = "1"
        task.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        task.standardOutput = stdout
        task.standardError = stderr
        task.standardInput = stdin
        stdoutPipe = stdout
        stderrPipe = stderr
        stdinPipe = stdin
        acceptsStdin = useDebugger

        // Stream stdout / stderr line-by-line into the log.
        readPipe(stdout) { [weak self] line in
            Task { @MainActor [weak self] in self?.appendLine(line, kind: .stdout) }
        }
        readPipe(stderr) { [weak self] line in
            Task { @MainActor [weak self] in self?.appendLine(line, kind: .stderr) }
        }

        task.terminationHandler = { [weak self] proc in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.state = .exited(code: proc.terminationStatus)
                self.appendInfo("[exit \(proc.terminationStatus)]")
                self.liveStream?.stop()
                self.liveStream = nil
            }
        }

        do {
            try task.run()
            process = task
            state = .running(pid: task.processIdentifier)
            // Begin tailing the JSONL stream so the canvas pulses
            // and updates values in real time as the runtime runs.
            // Debug + Run both feed the same file path here.
            startLiveStream(at: recordPath(for: project))
        } catch {
            state = .failed(error.localizedDescription)
            appendError(error.localizedDescription)
        }
    }

    /// Open the JSONL events file for live tailing. Each newly-
    /// appended record updates `pauseSymbols` (latest value per
    /// symbol name), `lastExecutedAt[line] = now`, and the bookkeeping
    /// counter `executionTick` that SwiftUI watches to refresh
    /// animation views.
    private func startLiveStream(at path: String) {
        liveStream?.stop()
        let url = URL(fileURLWithPath: path)
        let stream = LiveEventStream(url: url) { [weak self] batch in
            self?.applyLiveBatch(batch)
        }
        liveStream = stream
        stream.start()
    }

    /// Apply a whole drain's worth of records under one observation
    /// frame so a burst from a hot loop costs a single SwiftUI redraw
    /// instead of one per record. The receiver bumps `executionTick`
    /// exactly once at the end of the batch.
    private func applyLiveBatch(_ batch: [TimeTravelRecord]) {
        guard !batch.isEmpty else { return }
        let now = Date()
        for record in batch {
            if record.kind == .error, let line = record.line, line > 0 {
                // Strip the Swift case-printing wrapper: PauseInfo.Reason
                // prints as `error("…")`, but the user-facing tooltip
                // looks nicer with just the message.
                var msg = record.reason ?? "runtime error"
                if msg.hasPrefix("error(\""), msg.hasSuffix("\")") {
                    msg = String(msg.dropFirst("error(\"".count)
                                    .dropLast("\")".count))
                }
                errorLines[line] = msg
            }
            if let line = record.line, line > 0 {
                lastExecutedAt[line] = now
            }
            if let fs = record.featureSet, !fs.isEmpty {
                lastExecutedAtPerFeatureSet[fs] = now
                if embeddedAccumulator != nil {
                    var entry = embeddedAccumulator?.perFS[fs]
                        ?? (count: 0, firstAt: now, lastAt: now)
                    entry.count += 1
                    entry.lastAt = now
                    embeddedAccumulator?.perFS[fs] = entry
                    embeddedAccumulator?.totalEvents += 1
                }
            }
            for sym in record.symbols {
                let value = SymbolValue(
                    name: sym.name,
                    typeName: sym.typeName,
                    value: sym.value,
                    records: sym.records
                )
                pauseSymbols[sym.name] = value
                let lower = sym.name.lowercased()
                if lower.hasSuffix("-repository")
                    || lower.hasSuffix("-repo")
                    || lower.hasSuffix("-store")
                {
                    repositoryValues[sym.name] = value
                    if let recs = sym.records {
                        repositoryRecords[sym.name] = recs
                    }
                    // Push onto the front of the history queue and
                    // cap depth. Skip consecutive duplicates so the
                    // history reads as a write *sequence* rather
                    // than the same value re-emitted on every read.
                    var hist = repositoryHistory[sym.name] ?? []
                    if hist.first != value {
                        hist.insert(value, at: 0)
                        if hist.count > Self.repositoryHistoryDepth {
                            hist.removeLast(hist.count - Self.repositoryHistoryDepth)
                        }
                        repositoryHistory[sym.name] = hist
                    }
                }
            }
        }
        executionTick &+= 1
    }

    /// Stop the running process; no-op when nothing is running.
    func stop() {
        liveStream?.stop()
        liveStream = nil
        if let host = embeddedHost {
            host.stop()
            // The host's onEnded flips state to .exited.
            return
        }
        if let proxy = xpcProxy {
            proxy.stop()
            return
        }
        guard let process, process.isRunning else {
            process = nil
            return
        }
        process.terminate()
        // The terminationHandler will flip state to .exited.
    }

    /// Write a line of input to the running process's stdin. Used
    /// for debugger commands (continue, step, b 12, etc).
    func sendInput(_ line: String) {
        guard let stdinPipe else { return }
        appendInfo("> \(line)")
        let bytes = (line + "\n").data(using: .utf8) ?? Data()
        stdinPipe.fileHandleForWriting.write(bytes)
        isPaused = false
        pauseSymbols.removeAll(keepingCapacity: true)
    }

    // MARK: - Step commands

    /// Continue execution until the next breakpoint / program end.
    /// Embedded path calls into `EmbeddedRuntimeHost`'s
    /// step-via-API helpers (#282 phase 2); subprocess path keeps
    /// using the stdin-fed `c` / `s` / `n` / `f` commands.
    func continueExecution() {
        if let host = embeddedHost, host.isPausedAtBreakpoint {
            host.continueExecution(); return
        }
        if let proxy = xpcProxy, proxy.isPausedAtBreakpoint {
            proxy.continueExecution(); return
        }
        sendInput("c")
    }
    /// Advance into the next statement (follows emits/calls).
    func stepInto() {
        if let host = embeddedHost, host.isPausedAtBreakpoint {
            host.stepIn(); return
        }
        if let proxy = xpcProxy, proxy.isPausedAtBreakpoint {
            proxy.stepIn(); return
        }
        sendInput("s")
    }
    /// Advance over the next statement.
    func stepOver() {
        if let host = embeddedHost, host.isPausedAtBreakpoint {
            host.stepOver(); return
        }
        if let proxy = xpcProxy, proxy.isPausedAtBreakpoint {
            proxy.stepOver(); return
        }
        sendInput("n")
    }
    /// Run until the current feature set returns.
    func finishFrame() {
        if let host = embeddedHost, host.isPausedAtBreakpoint {
            host.stepOut(); return
        }
        if let proxy = xpcProxy, proxy.isPausedAtBreakpoint {
            proxy.stepOut(); return
        }
        sendInput("f")
    }
    /// Quit the debugger session.
    func quit() { sendInput("q") }

    /// Build a `MetricsSnapshot` from the embedded run's accumulator
    /// (per-FS counts/timing) and the current process resource usage
    /// (CPU + memory via mach), then hand it to the shared
    /// `MetricsClient` for the panel to render.
    fileprivate func publishEmbeddedMetricsSnapshot() {
        guard let acc = embeddedAccumulator else { return }
        let now = Date()
        let uptime = now.timeIntervalSince(acc.startedAt)
        let featureSets: [FeatureSetMetric] = acc.perFS
            .map { name, agg in
                let totalMs = max(0, agg.lastAt.timeIntervalSince(agg.firstAt) * 1000)
                let avg = agg.count > 0 ? totalMs / Double(agg.count) : 0
                return FeatureSetMetric(
                    name: name,
                    businessActivity: name,
                    count: agg.count,
                    successes: agg.count,
                    failures: 0,
                    totalMs: totalMs,
                    minMs: avg,
                    maxMs: avg,
                    avgMs: avg,
                    successRate: 100
                )
            }
            .sorted { $0.name < $1.name }
        let process = Self.currentProcessMetrics()
        let snap = MetricsSnapshot(
            kind: "embedded",
            collectedAt: ISO8601DateFormatter().string(from: now),
            uptimeSec: uptime,
            totalExecutions: acc.totalEvents,
            totalSuccesses: acc.totalEvents,
            totalFailures: 0,
            featureSets: featureSets,
            process: process
        )
        metricsClient.publishSynthetic(snap)
        embeddedMetricsSnapshot = snap
    }

    /// Snapshot the host process's CPU + memory. Reads
    /// `mach_task_basic_info` for resident memory and `getrusage`
    /// for accumulated user/system CPU seconds. Cheap (one syscall
    /// each), safe to call on every Metrics tick.
    private static func currentProcessMetrics() -> ProcessMetricsView {
        var basicInfo = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size
                / MemoryLayout<integer_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &basicInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }
        let residentMB: Double
        let virtualMB: Double
        if kr == KERN_SUCCESS {
            residentMB = Double(basicInfo.resident_size) / 1024 / 1024
            virtualMB = Double(basicInfo.virtual_size) / 1024 / 1024
        } else {
            residentMB = 0
            virtualMB = 0
        }
        var usage = rusage()
        let cpuUser: Double
        let cpuSystem: Double
        if getrusage(RUSAGE_SELF, &usage) == 0 {
            cpuUser = Double(usage.ru_utime.tv_sec)
                + Double(usage.ru_utime.tv_usec) / 1_000_000
            cpuSystem = Double(usage.ru_stime.tv_sec)
                + Double(usage.ru_stime.tv_usec) / 1_000_000
        } else {
            cpuUser = 0
            cpuSystem = 0
        }
        // Count of open file descriptors — best-effort via fcntl
        // F_MAXFD (Darwin); fall back to a fixed estimate.
        let fdCount = Int(getdtablesize())
        return ProcessMetricsView(
            cpuUserSec: cpuUser,
            cpuSystemSec: cpuSystem,
            virtualMB: virtualMB,
            residentMB: residentMB,
            openFDs: fdCount
        )
    }

    /// Where `--record` writes its JSONL stream for time-travel
    /// playback in the Time-Travel view. Creates the parent
    /// `.solaro/` directory on demand — `DebugEventLogWriter` fails
    /// silently if the directory is missing, which manifested as
    /// "no variables in the inspector during debug".
    private func recordPath(for project: Project) -> String {
        let url = project.rootPath.appendingPathComponent(".solaro/events.jsonl")
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        return url.path
    }

    /// Pick an `aro` binary in priority order:
    ///   1. `$SOLARO_ARO` environment override
    ///   2. The SOLARO source-tree's local debug build, walking up
    ///      from the open project's parent until a Package.swift +
    ///      .build/debug/aro pair is found (common during SOLARO
    ///      development — Homebrew's `aro` may lag behind main).
    ///   3. Same dance with .build/release/aro.
    ///   4. `/usr/local/bin/aro`
    ///   5. `/opt/homebrew/bin/aro`
    ///   6. Bare `aro` resolved by /usr/bin/env (the legacy path).
    nonisolated static func resolveAroBinary(near project: Project) -> String {
        let fm = FileManager.default
        // Settings override (UserDefaults) takes precedence over
        // the SOLARO_ARO env var so the user can change it without
        // relaunching with a different environment.
        let defaultsPath = UserDefaults.standard.string(forKey: SolaroPrefs.aroOverride.rawValue) ?? ""
        if !defaultsPath.isEmpty, fm.isExecutableFile(atPath: defaultsPath) {
            return defaultsPath
        }
        if let envPath = ProcessInfo.processInfo.environment["SOLARO_ARO"],
           !envPath.isEmpty, fm.isExecutableFile(atPath: envPath) {
            return envPath
        }

        // Walk up from the project root looking for an ARO source
        // checkout. When both `.build/release/aro` and
        // `.build/debug/aro` exist we pick whichever was built more
        // recently — otherwise a stale release binary from an old
        // build would shadow a freshly-rebuilt debug binary, and
        // SOLARO would silently keep launching the old CLI even
        // after the developer ran `swift build` (issue: tests
        // failing with "Unknown option '--record'" after a CLI
        // option was added).
        var dir = project.rootPath.deletingLastPathComponent()
        let configs = ["release", "debug"]
        for _ in 0..<8 {  // hard cap so we never recurse forever
            var candidates: [(path: String, mtime: Date)] = []
            for cfg in configs {
                let candidate = dir.appendingPathComponent(".build/\(cfg)/aro").path
                if fm.isExecutableFile(atPath: candidate) {
                    let mtime = (try? FileManager.default
                        .attributesOfItem(atPath: candidate)[.modificationDate]
                        as? Date) ?? .distantPast
                    candidates.append((candidate, mtime))
                }
            }
            if let newest = candidates.max(by: { $0.mtime < $1.mtime }) {
                return newest.path
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }

        // Common install locations as fallbacks.
        let fallbacks = [
            "/usr/local/bin/aro",
            "/opt/homebrew/bin/aro",
        ]
        for path in fallbacks where fm.isExecutableFile(atPath: path) {
            return path
        }

        // Last resort — let env walk PATH at exec time. The console
        // will surface the failure when an older `aro` doesn't
        // recognise the requested subcommand.
        return "/usr/bin/env"
    }

    /// Drain the read-side of a pipe in the background, splitting
    /// on newlines and posting each line back via `onLine`. ANSI
    /// codes get stripped before the line lands in the UI.
    nonisolated private func readPipe(_ pipe: Pipe,
                                      onLine: @Sendable @escaping (String) -> Void) {
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            guard let chunk = String(data: data, encoding: .utf8) else { return }
            let cleaned = Self.stripANSI(chunk)
            cleaned.split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
                .filter { !$0.isEmpty }
                .forEach(onLine)
        }
    }

    private func appendLine(_ line: String, kind: LogEntry.Kind) {
        log.append(LogEntry(kind: kind, text: line, timestamp: Date()))
        detectPause(in: line)
        if let hit = TestResultParser.match(line) {
            testResults[hit.name] = hit.result
            executionTick &+= 1
        }
    }

    /// Scan a freshly-logged line for the debugger's pause notice.
    /// Updates pausedLine, flips isPaused, and refreshes the live
    /// symbol table from the JSONL record.
    private func detectPause(in line: String) {
        guard line.contains("⏸") else { return }
        guard
            let atRange = line.range(of: " at "),
            let dashRange = line.range(of: " — ", range: atRange.upperBound..<line.endIndex)
        else { return }
        let whereSegment = line[atRange.upperBound..<dashRange.lowerBound]
        guard
            let colon = whereSegment.lastIndex(of: ":"),
            let n = Int(whereSegment[whereSegment.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces))
        else { return }
        pausedLine = n
        isPaused = true
        refreshSymbolsFromRecord()

        // First pause coming back from the debugger is at the
        // program's first statement (the step-debugger pauses on
        // every step by default). If the user actually set
        // breakpoints, auto-continue so execution runs to the
        // first breakpoint — they didn't ask to stop at line 1.
        // We only do this once per session; subsequent pauses are
        // user-initiated.
        if !didAutoContinueFirstPause,
           !breakpointLines.isEmpty,
           !breakpointLines.contains(n)
        {
            didAutoContinueFirstPause = true
            sendInput("c")
        }
    }

    /// Read the JSONL record file and capture the last pause event's
    /// symbol bag into `pauseSymbols` keyed by name. The record path
    /// is the same one we pass to `aro debug --record`.
    private func refreshSymbolsFromRecord() {
        guard let project = lastProject else { return }
        let url = URL(fileURLWithPath: recordPath(for: project))
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return
        }
        let records = TimeTravelReader.parse(text)
        guard let lastPause = records.last(where: { $0.kind == .pause })
        else { return }
        var bag: [String: SymbolValue] = [:]
        for s in lastPause.symbols {
            bag[s.name] = SymbolValue(
                name: s.name, typeName: s.typeName, value: s.value
            )
        }
        pauseSymbols = bag
    }

    /// Project the most recent `start()` call ran against — used
    /// by `refreshSymbolsFromRecord()` to locate the JSONL file.
    private var lastProject: Project?

    /// All breakpoint line numbers (across every file) the current
    /// debug session was started with. Used to decide whether the
    /// debugger's first pause is actually at a user-requested
    /// breakpoint or just at the program's entry — in the latter
    /// case we auto-continue so the run feels like a "real"
    /// breakpoint debugger.
    private var breakpointLines: Set<Int> = []
    private var didAutoContinueFirstPause = false

    private func appendInfo(_ line: String) {
        log.append(LogEntry(kind: .info, text: line, timestamp: Date()))
    }

    private func appendError(_ line: String) {
        log.append(LogEntry(kind: .error, text: line, timestamp: Date()))
    }

    /// Strip the most common ANSI CSI / SGR escape sequences. A
    /// follow-up turns these into NSAttributedString attributes
    /// instead of dropping them on the floor.
    nonisolated static func stripANSI(_ input: String) -> String {
        var out = ""
        out.reserveCapacity(input.count)
        var iter = input.makeIterator()
        while let c = iter.next() {
            if c == "\u{001B}" {                  // ESC
                // Eat until a letter (CSI terminator) or whitespace.
                while let n = iter.next() {
                    if n.isLetter { break }
                }
            } else {
                out.append(c)
            }
        }
        return out
    }
}

// MARK: - Console panel view

struct ConsolePanelView: View {
    @Bindable var process: ConsoleProcess
    let onClose: () -> Void

    @State private var stdinInput: String = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            if process.acceptsStdin {
                Divider().background(SolaroColor.divider)
                debugBar
            }
            Divider().background(SolaroColor.divider)
            logView
            if process.acceptsStdin {
                Divider().background(SolaroColor.divider)
                stdinField
            }
        }
        .frame(maxWidth: .infinity)
        .background(SolaroColor.surface)
    }

    /// Debugger button row — visible only while `aro debug` is the
    /// active subcommand. Each button maps to one of the TUI's
    /// single-letter commands. Disabled until the process actually
    /// pauses, so accidental clicks don't pile up commands on stdin.
    private var debugBar: some View {
        HStack(spacing: SolaroSpace.s) {
            DebugCmdButton(label: "Continue", symbol: "play.fill",
                           enabled: process.isPaused) {
                process.continueExecution()
            }
            DebugCmdButton(label: "Step", symbol: "arrow.turn.down.right",
                           enabled: process.isPaused) {
                process.stepInto()
            }
            DebugCmdButton(label: "Next", symbol: "arrow.right.to.line",
                           enabled: process.isPaused) {
                process.stepOver()
            }
            DebugCmdButton(label: "Finish", symbol: "arrow.uturn.up",
                           enabled: process.isPaused) {
                process.finishFrame()
            }
            Spacer()
            Text(process.isPaused
                 ? "paused at line \(process.pausedLine.map(String.init) ?? "?")"
                 : "running…")
                .font(SolaroFont.monoCaption)
                .foregroundStyle(process.isPaused
                                 ? SolaroColor.stateWarn
                                 : SolaroColor.textTertiary)
            DebugCmdButton(label: "Quit", symbol: "xmark.octagon",
                           enabled: true) {
                process.quit()
            }
        }
        .padding(.horizontal, SolaroSpace.m)
        .padding(.vertical, SolaroSpace.xs)
        .background(SolaroColor.surfaceRaised)
    }

    private var stdinField: some View {
        HStack(spacing: SolaroSpace.s) {
            Text("(debug)")
                .font(SolaroFont.monoCaption)
                .foregroundStyle(SolaroColor.accent)
            TextField("type a debugger command — c, s, n, b 12, q",
                      text: $stdinInput)
                .textFieldStyle(.plain)
                .font(SolaroFont.mono)
                .foregroundStyle(SolaroColor.textPrimary)
                .onSubmit {
                    guard !stdinInput.isEmpty else { return }
                    process.sendInput(stdinInput)
                    stdinInput = ""
                }
        }
        .padding(.horizontal, SolaroSpace.m)
        .padding(.vertical, SolaroSpace.xs)
        .background(SolaroColor.backdrop)
    }

    private var header: some View {
        HStack(spacing: SolaroSpace.s) {
            statePip
            Text("Console")
                .font(SolaroFont.sectionTitle)
                .foregroundStyle(SolaroColor.textSecondary)
                .tracking(2)
            Spacer()
            stateLabel
            Button {
                process.stop()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .disabled({
                if case .running = process.state { return false }
                return true
            }())
            Button {
                process.log.removeAll()
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .help("Clear the console log")
            Button {
                onClose()
            } label: {
                Label("Hide", systemImage: "xmark")
            }
            .help("Hide the console (logs persist in memory)")
        }
        .padding(.horizontal, SolaroSpace.m)
        .padding(.vertical, SolaroSpace.xs)
    }

    private var statePip: some View {
        Image(systemName: "circle.fill")
            .resizable()
            .frame(width: 8, height: 8)
            .foregroundStyle(pipColor)
    }

    private var pipColor: Color {
        switch process.state {
        case .idle:    return SolaroColor.textTertiary
        case .running: return SolaroColor.stateOK
        case .exited(let code): return code == 0 ? SolaroColor.stateOK
                                                 : SolaroColor.stateError
        case .failed:  return SolaroColor.stateError
        case .serviceCrashed: return SolaroColor.stateError
        }
    }

    private var stateLabel: some View {
        Text(stateText)
            .font(SolaroFont.monoCaption)
            .foregroundStyle(SolaroColor.textTertiary)
    }

    private var stateText: String {
        switch process.state {
        case .idle: return "idle"
        case .running(let pid): return "running · pid \(pid)"
        case .exited(let code): return "exit \(code)"
        case .failed(let msg): return "failed: \(msg)"
        case .serviceCrashed(let msg): return "service crashed: \(msg)"
        }
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(process.log) { entry in
                        Text(entry.text)
                            .font(SolaroFont.mono)
                            .foregroundStyle(color(for: entry.kind))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, SolaroSpace.m)
                            .padding(.vertical, 1)
                            .id(entry.id)
                    }
                    // Anchor so we can auto-scroll to the latest line.
                    Color.clear.frame(height: 1).id("bottom")
                }
            }
            .background(SolaroColor.backdrop)
            .onChange(of: process.log.count) { _, _ in
                withAnimation(.linear(duration: 0.1)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    /// Tiny labelled icon button for the debug bar.
    private struct DebugCmdButton: View {
        let label: String
        let symbol: String
        let enabled: Bool
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                HStack(spacing: 4) {
                    Image(systemName: symbol)
                    Text(label).font(SolaroFont.caption)
                }
            }
            .disabled(!enabled)
        }
    }

    private func color(for kind: ConsoleProcess.LogEntry.Kind) -> Color {
        switch kind {
        case .stdout: return SolaroColor.textPrimary
        case .stderr: return SolaroColor.stateError
        case .info:   return SolaroColor.accent
        case .error:  return SolaroColor.stateError
        }
    }
}
