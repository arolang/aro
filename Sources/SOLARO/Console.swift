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

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdinPipe: Pipe?
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
    func start(project: Project, breakpointsByFile: [URL: Set<Int>] = [:]) {
        if case .running = state { return }
        log.removeAll()

        // Aggregate every file's breakpoints into a single `--breakpoint`
        // list. The debugger accepts line numbers as "filename:line"
        // pairs as well as bare integers; we pass the bare form when
        // there's only one file to keep the command terse.
        let lines = breakpointsByFile.values.flatMap { $0 }.sorted()
        let useDebugger = !lines.isEmpty

        let aro = Self.resolveAroBinary(near: project)
        appendInfo("[aro] \(aro)")

        // Build the subcommand portion of the argv.
        var subArgs: [String]
        if useDebugger {
            subArgs = ["debug", project.rootPath.path,
                       "--record", recordPath(for: project)]
            for line in lines {
                subArgs.append("--breakpoint")
                subArgs.append(String(line))
            }
            appendInfo("$ aro debug \(project.rootPath.lastPathComponent)  (breakpoints: \(lines))")
        } else {
            subArgs = ["run", project.rootPath.path]
            appendInfo("$ aro run \(project.rootPath.lastPathComponent)")
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
            }
        }

        do {
            try task.run()
            process = task
            state = .running(pid: task.processIdentifier)
        } catch {
            state = .failed(error.localizedDescription)
            appendError(error.localizedDescription)
        }
    }

    /// Stop the running process; no-op when nothing is running.
    func stop() {
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
    }

    /// Where `--record` writes its JSONL stream for time-travel
    /// playback in the Time-Travel view.
    private func recordPath(for project: Project) -> String {
        project.rootPath.appendingPathComponent(".solaro/events.jsonl").path
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

    /// Scan a freshly-logged line for the debugger's pause notice
    /// and bump `pausedLine` so the workspace can jump the caret.
    private func detectPause(in line: String) {
        guard line.contains("⏸") else { return }
        // The TUI prints "⏸  paused (reason) at file.aro:N — FeatureSet".
        // We pull the number right after the last `:` in the
        // `at <where>` segment.
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
    }

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
        Circle()
            .fill(pipColor)
            .frame(width: 8, height: 8)
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

    private func color(for kind: ConsoleProcess.LogEntry.Kind) -> Color {
        switch kind {
        case .stdout: return SolaroColor.textPrimary
        case .stderr: return SolaroColor.stateError
        case .info:   return SolaroColor.accent
        case .error:  return SolaroColor.stateError
        }
    }
}
