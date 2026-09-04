// ============================================================
// ReplKernelClient.swift
// SOLARO — client for `aro repl --json` (ARO-0091)
// ============================================================
//
// Owns one `aro repl --json` subprocess and speaks its
// line-delimited JSON protocol — the same protocol the Jupyter
// kernel (Editor/jupyter-aro) drives, so a notebook cell behaves
// identically here and in JupyterLab. SOLARO does no ARO parsing
// of cell contents; everything language-shaped stays on the ARO
// side (cell splitting, accumulated definitions, display bundles).
//
// The protocol is request/response with exactly one `result` per
// request id, and any number of `stream` messages before it —
// ordering guaranteed by the server (see `OutputCapture.drain`).
// `REPLSession` is not internally synchronised, so the client
// funnels executes through the caller's serial run queue
// (`ReplNotebookController`); the pending map below still keys by
// id so a misbehaving overlap fails loudly instead of corrupting
// replies.
//
// Interrupt follows the kernel's semantics (ARO-0091 §Interrupt):
// a cell blocked inside the runtime cannot be unwound, so
// interrupt kills the process. The session's variables and
// definitions are gone, and the UI says so — an honest restart
// beats a hang.

import Foundation
import Observation

@MainActor
@Observable
final class ReplKernelClient {

    // MARK: - State

    enum State: Equatable {
        case stopped
        case starting
        /// Server sent `ready`; idle between requests.
        case ready
        /// A request is in flight.
        case busy
        /// Process died or refused to start. The string is shown in
        /// the kernel status popover.
        case dead(String)

        var isRunning: Bool {
            self == .ready || self == .busy || self == .starting
        }
    }

    private(set) var state: State = .stopped
    /// `aro` version reported by the `ready` message.
    private(set) var serverVersion: String?
    /// Session-order counter — increments per successful/failed
    /// execute, mirrors Jupyter's `In[n]`.
    private(set) var executionCounter: Int = 0
    /// PID of the live subprocess, for the metrics socket attach.
    private(set) var pid: Int32?

    // MARK: - Result types

    struct ExecOutcome: Sendable {
        var status: String              // "ok" | "error"
        var plainText: String?          // display bundle text/plain
        var jsonValue: String?          // display bundle application/json, re-encoded
        var errorName: String?
        var errorValue: String?
        var traceback: [String]?
        var durationMs: Double?
        var executionCount: Int
        /// The kernel died mid-cell (killed, crashed). Distinct from
        /// an ARO error — the session is gone.
        var kernelDied: Bool = false
    }

    struct KernelInfo: Sendable {
        var version: String
        var featureSets: [String]
        var variables: [String]
    }

    /// A `result` message, parsed into a typed value the moment it
    /// arrives so nothing untyped (or non-Sendable) crosses an
    /// `await`.
    struct Reply: Sendable {
        var status: String = "error"
        var durationMs: Double?
        var displayPlain: String?
        var displayJSON: String?
        var errorName: String?
        var errorValue: String?
        var traceback: [String]?
        var infoVersion: String?
        var infoFeatureSets: [String]?
        var infoVariables: [String]?
        /// The process died before answering — distinct from an ARO
        /// error inside a live session.
        var kernelDied = false

        static func died(_ reason: String) -> Reply {
            Reply(status: "error",
                  errorName: "KernelDied", errorValue: reason,
                  traceback: [reason], kernelDied: true)
        }

        init(status: String = "error", durationMs: Double? = nil,
             displayPlain: String? = nil, displayJSON: String? = nil,
             errorName: String? = nil, errorValue: String? = nil,
             traceback: [String]? = nil, infoVersion: String? = nil,
             infoFeatureSets: [String]? = nil, infoVariables: [String]? = nil,
             kernelDied: Bool = false) {
            self.status = status
            self.durationMs = durationMs
            self.displayPlain = displayPlain
            self.displayJSON = displayJSON
            self.errorName = errorName
            self.errorValue = errorValue
            self.traceback = traceback
            self.infoVersion = infoVersion
            self.infoFeatureSets = infoFeatureSets
            self.infoVariables = infoVariables
            self.kernelDied = kernelDied
        }

        init(message: [String: Any]) {
            status = message["status"] as? String ?? "error"
            durationMs = message["durationMs"] as? Double
            if let display = message["display"] as? [String: Any] {
                displayPlain = display["text/plain"] as? String
                if let json = display["application/json"],
                   let data = try? JSONSerialization.data(
                       withJSONObject: json,
                       options: [.fragmentsAllowed, .sortedKeys]),
                   let text = String(data: data, encoding: .utf8) {
                    displayJSON = text
                }
            }
            if let error = message["error"] as? [String: Any] {
                errorName = error["ename"] as? String
                errorValue = error["evalue"] as? String
                traceback = error["traceback"] as? [String]
            }
            if let info = message["info"] as? [String: Any] {
                infoVersion = info["version"] as? String
                infoFeatureSets = info["featureSets"] as? [String]
                infoVariables = info["variables"] as? [String]
            }
        }
    }

