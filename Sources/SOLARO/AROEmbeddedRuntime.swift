// ============================================================
// AROEmbeddedRuntime.swift
// SOLARO — link the ARO runtime directly (issue #282 phase 1)
// ============================================================
//
// First cut at running an ARO project in-process inside SOLARO,
// instead of shelling out to `aro run --record` and tailing the
// JSONL events file.
//
// Goals (per issue #282):
//   * Pre/post hooks on every statement without a JSON round-trip.
//   * The same wire schema we already feed the canvas, so the
//     downstream pipeline (`applyLiveBatch`, `lastExecutedAt`,
//     `pauseSymbols`, the FS glow, the repo card history) keeps
//     working unchanged.
//   * Opt-in for now — set `SOLARO_EMBEDDED_RUNTIME=1` in the
//     environment to switch the Run button from subprocess to
//     embedded. The subprocess path stays the default until the
//     embedded host has soaked.
//
// Out of scope for phase 1:
//   * Step-over / step-into UX over the in-process controller —
//     reuses the existing CLI-driven flow for Debug mode.
//   * stdout / stderr capture into the SOLARO console — embedded
//     prints go to the SOLARO process's real stdout.
//   * Crash isolation. A bad ARO program crashes SOLARO too.
//     Move to XPC if we want to fix that — tracked in issue #282.

import Foundation
import AROParser
import ARORuntime

/// `DebugFrontend` that converts every `PauseInfo` the runtime emits
/// into a `TimeTravelRecord` and forwards it to the host. Always
/// returns `.stepOver` so the runtime keeps firing checkpoints for
/// every statement — that's how we keep the canvas pulse live.
final class EmbeddedRuntimeFrontend: DebugFrontend, @unchecked Sendable {

    let onPause: @Sendable (TimeTravelRecord) -> Void
    let onEnd: @Sendable (Error?) -> Void
    private let startedAt = Date()
    /// Tracks the most recent line a regular checkpoint fired for.
    /// `errorCheckpoint()` from the runtime arrives with `file=""`,
    /// `line=0` (it's a statement-failure hook, not a source position),
    /// so we need this lookback to point the canvas's error badge at
    /// the actual offending node.
    private var lastCheckpointLine: Int = 0
    private var lastCheckpointFile: String? = nil
    private let trackingQueue = DispatchQueue(label: "com.arolang.solaro.EmbeddedFrontend")

    init(
        onPause: @escaping @Sendable (TimeTravelRecord) -> Void,
        onEnd: @escaping @Sendable (Error?) -> Void
    ) {
        self.onPause = onPause
        self.onEnd = onEnd
    }

    func didPause(
        _ pause: PauseInfo,
        controller: DebugController
    ) async -> StepMode {
        // Snapshot the running line so a subsequent errorCheckpoint
        // (no line of its own) can be attributed to the right node.
        if case .error = pause.reason {
            // Errors fall through to record-building below.
        } else if pause.line > 0 {
            trackingQueue.sync {
                lastCheckpointLine = pause.line
                lastCheckpointFile = pause.file.isEmpty ? nil : pause.file
            }
        }
        let record = Self.makeRecord(
            from: pause,
            startedAt: startedAt,
            fallbackLine: trackingQueue.sync { lastCheckpointLine },
            fallbackFile: trackingQueue.sync { lastCheckpointFile }
        )
        onPause(record)
        // Keep stepping. Returning `.continue` here would shut off
        // every subsequent checkpoint — the canvas would only flash
        // the very first statement.
        return .stepOver
    }

    func didEnd(error: Error?) async {
        onEnd(error)
    }

    private static func makeRecord(
        from pause: PauseInfo,
        startedAt: Date,
        fallbackLine: Int,
        fallbackFile: String?
    ) -> TimeTravelRecord {
        let symbols = pause.symbols.map {
            TimeTravelRecord.Symbol(
                name: $0.name,
                typeName: $0.typeName,
                value: $0.valuePreview
            )
        }
        // Errors arrive without a source location of their own; reuse
        // the most recent checkpointed line so the canvas can paint a
        // red border on the failing statement.
        let isError: Bool
        if case .error = pause.reason { isError = true } else { isError = false }
        let line: Int?
        let file: String?
        if isError {
            line = pause.line > 0 ? pause.line : (fallbackLine > 0 ? fallbackLine : nil)
            file = pause.file.isEmpty ? fallbackFile : pause.file
        } else {
            line = pause.line > 0 ? pause.line : nil
            file = pause.file.isEmpty ? nil : pause.file
        }
        return TimeTravelRecord(
            time: Date().timeIntervalSince(startedAt),
            kind: isError ? .error : .pause,
            featureSet: pause.featureSetName,
            file: file,
            line: line,
            column: pause.column > 0 ? pause.column : nil,
            statement: pause.statementSummary,
            verb: pause.verb,
            reason: String(describing: pause.reason),
            symbols: symbols
        )
    }
}

/// Drives an ARO project in-process — discover → compile → run,
/// with a `DebugController` installed so every statement boundary
/// hands us a `PauseInfo` we can stream to the canvas.
///
/// The host owns one in-flight run at a time. `start` is a no-op
/// while a run is in progress; call `stop` first.
@MainActor
final class EmbeddedRuntimeHost {

    /// Read by the rest of SOLARO so it can pick the embedded vs.
    /// subprocess path. Drains through `RuntimeBackend.current`,
    /// which consults the user's Settings → Backends choice first,
    /// falls back to the `SOLARO_EMBEDDED_RUNTIME=1` env var, and
    /// defaults to embedded for fresh installs.
    static var isEnabled: Bool {
        RuntimeBackend.current == .embedded
    }

