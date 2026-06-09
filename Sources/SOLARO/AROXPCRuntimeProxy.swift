// ============================================================
// AROXPCRuntimeProxy.swift
// SOLARO — proxy over the out-of-process AROXPCService (#282 phase 3)
// ============================================================
//
// Mirrors `EmbeddedRuntimeHost`'s API surface so the rest of
// SOLARO (Console / Workspace / toolbar) can swap between the
// in-process and out-of-process backends through `RuntimeBackend`
// without per-call branching.
//
// Spawns the AROXPCService binary as a child Process, talks
// framed JSON over stdin/stdout, and turns received AROXPCEvents
// back into the same callback shape the in-process host exposes
// (`onRecords`, `onEnded`, `onLog`).

import Foundation
import AROXPCProtocol

@MainActor
final class AROXPCRuntimeProxy {
    var onRecords: (([TimeTravelRecord]) -> Void)?
    var onEnded: ((Error?) -> Void)?
    var onLog: ((String) -> Void)?

    private(set) var isRunning: Bool = false
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var readBuffer = Data()
    private var currentRunID: String?
    /// Tracks whether the runtime is currently parked on a
    /// breakpoint so the SOLARO toolbar's step buttons can
    /// gate on it the same way the in-process path does.
    private(set) var isPausedAtBreakpoint: Bool = false