    // MARK: - Internals

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutBuffer = Data()

    private var nextRequestID = 1
    /// One continuation per in-flight request id, resumed by the
    /// matching `result` line.
    private var pending: [Int: CheckedContinuation<Reply, Never>] = [:]
    /// Stream sink per in-flight request id.
    private var streamSinks: [Int: @MainActor (String, String) -> Void] = [:]
    /// Callers awaiting the `ready` handshake.
    private var readyWaiters: [CheckedContinuation<Bool, Never>] = []
    /// Stderr tail kept for the failure message when the process
    /// dies before (or without) speaking the protocol.
    private var stderrTail = ""

    /// Bumped on every (re)start; lines from a previous process
    /// generation are dropped instead of resolving new requests.
    private var generation = 0

    // MARK: - Lifecycle

    /// Start the subprocess if it isn't running. Safe to call
    /// repeatedly. Returns once the server said `ready` (or died).
    func ensureStarted(project: Project) async {
        switch state {
        case .ready, .busy:
            return
        case .starting:
            _ = await waitUntilReady()
            return
        case .stopped, .dead:
            break
        }
        start(project: project)
        _ = await waitUntilReady()
    }

    private func start(project: Project) {
        generation += 1
        let gen = generation
        state = .starting
        serverVersion = nil
        stderrTail = ""
        stdoutBuffer.removeAll()

        let aro = ConsoleProcess.resolveAroBinary(near: project)
        let task = Process()
        if aro == "/usr/bin/env" {
            task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            task.arguments = ["aro", "repl", "--json"]
        } else {
            task.executableURL = URL(fileURLWithPath: aro)
            task.arguments = ["repl", "--json"]
        }
        task.currentDirectoryURL = project.rootPath

        // Open the runtime's metrics push socket so the Metrics tab
        // can stream kernel-side snapshots, same as `aro run` (the
        // workspace attaches by pid — see `solaroReplKernelStarted`).
        var env = ProcessInfo.processInfo.environment
        env["ARO_METRICS_SOCKET"] = "1"
        task.environment = env

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        task.standardInput = stdin
        task.standardOutput = stdout
        task.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor [weak self] in
                self?.consumeStdout(data, generation: gen)
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                guard let self, self.generation == gen else { return }
                // Keep only a bounded tail; this is failure
                // forensics, not a log.
                self.stderrTail = String((self.stderrTail + text).suffix(4000))
            }
        }
        task.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            Task { @MainActor [weak self] in
                self?.handleTermination(status: status, generation: gen)
            }
        }

        do {
            try task.run()
            process = task
            stdinHandle = stdin.fileHandleForWriting
            pid = task.processIdentifier
            NotificationCenter.default.post(
                name: .solaroReplKernelStarted, object: nil,
                userInfo: ["pid": task.processIdentifier]
            )
        } catch {
            state = .dead("Couldn't launch `aro repl --json`: \(error.localizedDescription)")
            resumeReadyWaiters(ready: false)
        }
    }

    /// Kill the subprocess. The session's variables and definitions
    /// are gone — that is the documented interrupt semantics.
    func interrupt(reason: String = "Interrupted — the session was restarted, its variables and definitions are gone.") {
        guard let process, process.isRunning else { return }
        // The termination handler does the bookkeeping (fails the
        // in-flight cell, notifies, flips state).
        pendingDeathReason = reason
        process.terminate()
    }

    /// Graceful stop: ask the server to exit, then close stdin so a
    /// wedged server still gets EOF.
    func shutdown() {
        guard state.isRunning else { return }
        if state == .ready {
            sendLine(["id": takeRequestID(), "type": "shutdown"])
        }
        try? stdinHandle?.close()
        stdinHandle = nil
        process?.terminate()
    }

    /// Kill (if needed) and start a fresh session.
    func restart(project: Project) async {
        if let process, process.isRunning {
            pendingDeathReason = "Restarting…"
            process.terminate()
            // Termination handler runs async; wait for it so the new
            // generation doesn't race the old handler's cleanup.
            while self.process != nil {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        executionCounter = 0
        state = .stopped
        await ensureStarted(project: project)
    }

    private var pendingDeathReason: String?

    private func handleTermination(status: Int32, generation gen: Int) {
        guard gen == generation else { return }
        let reason: String
        if let pendingDeathReason {
            reason = pendingDeathReason
        } else if !stderrTail.isEmpty {
            reason = "Kernel exited (\(status)): \(stderrTail.trimmingCharacters(in: .whitespacesAndNewlines))"
        } else {
            reason = "Kernel exited with status \(status)."
        }
        pendingDeathReason = nil
        process = nil
        stdinHandle = nil
        if let pid {
            NotificationCenter.default.post(
                name: .solaroReplKernelStopped, object: nil,
                userInfo: ["pid": pid]
            )
        }
        pid = nil
        state = .dead(reason)
        // Fail everything that was waiting on this process.
        let waiting = pending
        pending.removeAll()
        streamSinks.removeAll()
        for (_, continuation) in waiting {
            continuation.resume(returning: .died(reason))
        }
        resumeReadyWaiters(ready: false)
    }

    // MARK: - Requests

    /// Execute one cell. Streams arrive on `onStream` (name, text)
    /// in server order, all before the returned outcome.
    func execute(code: String,
                 onStream: @escaping @MainActor (String, String) -> Void) async -> ExecOutcome {
        guard await waitUntilReady() else {
            let reason = deadReason ?? "Kernel is not running."
            return ExecOutcome(status: "error",
                               errorName: "KernelDied", errorValue: reason,
                               traceback: [reason],
                               executionCount: executionCounter,
                               kernelDied: true)
        }
        state = .busy
        executionCounter += 1
        let count = executionCounter
        let reply = await request(["type": "execute", "code": code], onStream: onStream)
        if state == .busy { state = .ready }

        return ExecOutcome(
            status: reply.status,
            plainText: reply.displayPlain,
            jsonValue: reply.displayJSON,
            errorName: reply.errorName,
            errorValue: reply.errorValue,
            traceback: reply.traceback,
            durationMs: reply.durationMs,
            executionCount: count,
            kernelDied: reply.kernelDied
        )
    }

    /// Session snapshot for the kernel-info popover.
    func info() async -> KernelInfo? {
        guard state == .ready else { return nil }
        state = .busy
        let reply = await request(["type": "info"], onStream: { _, _ in })
        if state == .busy { state = .ready }
        guard reply.infoVersion != nil || reply.infoVariables != nil else { return nil }
        return KernelInfo(
            version: reply.infoVersion ?? "?",
            featureSets: reply.infoFeatureSets ?? [],
            variables: reply.infoVariables ?? []
        )
    }

    /// Clear the session's definitions and variables without a
    /// process restart.
    func reset() async {
        guard state == .ready else { return }
        state = .busy
        _ = await request(["type": "reset"], onStream: { _, _ in })
        if state == .busy { state = .ready }
        executionCounter = 0
    }

    private func request(_ body: [String: Any],
                         onStream: @escaping @MainActor (String, String) -> Void) async -> Reply {
        let id = takeRequestID()
        var message = body
        message["id"] = id
        return await withCheckedContinuation { continuation in
            pending[id] = continuation
            streamSinks[id] = onStream
            sendLine(message)
        }
    }

    private func takeRequestID() -> Int {
        defer { nextRequestID += 1 }
        return nextRequestID
    }

    private func sendLine(_ object: [String: Any]) {
        guard let stdinHandle,
              let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        var line = data
        line.append(0x0A)
        // A write to a dead pipe raises; the termination handler
        // already owns that failure path.
        try? stdinHandle.write(contentsOf: line)
    }

    private var deadReason: String? {
        if case .dead(let reason) = state { return reason }
        return nil
    }

    private func waitUntilReady() async -> Bool {
        switch state {
        case .ready, .busy: return true
        case .stopped, .dead: return false
        case .starting:
            return await withCheckedContinuation { continuation in
                readyWaiters.append(continuation)
            }
        }
    }

    private func resumeReadyWaiters(ready: Bool) {
        let waiters = readyWaiters
        readyWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: ready) }
    }

    // MARK: - Incoming messages

    private func consumeStdout(_ data: Data, generation gen: Int) {
        guard gen == generation, !data.isEmpty else { return }
        stdoutBuffer.append(data)
        while let newline = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer[stdoutBuffer.startIndex..<newline]
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...newline)
            guard !lineData.isEmpty,
                  let object = try? JSONSerialization.jsonObject(
                      with: Data(lineData), options: [.fragmentsAllowed]) as? [String: Any]
            else { continue }
            handleMessage(object)
        }
    }

    private func handleMessage(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "ready":
            serverVersion = message["version"] as? String
            state = .ready
            resumeReadyWaiters(ready: true)
        case "stream":
            guard let id = message["id"] as? Int,
                  let name = message["name"] as? String,
                  let text = message["text"] as? String else { return }
            streamSinks[id]?(name, text)
        case "result":
            guard let id = message["id"] as? Int,
                  let continuation = pending.removeValue(forKey: id) else { return }
            streamSinks.removeValue(forKey: id)
            continuation.resume(returning: Reply(message: message))
        default:
            break
        }
    }
}

extension Notification.Name {
    /// Posted with `userInfo["pid"]` when a notebook kernel process
    /// comes up — the workspace attaches the Metrics tab's socket
    /// client to it when no run session owns the panel.
    static let solaroReplKernelStarted = Notification.Name("solaroReplKernelStarted")
    /// Posted with `userInfo["pid"]` when that process goes away.
    static let solaroReplKernelStopped = Notification.Name("solaroReplKernelStopped")
}