    /// Called for each new event the runtime produces. Same shape
    /// `LiveEventStream` delivers so the receiver doesn't care
    /// which transport was used.
    var onRecords: (([TimeTravelRecord]) -> Void)?
    /// Called when the run ends (cleanly, with an error, or because
    /// `stop` was invoked). Roughly equivalent to the subprocess
    /// path's `terminationHandler`.
    var onEnded: ((Error?) -> Void)?
    /// Loose stdout-style sink — printed messages from the host
    /// itself (not from the running ARO program; those still go
    /// to the SOLARO process's real stdout).
    var onLog: ((String) -> Void)?

    private(set) var isRunning: Bool = false
    private var runTask: Task<Void, Never>?
    private var pendingRecords: [TimeTravelRecord] = []
    /// Schedules the batched delivery so a hot statement loop turns
    /// into one canvas redraw per runloop tick instead of one per
    /// record.
    private var flushScheduled: Bool = false

    /// Spawn an in-process run of `project`. The closure that hops
    /// through `Debug.$controller.withValue` runs on a detached task
    /// so the SOLARO main actor stays responsive while the program
    /// is doing its thing.
    func start(project: Project) {
        guard !isRunning else { return }
        isRunning = true
        let path = project.rootPath
        log("[embedded] starting in-process run of \(path.lastPathComponent)")

        let frontend = EmbeddedRuntimeFrontend(
            onPause: { [weak self] record in
                Task { @MainActor [weak self] in
                    self?.enqueue(record)
                }
            },
            onEnd: { [weak self] error in
                Task { @MainActor [weak self] in
                    self?.finish(error: error)
                }
            }
        )
        let controller = DebugController(frontend: frontend)

        runTask = Task.detached(priority: .userInitiated) { [weak self] in
            // Install `.errorAny` so the runtime's `errorCheckpoint`
            // actually fires `didPause`; without this the embedded
            // frontend never sees runtime failures and the canvas
            // can't paint the failed node's red border.
            await controller.addBreakpoint(.errorAny)
            do {
                try await Self.runProject(at: path, controller: controller)
            } catch is DebuggerQuit {
                await frontend.didEnd(error: nil)
            } catch {
                await frontend.didEnd(error: error)
                await MainActor.run { [weak self] in
                    self?.log("[embedded] run failed: \(error)")
                }
                return
            }
            await frontend.didEnd(error: nil)
            _ = self  // silence unused capture warning when log is gone
        }
    }

    /// Cancel the in-flight run. The runtime unwinds at the next
    /// statement boundary (which may take a moment for a tight
    /// computation loop, since cancellation is cooperative).
    func stop() {
        guard isRunning else { return }
        log("[embedded] stop requested")
        runTask?.cancel()
    }

    private func enqueue(_ record: TimeTravelRecord) {
        pendingRecords.append(record)
        if !flushScheduled {
            flushScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.flushScheduled = false
                guard !self.pendingRecords.isEmpty else { return }
                let batch = self.pendingRecords
                self.pendingRecords.removeAll(keepingCapacity: true)
                self.onRecords?(batch)
            }
        }
    }

    private func finish(error: Error?) {
        guard isRunning else { return }
        isRunning = false
        runTask = nil
        // Flush anything still buffered before signaling end so the
        // canvas's final state matches the runtime's.
        if !pendingRecords.isEmpty {
            let batch = pendingRecords
            pendingRecords.removeAll(keepingCapacity: true)
            onRecords?(batch)
        }
        onEnded?(error)
    }

    private func log(_ message: String) {
        onLog?(message)
    }

    /// Mirrors the discovery → compile → run pipeline in
    /// `AROCLI.RunCommand` but condensed to what SOLARO needs.
    /// Detached so the calling context isn't bound to MainActor.
    private static func runProject(
        at path: URL,
        controller: DebugController
    ) async throws {
        let discovery = ApplicationDiscovery()
        let appConfig = try await discovery.discoverWithImports(
            at: path, entryPoint: "Application-Start"
        )

        let compiler = Compiler()
        var compiledPrograms: [AnalyzedProgram] = []
        for sourceFile in appConfig.sourceFiles {
            let source = try String(contentsOf: sourceFile, encoding: .utf8)
            let result = compiler.compile(source)
            if result.isSuccess {
                compiledPrograms.append(result.analyzedProgram)
            } else {
                let errs = result.diagnostics.filter { $0.severity == .error }
                if let first = errs.first {
                    throw EmbeddedRuntimeError.compilationFailed(
                        file: sourceFile.lastPathComponent,
                        message: "\(first)"
                    )
                }
            }
        }

        try? UnifiedPluginLoader.shared.loadPlugins(from: appConfig.rootPath)

        let application = Application(
            programs: compiledPrograms,
            entryPoint: "Application-Start",
            config: ApplicationConfig(
                verbose: false,
                workingDirectory: appConfig.rootPath.path
            ),
            openAPISpec: appConfig.openAPISpec,
            replayPath: nil,
            storeFiles: appConfig.storeFiles
        )

        try await Debug.$controller.withValue(controller) {
            _ = try await application.run()
        }
    }
}

enum EmbeddedRuntimeError: Error, LocalizedError {
    case compilationFailed(file: String, message: String)

    var errorDescription: String? {
        switch self {
        case .compilationFailed(let file, let msg):
            return "compilation failed in \(file): \(msg)"
        }
    }
}
