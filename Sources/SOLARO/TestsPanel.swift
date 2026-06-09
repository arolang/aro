// ============================================================
// TestsPanel.swift
// SOLARO — bottom-panel "Tests" tab with pass/fail tree (#271)
// ============================================================
//
// MVP: runs `aro test` via the existing ConsoleProcess, parses
// the streaming output for ✓ / ✗ markers, and shows results as
// a flat list of test names with status pips. The richer
// suite-grouped tree + per-line gutter pips can grow on top of
// this when the runner's output format stabilises.

import SwiftUI
import Foundation

@MainActor
@Observable
final class TestRunModel {
    enum Status { case unknown, passed, failed, skipped }

    struct Result: Identifiable, Equatable {
        let id = UUID()
        let name: String
        let status: Status
        let suite: String?
    }

    var results: [Result] = []
    /// True while a run is in flight — Run button disables.
    private(set) var isRunning: Bool = false
    private var process: Process?
    private var stdoutPipe: Pipe?
    /// Rolling buffer of partial output. Owned by the main actor;
    /// readabilityHandler chunks hop here before being parsed.
    private var pendingOutput: String = ""

    var passCount: Int  { results.filter { $0.status == .passed }.count }
    var failCount: Int  { results.filter { $0.status == .failed }.count }
    var skipCount: Int  { results.filter { $0.status == .skipped }.count }

    func run(project: Project) {
        cancel()
        results = []
        isRunning = true
        let aro = ConsoleProcess.resolveAroBinary(near: project)
        let task = Process()
        if aro == "/usr/bin/env" {
            task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            task.arguments = ["aro", "test", project.rootPath.path]
        } else {
            task.executableURL = URL(fileURLWithPath: aro)
            task.arguments = ["test", project.rootPath.path]
        }
        task.currentDirectoryURL = project.rootPath

        let stdout = Pipe()
        let stderr = Pipe()
        task.standardOutput = stdout
        task.standardError = stderr
        stdoutPipe = stdout

        pendingOutput = ""
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let text = String(data: data, encoding: .utf8) else { return }
            let cleaned = ConsoleProcess.stripANSI(text)
            Task { @MainActor [weak self] in
                self?.appendChunk(cleaned)
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData   // drain so pipe doesn't block
        }
        task.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isRunning = false
                self?.process = nil
            }
        }
        do {
            try task.run()
            process = task
        } catch {
            isRunning = false
            results.append(.init(
                name: "Could not launch `aro test`: \(error.localizedDescription)",
                status: .failed, suite: nil
            ))
        }
    }

    func cancel() {
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        isRunning = false
    }

    /// Append a stdout chunk and flush every complete line to
    /// `ingest`. Always called on the main actor.
    private func appendChunk(_ chunk: String) {
        pendingOutput += chunk
        while let nl = pendingOutput.firstIndex(of: "\n") {
            let line = String(pendingOutput[..<nl])
            pendingOutput = String(pendingOutput[pendingOutput.index(after: nl)...])
            ingest(line)
        }
    }

    /// Parse a single output line. Looks for status glyphs:
    /// `✓ <name>` / `✗ <name>` / `~ <name>` (skipped). Lines that
    /// don't match are ignored.
    private func ingest(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let status: Status
        let body: String
        if trimmed.hasPrefix("✓") || trimmed.hasPrefix("PASS") {
            status = .passed
            body = stripPrefix(trimmed)
        } else if trimmed.hasPrefix("✗") || trimmed.hasPrefix("FAIL") {
            status = .failed
            body = stripPrefix(trimmed)
        } else if trimmed.hasPrefix("~") || trimmed.hasPrefix("SKIP") {
            status = .skipped
            body = stripPrefix(trimmed)
        } else {
            return
        }
        results.append(Result(name: body, status: status, suite: nil))
    }

    private func stripPrefix(_ line: String) -> String {
        var s = line
        for prefix in ["✓", "✗", "~", "PASS:", "FAIL:", "SKIP:", "PASS", "FAIL", "SKIP"] {
            if s.hasPrefix(prefix) {
                s = String(s.dropFirst(prefix.count))
                break
            }
        }
        return s.trimmingCharacters(in: .whitespaces)
    }
}

struct TestsPanel: View {
    let project: Project
    @Bindable var model: TestRunModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .background(SolaroColor.surface)
    }

    private var header: some View {
        HStack(spacing: SolaroSpace.s) {
            Button {
                model.run(project: project)
            } label: {
                if model.isRunning {
                    Label("Running…", systemImage: "stop.fill")
                } else {
                    Label("Run tests", systemImage: "play.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(model.isRunning)

            statusChip("✓ \(model.passCount)", SolaroColor.stateOK)
            statusChip("✗ \(model.failCount)", SolaroColor.stateError)
            if model.skipCount > 0 {
                statusChip("~ \(model.skipCount)", SolaroColor.stateWarn)
            }
            Spacer()
            if model.isRunning {
                Button("Cancel") { model.cancel() }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, SolaroSpace.m)
        .padding(.vertical, SolaroSpace.s)
    }

    private func statusChip(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(SolaroFont.monoCaption)
            .foregroundStyle(color)
    }

    @ViewBuilder
    private var content: some View {
        if model.results.isEmpty {
            VStack(spacing: SolaroSpace.s) {
                Spacer()
                Text("Press Run to invoke `aro test`.")
                    .font(SolaroFont.caption)
                    .foregroundStyle(SolaroColor.textTertiary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.results) { result in
                        row(result)
                        Divider()
                    }
                }
            }
        }
    }

    private func row(_ result: TestRunModel.Result) -> some View {
        HStack(spacing: SolaroSpace.s) {
            Image(systemName: symbol(for: result.status))
                .foregroundStyle(color(for: result.status))
                .frame(width: 14)
            Text(result.name)
                .font(SolaroFont.mono)
                .foregroundStyle(SolaroColor.textPrimary)
                .textSelection(.enabled)
            Spacer()
        }
        .padding(.horizontal, SolaroSpace.m)
        .padding(.vertical, 4)
    }

    private func symbol(for status: TestRunModel.Status) -> String {
        switch status {
        case .passed:  return "checkmark.circle.fill"
        case .failed:  return "xmark.circle.fill"
        case .skipped: return "circle.dotted"
        case .unknown: return "circle"
        }
    }

    private func color(for status: TestRunModel.Status) -> Color {
        switch status {
        case .passed:  return SolaroColor.stateOK
        case .failed:  return SolaroColor.stateError
        case .skipped: return SolaroColor.stateWarn
        case .unknown: return SolaroColor.textTertiary
        }
    }
}
