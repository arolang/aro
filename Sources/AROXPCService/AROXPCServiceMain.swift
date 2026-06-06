// ============================================================
// main.swift
// AROXPCService — out-of-process ARO runtime host (#282 phase 3)
// ============================================================
//
// Loop:
//   1. Send the handshake on stdout.
//   2. Read framed AROXPCRequest values off stdin.
//   3. For `run`, spin up an ARORuntime Application, stream
//      AROXPCEvent.pause records back through stdout, and end
//      with `ended`.
//   4. For `stop`, cancel the in-flight run.
//   5. Step verbs forward to a parked frontend continuation
//      (mirrors AROEmbeddedRuntimeFrontend's logic).
//
// stdin / stdout is the simplest framing — NSXPCConnection has
// a richer surface but Swift Concurrency interop is awkward.
// SOLARO spawns the service as a child Process and pipes both
// FDs through.

import Foundation
import AROVersion
import AROParser
import ARORuntime
import AROXPCProtocol

// MARK: - Wire IO

let stdin = FileHandle.standardInput
let stdout = FileHandle.standardOutput
let stderr = FileHandle.standardError

func send(_ event: AROXPCEvent) {
    do {
        let frame = try AROXPCFraming.encode(event)
        try stdout.write(contentsOf: frame)
    } catch {
        try? stderr.write(contentsOf:
            Data("[AROXPCService] failed to emit event: \(error)\n".utf8))
    }
}

// MARK: - Service state

@MainActor
final class Service {
    private var runTask: Task<Void, Never>?
    private var currentApplication: Application?
    private var currentFrontend: ServiceFrontend?

    func handle(_ request: AROXPCRequest) {
        switch request {
        case .handshake:
            send(.ready(handshake: AROXPCHandshakeReply(
                protocolVersion: AROXPCProtocolVersion.current,
                serviceVersion: AROVersion.shortVersion,
                pid: ProcessInfo.processInfo.processIdentifier
            )))
        case let .run(runID, projectPath, entryPoint, _embeddedConsole):
            _ = _embeddedConsole
            start(runID: runID, projectPath: projectPath, entryPoint: entryPoint)
        case .stop(let runID):
            stop(runID: runID)
        case .stepContinue(let runID): resume(runID: runID, mode: .continue)
        case .stepOver(let runID):     resume(runID: runID, mode: .stepOver)
        case .stepIn(let runID):       resume(runID: runID, mode: .stepIn)
        case .stepOut(let runID):      resume(runID: runID, mode: .stepOut)
        }
    }

    private func start(runID: String, projectPath: String, entryPoint: String) {
        guard runTask == nil else {
            send(.log(runID: runID,
                      message: "[AROXPCService] another run is already in flight"))
            return
        }
        send(.started(runID: runID))

        let frontend = ServiceFrontend(runID: runID)
        currentFrontend = frontend
        let controller = DebugController(frontend: frontend)

        let path = URL(fileURLWithPath: projectPath)
        let weakBox = ServiceWeakBox(service: self)
        runTask = Task.detached(priority: .userInitiated) {
            await controller.addBreakpoint(.errorAny)
            do {
                try await ConsoleObject.$sink.withValue({ message in
                    send(.consoleOutput(runID: runID,
                                        line: message,
                                        isError: false))
                }) {
                    try await Self.runProject(
                        at: path,
                        entryPoint: entryPoint,
                        controller: controller,
                        onApplication: { app in
                            Task { @MainActor in
                                weakBox.service?.currentApplication = app
                            }
                        }
                    )
                }
                await MainActor.run {
                    weakBox.service?.finish(runID: runID, error: nil)
                }
            } catch {
                let msg = "\(error)"
                await MainActor.run {
                    weakBox.service?.finish(runID: runID, error: msg)
                }
            }
        }
    }

    /// Sendable weak ref so the detached run task can call back
    /// into the @MainActor Service without triggering capture
    /// errors. The closure runs on a non-isolated executor; the
    /// box just hands the reference through.
    @MainActor
    private final class ServiceWeakBox: Sendable {
        weak var service: Service?
        init(service: Service) { self.service = service }
    }

