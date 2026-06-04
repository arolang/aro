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

@MainActor
@Observable
final class ConsoleProcess {
    enum State: Equatable {
        case idle
        case running(pid: Int32)
        case exited(code: Int32)
        case failed(String)
    }

    /// Append-only log of captured stdout+stderr lines.
    var log: [LogEntry] = []
    var state: State = .idle
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

    struct SymbolValue: Equatable, Hashable {
        let name: String
        let typeName: String
        let value: String
    }

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdinPipe: Pipe?
    private var liveStream: LiveEventStream?
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

    /// Convenience for the Play button — always plain `aro run`,
    /// no breakpoints, no record file.
    func startRun(project: Project) {
        start(project: project, mode: .run, breakpointsByFile: [:])
    }

    /// Convenience for the Debug button — `aro debug` with whatever
    /// breakpoints the workspace has accumulated.
    func startDebug(project: Project, breakpointsByFile: [URL: Set<Int>]) {
        start(project: project, mode: .debug, breakpointsByFile: breakpointsByFile)
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
               breakpointsByFile: [URL: Set<Int>] = [:]) {
        if case .running = state { return }
        log.removeAll()
        pausedLine = nil
        isPaused = false
        pauseSymbols.removeAll(keepingCapacity: true)
        lastExecutedAt.removeAll(keepingCapacity: true)
        repositoryValues.removeAll(keepingCapacity: true)
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
            appendInfo("$ aro debug \(project.rootPath.lastPathComponent)  (breakpoints: \(lines))")
        case .run:
            // `--record` is on by default so SOLARO's canvas can
            // light up executing nodes and surface live values
            // without a separate "debug" mode.
            subArgs = ["run", project.rootPath.path,
                       "--record", recordPath(for: project)]
            appendInfo("$ aro run \(project.rootPath.lastPathComponent)")
        case .test(let filter):
            subArgs = ["test", project.rootPath.path]
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
        let stream = LiveEventStream(url: url) { [weak self] record in
            self?.applyLiveRecord(record)
        }
        liveStream = stream
        stream.start()
    }

    private func applyLiveRecord(_ record: TimeTravelRecord) {
        if let line = record.line, line > 0 {
            lastExecutedAt[line] = Date()
        }
        for sym in record.symbols {
            let value = SymbolValue(
                name: sym.name,
                typeName: sym.typeName,
                value: sym.value
            )
            pauseSymbols[sym.name] = value
            // Heuristic: if a symbol's name reads as a repository
            // entity, surface its current value on the repo card too.
            let lower = sym.name.lowercased()
            if lower.hasSuffix("-repository")
                || lower.hasSuffix("-repo")
                || lower.hasSuffix("-store")
            {
                repositoryValues[sym.name] = value
            }
        }
        executionTick &+= 1
    }

    /// Stop the running process; no-op when nothing is running.
    func stop() {
        liveStream?.stop()
        liveStream = nil
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
    func continueExecution() { sendInput("c") }
    /// Advance into the next statement (follows emits/calls).
    func stepInto()          { sendInput("s") }
    /// Advance over the next statement.
    func stepOver()          { sendInput("n") }
    /// Run until the current feature set returns.
    func finishFrame()       { sendInput("f") }
    /// Quit the debugger session.
    func quit()              { sendInput("q") }

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
        // checkout. We accept anywhere up to filesystem root.
        var dir = project.rootPath.deletingLastPathComponent()
        let configs = ["release", "debug"]
        for _ in 0..<8 {  // hard cap so we never recurse forever
            for cfg in configs {
                let candidate = dir.appendingPathComponent(".build/\(cfg)/aro").path
                if fm.isExecutableFile(atPath: candidate) {
                    return candidate
                }
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