    /// Path to the AROXPCService binary. Resolution order:
    ///
    /// 1. `AROXPC_SERVICE` env override (devs pointing at a
    ///    custom build).
    /// 2. The .app bundle's `Resources/AROXPCService` — what
    ///    end users hit. The bundle script copies it there.
    /// 3. Newest-by-mtime under `.build/{release,debug}/` going
    ///    up from the project root — devs running an uninstalled
    ///    build; mirrors `resolveAroBinary`'s behaviour so
    ///    rebuilds always win.
    static func resolveServiceBinary(near project: Project) -> String? {
        let fm = FileManager.default
        if let envPath = ProcessInfo.processInfo
            .environment["AROXPC_SERVICE"], !envPath.isEmpty,
           fm.isExecutableFile(atPath: envPath) {
            return envPath
        }
        // Bundle-local copy — the release/distribution path.
        if let bundleResources = Bundle.main.resourceURL {
            let candidate = bundleResources
                .appendingPathComponent("AROXPCService").path
            if fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        // Project-adjacent build artifacts, newest mtime wins.
        var dir = project.rootPath.deletingLastPathComponent()
        for _ in 0..<8 {
            var candidates: [(path: String, mtime: Date)] = []
            for cfg in ["release", "debug"] {
                let candidate = dir
                    .appendingPathComponent(".build/\(cfg)/AROXPCService")
                    .path
                if fm.isExecutableFile(atPath: candidate) {
                    let mtime = (try? fm
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
        return nil
    }

    func start(project: Project, entryPoint: String = "Application-Start") {
        guard !isRunning else { return }
        guard let binary = Self.resolveServiceBinary(near: project) else {
            onLog?("[XPC] service binary not found — build the AROXPCService product first")
            onEnded?(NSError(domain: "AROXPCRuntimeProxy", code: 1,
                              userInfo: [NSLocalizedDescriptionKey:
                                "service binary missing"]))
            return
        }
        isRunning = true
        let runID = UUID().uuidString
        currentRunID = runID
        let task = Process()
        task.executableURL = URL(fileURLWithPath: binary)
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        task.standardInput = stdin
        task.standardOutput = stdout
        task.standardError = stderr
        process = task
        stdinPipe = stdin
        stdoutPipe = stdout
        readBuffer.removeAll()

        stdout.fileHandleForReading.readabilityHandler = {
            [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            Task { @MainActor [weak self] in
                self?.ingest(data)
            }
        }
        stderr.fileHandleForReading.readabilityHandler = {
            [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let line = String(data: data, encoding: .utf8) else {
                return
            }
            Task { @MainActor [weak self] in
                self?.onLog?("[XPC] \(line)")
            }
        }
        task.terminationHandler = { [weak self] proc in
            Task { @MainActor [weak self] in
                self?.handleTermination(status: proc.terminationStatus)
            }
        }

        do {
            try task.run()
        } catch {
            isRunning = false
            onEnded?(error)
            return
        }

        send(.run(runID: runID,
                  projectPath: project.rootPath.path,
                  entryPoint: entryPoint,
                  embeddedConsole: true))
    }

    func stop() {
        guard isRunning, let runID = currentRunID else { return }
        send(.stop(runID: runID))
        process?.terminate()
    }

    func continueExecution() { sendStep(.stepContinue) }
    func stepOver()          { sendStep(.stepOver) }
    func stepIn()            { sendStep(.stepIn) }
    func stepOut()           { sendStep(.stepOut) }

    private enum StepVerb { case stepContinue, stepOver, stepIn, stepOut }

    private func sendStep(_ verb: StepVerb) {
        guard let runID = currentRunID else { return }
        switch verb {
        case .stepContinue: send(.stepContinue(runID: runID))
        case .stepOver:     send(.stepOver(runID: runID))
        case .stepIn:       send(.stepIn(runID: runID))
        case .stepOut:      send(.stepOut(runID: runID))
        }
        isPausedAtBreakpoint = false
    }

    private func send(_ request: AROXPCRequest) {
        guard let stdinPipe else { return }
        do {
            let frame = try AROXPCFraming.encode(request)
            try stdinPipe.fileHandleForWriting.write(contentsOf: frame)
        } catch {
            onLog?("[XPC] write failed: \(error)")
        }
    }

    private func ingest(_ data: Data) {
        readBuffer.append(data)
        let decoder = JSONDecoder()
        while let payload = AROXPCFraming.nextPayload(in: &readBuffer) {
            do {
                let event = try decoder.decode(AROXPCEvent.self,
                                               from: payload)
                handle(event)
            } catch {
                onLog?("[XPC] decode error: \(error)")
            }
        }
    }

    private func handle(_ event: AROXPCEvent) {
        switch event {
        case .ready(let handshake):
            // Service mismatch → log + end the run; SOLARO falls
            // back to the in-process path if the user clicks Run
            // again after fixing it.
            if handshake.protocolVersion != AROXPCProtocolVersion.current {
                onLog?("[XPC] protocol mismatch — service v\(handshake.protocolVersion) vs SOLARO v\(AROXPCProtocolVersion.current)")
            }
        case .started:
            break
        case .pause(_, let record):
            if record.kind == .breakpoint {
                isPausedAtBreakpoint = true
            }
            onRecords?([Self.timeTravel(from: record)])
        case .pauseBatch(_, let records):
            // Batched form (#282 phase 3). Service combines per-
            // checkpoint records into one frame; we flatten the
            // map back into the existing single-batch callback
            // so the canvas redraws once per batch instead of
            // per record.
            let mapped = records.map(Self.timeTravel)
            onRecords?(mapped)
        case .consoleOutput(_, let line, _):
            onLog?(line)
        case .log(_, let message):
            onLog?(message)
        case .ended(_, let error):
            isPausedAtBreakpoint = false
            if let error {
                onEnded?(NSError(domain: "AROXPCRuntimeProxy",
                                 code: 2,
                                 userInfo: [NSLocalizedDescriptionKey: error]))
            } else {
                onEnded?(nil)
            }
            currentRunID = nil
            isRunning = false
        }
    }

    private func handleTermination(status: Int32) {
        guard isRunning else { return }
        isRunning = false
        isPausedAtBreakpoint = false
        let err: Error? = status == 0
            ? nil
            : NSError(domain: "AROXPCRuntimeProxy", code: 3,
                      userInfo: [NSLocalizedDescriptionKey:
                        "XPC service exited with status \(status)"])
        onEnded?(err)
        currentRunID = nil
    }

    /// Maps the wire-format pause record into the same
    /// `TimeTravelRecord` shape SOLARO's live-event consumers
    /// already understand.
    private static func timeTravel(
        from record: AROXPCPauseRecord
    ) -> TimeTravelRecord {
        let symbols = record.symbols.map {
            TimeTravelRecord.Symbol(name: $0.name,
                                    typeName: $0.typeName,
                                    value: $0.value,
                                    records: $0.records)
        }
        let kind: TimeTravelRecord.Kind
        switch record.kind {
        case .pause:      kind = .pause
        case .error:      kind = .error
        case .event:      kind = .pause
        case .breakpoint: kind = .pause
        }
        let metrics = record.metrics.map {
            TimeTravelRecord.Metrics(
                elapsedNanos: $0.elapsedNanos,
                residentMemoryBytes: $0.residentMemoryBytes
            )
        }
        return TimeTravelRecord(
            time: record.time,
            kind: kind,
            featureSet: record.featureSet,
            file: record.file,
            line: record.line,
            column: record.column,
            statement: record.statement,
            verb: record.verb,
            reason: record.reason,
            symbols: symbols,
            metrics: metrics
        )
    }
}