    private func resume(runID: String, mode: StepMode) {
        currentFrontend?.resume(with: mode)
    }

    private func stop(runID: String) {
        currentFrontend?.resume(with: .continue)
        runTask?.cancel()
        if let app = currentApplication {
            Task.detached { await app.stopAsync() }
        }
    }

    private func finish(runID: String, error: String?) {
        // Make sure no buffered batch is left behind — would
        // otherwise show up as missing pulses on the canvas after
        // a successful run.
        currentFrontend?.flushRemainingBatch()
        if let app = currentApplication {
            currentApplication = nil
            Task.detached { await app.stopAsync() }
        }
        currentFrontend = nil
        runTask = nil
        send(.ended(runID: runID, error: error))
    }

    private static func runProject(
        at path: URL,
        entryPoint: String,
        controller: DebugController,
        onApplication: @Sendable (Application) -> Void
    ) async throws {
        let discovery = ApplicationDiscovery()
        let appConfig = try await discovery.discoverWithImports(
            at: path, entryPoint: entryPoint
        )
        let compiler = Compiler()
        var compiledPrograms: [AnalyzedProgram] = []
        for sourceFile in appConfig.sourceFiles {
            let source = try String(contentsOf: sourceFile, encoding: .utf8)
            let result = compiler.compile(source)
            if result.isSuccess {
                compiledPrograms.append(result.analyzedProgram)
            } else if let first = result.diagnostics
                .first(where: { $0.severity == .error }) {
                throw NSError(
                    domain: "AROXPCService",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey:
                        "compilation failed in \(sourceFile.lastPathComponent): \(first)"]
                )
            }
        }
        // Plugin loading happens inside the service process so a
        // segfaulting C plugin takes the service down, not SOLARO
        // (#282 phase 3 — option C rationale). The loader is the
        // same UnifiedPluginLoader the CLI uses, so any plugin
        // that works under `aro run` works here.
        do {
            try UnifiedPluginLoader.shared
                .loadPlugins(from: appConfig.rootPath)
        } catch {
            try? stderr.write(contentsOf: Data(
                "[AROXPCService] plugin load failed: \(error)\n".utf8
            ))
        }

        let app = Application(
            programs: compiledPrograms,
            entryPoint: entryPoint,
            config: ApplicationConfig(
                verbose: false,
                workingDirectory: appConfig.rootPath.path
            ),
            openAPISpec: appConfig.openAPISpec,
            replayPath: nil,
            storeFiles: appConfig.storeFiles
        )
        onApplication(app)
        try await Debug.$controller.withValue(controller) {
            _ = try await app.run()
        }
    }
}

// MARK: - Frontend

/// XPC-flavoured frontend that wraps every PauseInfo into an
/// AROXPCPauseRecord, ships it across the wire, and parks on a
/// CheckedContinuation when the runtime hits a breakpoint —
/// mirrors the SOLARO-side EmbeddedRuntimeFrontend logic.
final class ServiceFrontend: DebugFrontend, @unchecked Sendable {
    let runID: String
    private let startedAt = Date()
    private let lock = NSLock()
    private var pending: CheckedContinuation<StepMode, Never>?
    /// Coalesces pause records into batches before they hit the
    /// wire (#282 phase 3 — batching). Single records still go
    /// out individually if the buffer doesn't accumulate before
    /// a flush; the goal is to fold hot loops, not delay first
    /// pulses.
    private var batchBuffer: [AROXPCPauseRecord] = []
    private let batchLock = NSLock()
    private var batchScheduled = false
    private let batchQueue = DispatchQueue(
        label: "com.arolang.AROXPCService.batch"
    )
    /// Batch hold window. 1 ms is enough to fold ~95 % of the
    /// records emitted by a tight Compute loop while staying
    /// well below the human visual threshold (~100 ms).
    private let batchInterval: DispatchTimeInterval = .milliseconds(1)

