// ============================================================
// DAPFrontend.swift
// ARO Runtime - Debug Adapter Protocol Frontend (Issue #229 Phase 2)
// ============================================================
//
// Glue between the spec-light DAPProtocol layer and the runtime-side
// `DebugController`. Lifecycle:
//
//   1. Client sends `initialize` → we reply with capabilities + send
//      `initialized` event.
//   2. Client sends `launch` (the CLI has already constructed the
//      Application; launch just tells us to proceed) → we reply success.
//   3. Client sends zero or more `setBreakpoints` → we register them on
//      the controller and reply with the verified set.
//   4. Client sends `configurationDone` → we resume (continue).
//   5. Runtime hits a checkpoint → frontend sends `stopped` and awaits a
//      step command (continue / next / stepIn / stepOut / pause).
//   6. Repeat until disconnect.
//
// Phase 2 ships the minimum to drive nvim-dap and a hand-written VS Code
// extension. Phase 3 wires conditional / event / verb breakpoints and
// the `evaluate` request. Source mapping for compiled binaries lives
// under the LLVM codegen and lands as a follow-up.

import Foundation

public actor DAPFrontend: DebugFrontend {
    private let reader: DAPReader
    private let writer: DAPWriter
    private let logHandle: FileHandle?

    // Coordination between the message reader (which receives DAP step
    // commands) and the runtime's `didPause` await.
    private var pendingResume: CheckedContinuation<StepMode, Never>?
    private var didTerminate = false
    private weak var controller: DebugController?

    public init(input: FileHandle = .standardInput, output: FileHandle = .standardOutput, log: FileHandle? = nil) {
        self.reader = DAPReader(handle: input)
        self.writer = DAPWriter(handle: output)
        self.logHandle = log
    }

    public func attach(controller: DebugController) {
        self.controller = controller
    }

    /// Drives the DAP message loop. Returns when the client disconnects
    /// or the input stream EOFs. Run this as a detached Task alongside
    /// the application.
    public func runMessageLoop() async {
        while !didTerminate {
            do {
                guard let msg = try await reader.read() else {
                    didTerminate = true
                    pendingResume?.resume(returning: .continue)
                    pendingResume = nil
                    return
                }
                await handle(msg)
            } catch {
                log("read error: \(error)")
                didTerminate = true
                pendingResume?.resume(returning: .continue)
                pendingResume = nil
                return
            }
        }
    }

    // MARK: - DebugFrontend

    nonisolated public func didPause(_ pause: PauseInfo, controller: DebugController) async -> StepMode {
        await sendStopped(pause)
        return await awaitNextStep()
    }

    nonisolated public func didEnd(error: Error?) async {
        await sendTerminated(error: error)
    }

    // MARK: - Message handling

    private func handle(_ msg: DAPMessage) async {
        switch (msg.kind, msg.name) {
        case (.request, "initialize"):
            try? await writer.reply(to: msg, body: [
                "supportsConfigurationDoneRequest": true,
                "supportsConditionalBreakpoints": false,        // Phase 3
                "supportsHitConditionalBreakpoints": false,
                "supportsFunctionBreakpoints": true,             // verb breakpoints
                "supportsSetVariable": false,
                "supportsEvaluateForHovers": false,              // Phase 3
                "supportsStepBack": false,                       // Phase 4
                "exceptionBreakpointFilters": [
                    ["filter": "error", "label": "Runtime errors", "default": true]
                ]
            ])
            try? await writer.event("initialized")
        case (.request, "launch"), (.request, "attach"):
            try? await writer.reply(to: msg)
        case (.request, "configurationDone"):
            try? await writer.reply(to: msg)
            // No need to resume here — execution hasn't paused yet at
            // initial handshake. The first `stopped` is sent on the
            // initial entry checkpoint, after which the client sends
            // a `continue`.
        case (.request, "setBreakpoints"):
            await handleSetBreakpoints(msg)
        case (.request, "setFunctionBreakpoints"):
            await handleSetFunctionBreakpoints(msg)
        case (.request, "setExceptionBreakpoints"):
            try? await writer.reply(to: msg)
        case (.request, "threads"):
            try? await writer.reply(to: msg, body: [
                "threads": [["id": 1, "name": "aro"]]
            ])
        case (.request, "stackTrace"):
            try? await writer.reply(to: msg, body: [
                "stackFrames": [], "totalFrames": 0
            ])
        case (.request, "scopes"):
            try? await writer.reply(to: msg, body: [
                "scopes": [
                    ["name": "Locals", "variablesReference": 1, "expensive": false]
                ]
            ])
        case (.request, "variables"):
            // The most recent pause's symbols are surfaced as locals.
            // Phase 2 keeps it stateless — the client re-requests on each
            // stopped event.
            try? await writer.reply(to: msg, body: ["variables": cachedVariables])
        case (.request, "continue"):
            try? await writer.reply(to: msg, body: ["allThreadsContinued": true])
            resumeNextStep(with: .continue)
        case (.request, "next"):
            try? await writer.reply(to: msg)
            resumeNextStep(with: .stepOver)
        case (.request, "stepIn"):
            try? await writer.reply(to: msg)
            resumeNextStep(with: .stepIn)
        case (.request, "stepOut"):
            try? await writer.reply(to: msg)
            resumeNextStep(with: .stepOut)
        case (.request, "pause"):
            try? await writer.reply(to: msg)
            // No-op in Phase 2: pause-on-demand requires a runtime
            // interruption signal. Phase 5 (production attach) adds it.
        case (.request, "disconnect"), (.request, "terminate"):
            try? await writer.reply(to: msg)
            didTerminate = true
            resumeNextStep(with: .continue)
        default:
            try? await writer.reply(to: msg, success: false, message: "unhandled: \(msg.name)")
        }
    }

    private func handleSetBreakpoints(_ msg: DAPMessage) async {
        guard let args = msg.arguments,
              let lines = args["breakpoints"] as? [[String: Any]]
        else {
            try? await writer.reply(to: msg, body: ["breakpoints": []])
            return
        }
        let sourceName = (args["source"] as? [String: Any])?["name"] as? String
        // Wipe any existing location breakpoints for this source and re-add.
        if let ctrl = controller {
            for bp in await ctrl.listBreakpoints() {
                if case .location(let f, _) = bp, f == sourceName ?? "" {
                    await ctrl.removeBreakpoint(bp)
                }
            }
            var verified: [[String: Any]] = []
            for entry in lines {
                guard let line = entry["line"] as? Int else { continue }
                await ctrl.addBreakpoint(.location(file: sourceName ?? "", line: line))
                verified.append(["verified": true, "line": line])
            }
            try? await writer.reply(to: msg, body: ["breakpoints": verified])
        } else {
            try? await writer.reply(to: msg, body: ["breakpoints": []])
        }
    }

    private func handleSetFunctionBreakpoints(_ msg: DAPMessage) async {
        guard let args = msg.arguments,
              let names = args["breakpoints"] as? [[String: Any]],
              let ctrl = controller
        else {
            try? await writer.reply(to: msg, body: ["breakpoints": []])
            return
        }
        // Drop existing verb breakpoints and re-add.
        for bp in await ctrl.listBreakpoints() {
            if case .verb = bp { await ctrl.removeBreakpoint(bp) }
        }
        var verified: [[String: Any]] = []
        for entry in names {
            guard let n = entry["name"] as? String else { continue }
            await ctrl.addBreakpoint(.verb(n))
            verified.append(["verified": true])
        }
        try? await writer.reply(to: msg, body: ["breakpoints": verified])
    }

    // MARK: - Stop coordination

    private var cachedVariables: [[String: Any]] = []

    private func sendStopped(_ pause: PauseInfo) async {
        cachedVariables = pause.symbols.map { s in
            [
                "name": "<\(s.name)>",
                "value": s.valuePreview,
                "type": s.typeName,
                "variablesReference": 0
            ]
        }
        let reason: String
        switch pause.reason {
        case .entry: reason = "entry"
        case .step: reason = "step"
        case .breakpoint: reason = "breakpoint"
        case .event: reason = "event"
        case .error: reason = "exception"
        }
        try? await writer.event("stopped", body: [
            "reason": reason,
            "threadId": 1,
            "allThreadsStopped": true,
            "description": pause.statementSummary
        ])
    }

    private func sendTerminated(error: Error?) async {
        if let error {
            try? await writer.event("output", body: [
                "category": "stderr",
                "output": "\(error)\n"
            ])
        }
        try? await writer.event("terminated")
    }

    private func awaitNextStep() async -> StepMode {
        if didTerminate { return .continue }
        return await withCheckedContinuation { (cont: CheckedContinuation<StepMode, Never>) in
            self.pendingResume = cont
        }
    }

    private func resumeNextStep(with mode: StepMode) {
        if let cont = pendingResume {
            pendingResume = nil
            cont.resume(returning: mode)
        }
    }

    private func log(_ s: String) {
        guard let logHandle else { return }
        try? logHandle.write(contentsOf: Data("[dap] \(s)\n".utf8))
    }
}
