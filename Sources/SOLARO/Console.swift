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

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    struct LogEntry: Identifiable, Equatable {
        let id = UUID()
        let kind: Kind
        let text: String
        let timestamp: Date

        enum Kind { case stdout, stderr, info, error }
    }

    /// Spawn `aro run <project>`. No-op when a process is already
    /// running; call `stop()` first if you want to restart.
    func start(project: Project) {
        if case .running = state { return }
        log.removeAll()
        appendInfo("$ aro run \(project.rootPath.lastPathComponent)")

        let task = Process()
        // `/usr/bin/env` resolves `aro` against $PATH so the install
        // location doesn't have to be hard-coded.
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["aro", "run", project.rootPath.path]
        task.currentDirectoryURL = project.rootPath

        let stdout = Pipe()
        let stderr = Pipe()
        task.standardOutput = stdout
        task.standardError = stderr
        stdoutPipe = stdout
        stderrPipe = stderr

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

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(SolaroColor.divider)
            logView
        }
        .frame(maxWidth: .infinity)
        .background(SolaroColor.surface)
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