    init(runID: String) { self.runID = runID }

    func resume(with mode: StepMode) {
        lock.lock()
        let c = pending
        pending = nil
        lock.unlock()
        c?.resume(returning: mode)
    }

    func didPause(_ pause: PauseInfo,
                  controller: DebugController) async -> StepMode {
        let record = Self.record(from: pause, runID: runID,
                                 startedAt: startedAt)
        // Breakpoints get their own immediate send — the user is
        // waiting on the UI to update, no benefit to delaying.
        // Everything else funnels through the batcher.
        if case .breakpoint = pause.reason {
            flushBatch()
            send(.pause(runID: runID, record: record))
            return await withCheckedContinuation { continuation in
                lock.lock()
                pending = continuation
                lock.unlock()
            }
        }
        appendToBatch(record)
        return .stepOver
    }

    private func appendToBatch(_ record: AROXPCPauseRecord) {
        batchLock.lock()
        batchBuffer.append(record)
        let needsSchedule = !batchScheduled
        if needsSchedule { batchScheduled = true }
        batchLock.unlock()
        guard needsSchedule else { return }
        batchQueue.asyncAfter(deadline: .now() + batchInterval) { [weak self] in
            self?.flushBatch()
        }
    }

    private func flushBatch() {
        batchLock.lock()
        let records = batchBuffer
        batchBuffer.removeAll(keepingCapacity: true)
        batchScheduled = false
        batchLock.unlock()
        guard !records.isEmpty else { return }
        if records.count == 1 {
            send(.pause(runID: runID, record: records[0]))
        } else {
            send(.pauseBatch(runID: runID, records: records))
        }
    }

    func flushRemainingBatch() { flushBatch() }

    func didEnd(error: Error?) async {}

    private static func record(from pause: PauseInfo,
                               runID: String,
                               startedAt: Date) -> AROXPCPauseRecord {
        let kind: AROXPCPauseRecord.Kind
        switch pause.reason {
        case .breakpoint:   kind = .breakpoint
        case .error:        kind = .error
        case .event:        kind = .event
        case .entry, .step: kind = .pause
        }
        let symbols = pause.symbols.map {
            AROXPCPauseRecord.Symbol(name: $0.name,
                                     typeName: $0.typeName,
                                     value: $0.valuePreview)
        }
        let metrics = pause.metrics.map {
            AROXPCPauseRecord.Metrics(elapsedNanos: $0.elapsedNanos,
                                      residentMemoryBytes: $0.residentMemoryBytes)
        }
        return AROXPCPauseRecord(
            time: Date().timeIntervalSince(startedAt),
            kind: kind,
            featureSet: pause.featureSetName,
            file: pause.file.isEmpty ? nil : pause.file,
            line: pause.line > 0 ? pause.line : nil,
            column: pause.column > 0 ? pause.column : nil,
            statement: pause.statementSummary,
            verb: pause.verb,
            reason: String(describing: pause.reason),
            symbols: symbols,
            metrics: metrics
        )
    }
}

// MARK: - Entry point

@main
struct AROXPCServiceMain {
    static func main() async {
        let service = await Service()

        send(.ready(handshake: AROXPCHandshakeReply(
            protocolVersion: AROXPCProtocolVersion.current,
            serviceVersion: AROVersion.shortVersion,
            pid: ProcessInfo.processInfo.processIdentifier
        )))

        var buffer = Data()
        let decoder = JSONDecoder()
        while true {
            guard let chunk = try? stdin.read(upToCount: 4096),
                  !chunk.isEmpty else {
                break
            }
            buffer.append(chunk)
            while let payload = AROXPCFraming.nextPayload(in: &buffer) {
                do {
                    let request = try decoder
                        .decode(AROXPCRequest.self, from: payload)
                    await MainActor.run {
                        service.handle(request)
                    }
                } catch {
                    try? stderr.write(contentsOf:
                        Data("[AROXPCService] decode error: \(error)\n".utf8))
                }
            }
        }
    }
}
