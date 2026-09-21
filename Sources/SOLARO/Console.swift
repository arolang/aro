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
    /// Source-of-truth debugger snapshot owned by the session
    /// (this ConsoleProcess). All the old flat properties
    /// (pausedLine, pauseSymbols, lastExecutedAt, …) are
    /// preserved as forwarding accessors so existing call sites
    /// keep compiling, but the data physically lives here (#306).
    var debuggerState = DebuggerState()

    var pausedLine: Int? {
        get { debuggerState.pausedLine }
        set { debuggerState.pausedLine = newValue }
    }

    /// `true` between a `⏸  paused` notice and the next command
    /// the user sends. Drives the debug-button bar's enablement.
    var isPaused: Bool = false

    var pauseSymbols: [String: SymbolValue] {
        get { debuggerState.pauseSymbols }
        set { debuggerState.pauseSymbols = newValue }
    }

    var lastExecutedAt: [SourceRef: Date] {
        get { debuggerState.lastExecutedAt }
        set { debuggerState.lastExecutedAt = newValue }
    }
    var lastExecutedAtPerFeatureSet: [String: Date] {
        get { debuggerState.lastExecutedAtPerFeatureSet }
        set { debuggerState.lastExecutedAtPerFeatureSet = newValue }
    }
    var errorLines: [SourceRef: String] {
        get { debuggerState.errorLines }
        set { debuggerState.errorLines = newValue }
    }
    var testResults: [String: TestNodeResult] {
        get { debuggerState.testResults }
        set { debuggerState.testResults = newValue }
    }
    var executionTick: UInt64 {
        get { debuggerState.executionTick }
        set { debuggerState.executionTick = newValue }
    }
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
    /// Cap on `log` size. A long verbose run otherwise grows without
    /// bound. On overflow we drop the oldest half so SwiftUI re-renders
    /// are bounded and amortized cost stays O(1) per append.
    ///
    /// Raised from 10 000 now that `logView` is lazy (#751). The old cap
    /// existed because a non-lazy `VStack` materialised every row on every
    /// append, so the list itself was the limit; a `LazyVStack` builds only
    /// what is on screen, and the ceiling can go back to being about memory.
    /// A `LogEntry` is a kind, a line and a timestamp, so 50 000 lines of a
    /// verbose run cost a few megabytes — and a verbose run is exactly when
    /// scrolling back matters.
    static let logCap = 50_000

    /// Shared metrics client read by the metrics panel. Owned here so
    /// both transports — the push socket the subprocess opens, and
    /// the synthetic snapshots the embedded runtime publishes —
    /// converge on a single observable target. Created once per
    /// process; runs reset it via `connect()` or
    /// `publishSynthetic()`.
    let metricsClient = MetricsClient()
    /// Per-run metrics buckets + ◂ ▸ navigation state (#375).
    /// Owned here — not by the panel — so history survives the
    /// inspector being collapsed/reopened, and so every run path
    /// (embedded, XPC, subprocess) can signal "run started" the
    /// moment it begins.
    let metricsRunHistory = MetricsRunHistory()
    /// Synthetic snapshot produced by the embedded runtime path.
    /// Held directly on ConsoleProcess (an `@Observable` class) so
    /// the metrics panel re-renders deterministically on every
    /// update — the previous `metricsClient.latest` route went
    /// through a nested @Observable whose change notifications
    /// weren't reliably propagating through the panel's
    /// computed-property accessor.
    var embeddedMetricsSnapshot: MetricsSnapshot?

    /// In-flight metrics aggregation for the current embedded run.
    /// Populated by `applyLiveBatch` while `embeddedHost != nil`,
    /// snapshotted to `metricsClient` on a 1s timer (and on
    /// completion) so the panel still shows numbers even when the
    /// run finishes inside a single SwiftUI frame.
    private struct EmbeddedAccumulator {
        var startedAt: Date
        /// SOLARO's own footprint sampled just before the run starts.
        /// Embedded runs share the IDE's address space, so absolute
        /// mach/rusage numbers would include SOLARO itself — the
        /// panel shows the delta against this baseline instead, i.e.
        /// what the ARO application consumed. `nil` for XPC runs:
        /// there the app lives in the AROXPCService child, whose
        /// absolute footprint is sampled per-PID and is already
        /// app-only.
        var baseline: ProcessMetricsView?
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
    /// Pending SIGKILL escalation for the process being stopped (#756).
    ///
    /// Held so it can be cancelled. It used to be an unowned `Task` that
    /// captured the `Process` strongly and was never stored, so a child
    /// that exited cleanly at 1.9 seconds left a timer still counting —
    /// and a new run started in the meantime raced it.
    private var killEscalation: Task<Void, Never>?
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
        /// `aro build` — produce a native binary (#763).
        case build(BuildOptions)
        /// `aro check` — syntax and semantics, no execution (#763).
        case check

        /// Whether this mode writes the JSONL event record the canvas
        /// tails. Build and check do not run the program, so there is
        /// nothing to light up and no stream to open.
        var producesEvents: Bool {
            switch self {
            case .run, .debug, .test: return true
            case .build, .check: return false
            }
        }
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
        // The runtime reads the project from disk, so the editor's debounced
        // autosaves have to land first (#748). Covers all three backends.
        EditorWriteQueue.flushNow()
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
        // A previous stop may still be counting down to SIGKILL (#756).
        // Its target is gone or about to be; let it go before its timer
        // can reach a pid this run now owns.
        killEscalation?.cancel()
        killEscalation = nil
        // `aro` is about to read the files, not the buffers (#748).
        EditorWriteQueue.flushNow()
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
            // Final snapshot before tearing down — mirrors the
            // embedded path; short-lived programs finish before
            // the 1 s timer ever fires.
            self.publishEmbeddedMetricsSnapshot()
            self.embeddedMetricsTimer?.invalidate()
            self.embeddedMetricsTimer = nil
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
        // Same synthetic-metrics pipeline as the embedded path —
        // the service has no push socket to connect to. No baseline:
        // process usage is sampled from the service child's PID, so
        // the numbers are already app-only.
        embeddedAccumulator = EmbeddedAccumulator(
            startedAt: Date(), baseline: nil
        )
        embeddedMetricsSnapshot = nil
        metricsClient.resetIdle()
        metricsRunHistory.beginRun()
        embeddedMetricsTimer?.invalidate()
        embeddedMetricsTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.publishEmbeddedMetricsSnapshot() }
        }
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
        // A previous stop may still be counting down to SIGKILL (#756).
        // Its target is gone or about to be; let it go before its timer
        // can reach a pid this run now owns.
        killEscalation?.cancel()
        killEscalation = nil
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
        embeddedAccumulator = EmbeddedAccumulator(
            startedAt: Date(),
            baseline: Self.currentProcessMetrics()
        )
        embeddedMetricsSnapshot = nil
        metricsClient.resetIdle()
        metricsRunHistory.beginRun()
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
                    breakpointConfigs: [Int: LayoutSidecar.BreakpointConfig] = [:],
                    parameters: [String: String] = [:]) {
        start(project: project,
              mode: .debug,
              breakpointsByFile: breakpointsByFile,
              breakpointConfigs: breakpointConfigs,
              parameters: parameters)
    }

    /// Convenience for the Tests command — runs `aro test` with an
    /// optional --filter pattern. Output streams into the same
    /// console panel as run/debug.
    func startTests(project: Project, filter: String? = nil) {
        start(project: project, mode: .test(filter: filter),
              breakpointsByFile: [:])
    }

    /// Build the project to a native binary (#763).
    ///
    /// Always the external `aro` binary: `aro build` shells out to a
    /// linker and produces a file on disk, which is not something the
    /// embedded or XPC runtime backends do — they execute programs.
    func startBuild(project: Project, options: BuildOptions) {
        start(project: project, mode: .build(options))
    }

    /// Check the project without running it (#763).
    func startCheck(project: Project) {
        start(project: project, mode: .check)
    }

    /// Lower-level entry that both convenience helpers funnel through.
    func start(project: Project,
               mode: Mode,
               breakpointsByFile: [URL: Set<Int>] = [:],
               breakpointConfigs: [Int: LayoutSidecar.BreakpointConfig] = [:],
               parameters: [String: String] = [:]) {
        if case .running = state { return }
        // A previous stop may still be counting down to SIGKILL (#756).
        // Its target is gone or about to be; let it go before its timer
        // can reach a pid this run now owns.
        killEscalation?.cancel()
        killEscalation = nil
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
        // A stale embedded snapshot from a previous in-process run
        // would otherwise shadow the subprocess socket stream in
        // the metrics panel (it's preferred when non-nil).
        embeddedMetricsSnapshot = nil
        metricsRunHistory.beginRun()

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
            // Each breakpoint line becomes one of three flag shapes
            // depending on its per-line config (#259):
            //   * logpoint   → --logpoint "LINE=MESSAGE" (never pauses)
            //   * conditional→ --break-condition "LINE=EXPR"
            //   * plain      → --breakpoint LINE
            // The runtime matches on line number (file-agnostic),
            // mirroring how `breakpointLines` is already flattened
            // across files.
            for line in lines {
                let config = breakpointConfigs[line] ?? .init()
                if config.kind == .logpoint,
                   let message = config.logMessage, !message.isEmpty {
                    subArgs.append("--logpoint")
                    subArgs.append("\(line)=\(message)")
                } else if let condition = config.condition, !condition.isEmpty {
                    subArgs.append("--break-condition")
                    subArgs.append("\(line)=\(condition)")
                } else {
                    subArgs.append("--breakpoint")
                    subArgs.append(String(line))
                }
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
        case .build(let options):
            subArgs = ["build", project.rootPath.path] + options.arguments
            appendInfo(options.commandLine(
                projectName: project.rootPath.lastPathComponent))
        case .check:
            subArgs = ["check", project.rootPath.path]
            appendInfo("$ aro check \(project.rootPath.lastPathComponent)")
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
                // The child is gone, so there is nothing left to escalate
                // to (#756) — and its pid is now free for the system to
                // hand to somebody else.
                self.killEscalation?.cancel()
                self.killEscalation = nil
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
            // Debug + Run both feed the same file path here. Build and
            // check never execute the program, so there is nothing to
            // tail and no stale record to reopen (#763).
            if mode.producesEvents {
                startLiveStream(at: recordPath(for: project))
            }
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
        // A new run's symbols have nothing to do with the last one's.
        lastPauseSymbols = nil
        // Nor does the previous run's evidence about which mechanism
        // reports pauses (#752) — a run against an older runtime has to
        // be able to fall back to the console text again.
        sawStructuredPause = false
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
    /// Whether a program is executing right now (#765).
    ///
    /// The Project Map animates events travelling along wires, which
    /// happens between records rather than at one, so it needs to know
    /// when to keep asking for frames and when to stop.
    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    /// Not private so a test can feed it records without a subprocess.
    func applyLiveBatch(_ batch: [TimeTravelRecord]) {
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
                errorLines[SourceRef(file: record.file, line: line)] = msg
            }
            if let line = record.line, line > 0 {
                lastExecutedAt[SourceRef(file: record.file, line: line)] = now
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
            if record.kind == .pause {
                // The runtime says where it stopped, so take it from here
                // rather than parsing an emoji out of the console (#752).
                sawStructuredPause = true
                // The bag as of this pause, so `refreshSymbolsFromRecord`
                // does not have to go back to the file for it (GitLab #747).
                var bag: [String: SymbolValue] = [:]
                for sym in record.symbols {
                    bag[sym.name] = SymbolValue(
                        name: sym.name,
                        typeName: sym.typeName,
                        value: sym.value,
                        records: sym.records
                    )
                }
                lastPauseSymbols = bag
                // The bag is in place before this, because entering the
                // pause refreshes the inspector from it.
                if let line = record.line, line > 0 {
                    enterPause(atLine: line)
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
        // Escalate to SIGKILL after a grace period — an `aro`
        // process wedged in native code never services the SIGTERM
        // and would keep its ports bound (GitLab #527).
        //
        // The pid is valid while `isRunning` is true, because `Process`
        // only reaps the child — freeing the pid for reuse — when it
        // actually exits. That is a statement about this Process object,
        // though, and the escalation used to keep the object alive past
        // its own child's death (#756): a clean exit at 1.9 seconds, a new
        // run started immediately, and two overlapping stop/start cycles
        // racing to signal a pid the system had already handed on.
        //
        // So the escalation is owned. It is cancelled when the child
        // exits, and again when the next run starts.
        killEscalation?.cancel()
        killEscalation = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            // Re-read the current process rather than trusting a captured
            // one: if a new run has begun, this timer belongs to nobody.
            guard let current = self.process, current === process,
                  current.isRunning
            else { return }
            kill(current.processIdentifier, SIGKILL)
        }
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

    /// Build a `MetricsSnapshot` from the current run's accumulator
    /// (per-FS counts/timing) plus app-only process resource usage,
    /// then hand it to the shared `MetricsClient` for the panel to
    /// render. Serves both socket-less backends: embedded runs
    /// report the delta against a pre-run baseline (SOLARO's own
    /// footprint excluded), XPC runs sample the service child's PID
    /// directly.
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
        let process: ProcessMetricsView
        let kind: String
        if let baseline = acc.baseline {
            // Embedded run: the app shares SOLARO's address space,
            // so absolute numbers would be IDE + app combined.
            // Report the delta against the pre-run baseline instead.
            // Clamped at 0 — memory SOLARO frees mid-run
            // (autorelease pools, purged caches) can push the raw
            // delta negative.
            kind = "embedded"
            let current = Self.currentProcessMetrics()
            process = ProcessMetricsView(
                cpuUserSec: max(0, current.cpuUserSec - baseline.cpuUserSec),
                cpuSystemSec: max(0, current.cpuSystemSec - baseline.cpuSystemSec),
                virtualMB: max(0, current.virtualMB - baseline.virtualMB),
                residentMB: max(0, current.residentMB - baseline.residentMB),
                openFDs: max(0, current.openFDs - baseline.openFDs)
            )
        } else {
            // XPC run: sample the AROXPCService child by PID —
            // absolute numbers are already app-only. If the service
            // is gone (final publish after a fast exit can race its
            // teardown), keep the last sampled values rather than
            // flashing zeros.
            kind = "xpc"
            process = xpcProxy?.servicePID
                .flatMap(Self.processMetrics(forPID:))
                ?? embeddedMetricsSnapshot?.process
                ?? ProcessMetricsView(cpuUserSec: 0, cpuSystemSec: 0,
                                      virtualMB: 0, residentMB: 0,
                                      openFDs: 0)
        }
        let snap = MetricsSnapshot(
            kind: kind,
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

    /// Sample another process's CPU + memory by PID via
    /// `proc_pidinfo(PROC_PIDTASKINFO)` — used for the XPC service
    /// child, which has no push socket of its own. Returns nil when
    /// the PID is gone (service exited); callers fall back to the
    /// last good sample. CPU totals arrive in Mach absolute time
    /// units and are converted through `mach_timebase_info`.
    private static func processMetrics(forPID pid: Int32) -> ProcessMetricsView? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.stride)
        let got = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDTASKINFO, 0, $0, size)
        }
        guard got == size else { return nil }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        func seconds(_ machUnits: UInt64) -> Double {
            Double(machUnits) * Double(timebase.numer)
                / Double(timebase.denom) / 1_000_000_000
        }
        // FD count via the list-FDs buffer size probe; best-effort —
        // a failed probe just reports 0.
        let fdBytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        let fdCount = fdBytes > 0
            ? Int(fdBytes) / MemoryLayout<proc_fdinfo>.stride
            : 0
        return ProcessMetricsView(
            cpuUserSec: seconds(info.pti_total_user),
            cpuSystemSec: seconds(info.pti_total_system),
            virtualMB: Double(info.pti_virtual_size) / 1024 / 1024,
            residentMB: Double(info.pti_resident_size) / 1024 / 1024,
            openFDs: fdCount
        )
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
        let defaultsPath = Preferences.aroOverride
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

    /// Drain the read-side of a pipe in the background, posting each
    /// *complete* line back via `onLine`. ANSI codes get stripped
    /// before the line lands in the UI.
    ///
    /// The pipe's own `ConsoleLineAssembler` carries a partial line
    /// from one read to the next, so a line longer than a chunk
    /// arrives as one entry, a chunk that splits a UTF-8 scalar
    /// isn't dropped, and an escape sequence can't leak its tail
    /// (GitLab #541). Blank lines are kept — they're part of what
    /// the program printed.
    nonisolated private func readPipe(_ pipe: Pipe,
                                      onLine: @Sendable @escaping (String) -> Void) {
        let handle = pipe.fileHandleForReading
        // One assembler per pipe, mutated only from that handle's
        // reader queue (FileHandle serialises its readability
        // callbacks), hence the unchecked box rather than a lock.
        let assembler = LineAssemblerBox()
        handle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                // EOF: emit the unterminated tail, then stop reading.
                assembler.flush().forEach(onLine)
                handle.readabilityHandler = nil
                return
            }
            assembler.append(data).forEach(onLine)
        }
    }

    /// Reference box so the escaping `@Sendable` readability handler
    /// can carry the assembler's state across reads. Confined to one
    /// FileHandle's serial reader queue.
    private final class LineAssemblerBox: @unchecked Sendable {
        private var assembler = ConsoleLineAssembler()
        func append(_ data: Data) -> [String] { assembler.append(data) }
        func flush() -> [String] { assembler.flush() }
    }

    /// Append one line, trimming the oldest half when the cap is hit.
    ///
    /// Not private so the bound itself can be tested (#751) — it is the
    /// only thing standing between a verbose run and unbounded memory.
    func appendLog(_ entry: LogEntry) {
        log.append(entry)
        if log.count > Self.logCap {
            log.removeFirst(log.count - Self.logCap / 2)
        }
    }

    private func appendLine(_ line: String, kind: LogEntry.Kind) {
        appendLog(LogEntry(kind: kind, text: line, timestamp: Date()))
        detectPause(in: line)
        if let hit = TestResultParser.match(line) {
            testResults[hit.name] = hit.result
            executionTick &+= 1
        }
    }

    /// Scan a freshly-logged line for the debugger's pause notice.
    /// Updates pausedLine, flips isPaused, and refreshes the live
    /// symbol table from the JSONL record.
    /// Whether this run has ever reported a pause through the structured
    /// event stream (#752).
    ///
    /// Once it has, the console-text parse below is switched off for the
    /// rest of the run: the two would otherwise both fire on the same
    /// pause, and the record is the one that is actually authoritative.
    private var sawStructuredPause = false

    /// Enter the paused state at `line` of `file`.
    ///
    /// Reached from the structured `pause` record, and from the console
    /// text as a fallback.
    private func enterPause(atLine line: Int) {
        pausedLine = line
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
           !breakpointLines.contains(line)
        {
            didAutoContinueFirstPause = true
            sendInput("c")
        }
    }

    /// Fallback pause detection, by reading the console text.
    ///
    /// This was the only mechanism (#752): match a `⏸` in a line of the
    /// child's stdout, find `" at "` and `" — "`, and take the integer
    /// after the last colon between them. So the debugger's correctness
    /// rested on the exact wording and emoji of a human-facing message in
    /// another binary — a CLI rewording would silently leave the Step
    /// buttons disabled forever, and a user program that printed a `⏸`
    /// could fake a pause. The structured record drives it now, and this
    /// remains only for a runtime too old to write one.
    private func detectPause(in line: String) {
        guard !sawStructuredPause else { return }
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
        enterPause(atLine: n)
    }

    /// Read the JSONL record file and capture the last pause event's
    /// symbol bag into `pauseSymbols` keyed by name. The record path
    /// is the same one we pass to `aro debug --record`.
    /// Symbols from the most recent pause seen on the live stream.
    ///
    /// `applyLiveBatch` already sees every record, pauses included, so the
    /// bag is here for free. It used to be fetched by reading and parsing the
    /// whole events file — once per step, on the main actor — against a file
    /// that grows for the length of the session, so stepping through a loop
    /// got slower the longer you stepped (GitLab #747).
    private var lastPauseSymbols: [String: SymbolValue]?

    private func refreshSymbolsFromRecord() {
        if let cached = lastPauseSymbols {
            pauseSymbols = cached
            return
        }

        // Fallback: no pause has come off the live stream yet. That happens
        // for the first pause of a subprocess debug session, where the
        // console line can beat the stream's poll.
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
        appendLog(LogEntry(kind: .info, text: line, timestamp: Date()))
    }

    private func appendError(_ line: String) {
        appendLog(LogEntry(kind: .error, text: line, timestamp: Date()))
    }

    /// Strip ANSI escape sequences. The grammar lives in
    /// `ANSIEscape` (GitLab #541) — this stays as the name the rest
    /// of SOLARO calls. A follow-up turns SGR into
    /// NSAttributedString attributes instead of dropping it.
    nonisolated static func stripANSI(_ input: String) -> String {
        ANSIEscape.strip(input)
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
                // Lazy, so appends during a run cost the rows on screen
                // rather than every row ever logged (#751).
                LazyVStack(alignment: .leading, spacing: 0) {
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
