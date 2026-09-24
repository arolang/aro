// ============================================================
// JupyterKernelServer.swift
// aro kernel — the native Jupyter kernel (ARO-0091)
// ============================================================
//
// Speaks Jupyter's wire protocol (5.3) over ZeroMQ directly — no
// Python, no ipykernel. Cells execute through the same
// `REPLCellEngine` the stdio JSON server drives, so a cell behaves
// identically under `aro kernel`, `aro repl --json`, and the
// Python shim in Editor/jupyter-aro.
//
// Thread model, following libzmq's one-socket-one-thread rule:
//
//   heartbeat  REP     its own thread, pure echo loop
//   control    ROUTER  its own thread — shutdown must be answerable
//                      while a cell is running on shell
//   shell      ROUTER  the run() thread; recv → handle → reply.
//                      Blocking here during execution IS the
//                      protocol: one request at a time, and the
//                      front-end knows the kernel is busy from the
//                      iopub status message.
//   iopub      PUB     written from the shell thread and from the
//                      output-capture readers; serialized by
//                      `iopubLock` (a full barrier, which is what
//                      socket migration requires)
//   stdin      ROUTER  bound but never used — the kernel never asks
//                      for input, so `allow_stdin` is dead weight
//
// Interrupt is a signal (see the kernelspec): SIGINT's default
// disposition kills the process and Jupyter restarts it — the same
// honest kill-and-replace the proposal documents for the shim. A
// cell blocked inside the runtime cannot be unwound.

#if !os(Windows)
import Foundation
import AROVersion

final class JupyterKernelServer: @unchecked Sendable {

    private let connection: JupyterConnection
    private let signer: JupyterSigner
    /// The kernel's own session id, stamped on every message it
    /// originates.
    private let kernelSession = UUID().uuidString

    private let session: REPLSession
    private let engine: REPLCellEngine
    /// Comm protocol + the ipywidgets subset (`:widget …`).
    private let comms = KernelCommRegistry()
    /// The DAP subset behind `debug_request` (variable inspector,
    /// evaluate, dumpCell).
    private var debugAdapter: KernelDebugAdapter!
    /// True while a cell runs on the shell thread — the control
    /// thread's `evaluate` must not race the unsynchronised session.
    private var executingCell = false

    private let context: ZMQContext
    private let shell: ZMQSocket
    private let control: ZMQSocket
    private let iopub: ZMQSocket
    private let stdinSocket: ZMQSocket
    private let heartbeat: ZMQSocket

    /// Serializes every iopub send — see the thread model above.
    private let iopubLock = NSLock()

    private let stateLock = NSLock()
    private var executionCount = 0
    /// Header of the request currently being served; parents every
    /// iopub message, including captured output racing in from the
    /// reader threads.
    private var currentParent: [String: Any] = [:]
    private var drainToken = 0
    private var stopping = false

    #if !os(Windows)
    private var captures: [OutputCapture] = []
    /// The real stderr, kept for the kernel's own log lines after
    /// fd 2 is redirected into the capture pipes.
    private let logFD: Int32
    #endif

    init(connection: JupyterConnection) throws {
        self.connection = connection
        self.signer = JupyterSigner(key: connection.key)
        self.session = REPLSession()
        self.engine = REPLCellEngine(session: session)
        self.logFD = dup(STDERR_FILENO)

        guard let context = ZMQContext() else {
            throw KernelError.setup("zmq_ctx_new failed")
        }
        self.context = context

        func makeSocket(_ kind: ZMQSocket.Kind, port: Int) throws -> ZMQSocket {
            guard let socket = ZMQSocket(context: context, kind: kind) else {
                throw KernelError.setup("zmq_socket failed")
            }
            try socket.bind(connection.endpoint(port: port))
            return socket
        }
        self.shell = try makeSocket(.router, port: connection.shellPort)
        self.control = try makeSocket(.router, port: connection.controlPort)
        self.iopub = try makeSocket(.pub, port: connection.iopubPort)
        self.stdinSocket = try makeSocket(.router, port: connection.stdinPort)
        self.heartbeat = try makeSocket(.rep, port: connection.hbPort)

        engine.note = { [weak self] text in
            self?.publishStream(name: "stdout", text: text)
        }

        comms.publish = { [weak self] type, content in
            guard let self else { return }
            let parent = self.stateLock.withLock { self.currentParent }
            self.publish(type: type, parent: parent, content: content)
        }
        comms.readVariable = { [weak self] name in
            self?.session.getVariable(name)
        }
        comms.writeVariable = { [weak self] name, value in
            guard let self else { return }
            // JSON hands numbers over as NSNumber; store what the
            // session's arithmetic expects.
            switch value {
            case let number as NSNumber:
                if number.doubleValue.truncatingRemainder(dividingBy: 1) == 0 {
                    self.session.setVariable(name, value: number.intValue)
                } else {
                    self.session.setVariable(name, value: number.doubleValue)
                }
            case let text as String:
                self.session.setVariable(name, value: text)
            default:
                break
            }
        }

        debugAdapter = KernelDebugAdapter(session: session) { [weak self] expression in
            guard let self else { return nil }
            // Never race a running cell — the session is one-request-
            // at-a-time by design (ARO-0091 limits).
            let busy = self.stateLock.withLock { self.executingCell }
            guard !busy else { return nil }
            let outcome = self.runBlocking { [session = self.session] () -> String? in
                guard let result = try? await session.evaluateExpression(expression) else {
                    return nil
                }
                switch result {
                case .value(let value):
                    return String(describing: value)
                case .ok:
                    return "OK"
                default:
                    return nil
                }
            }
            return outcome
        }
    }

    enum KernelError: Error, CustomStringConvertible {
        case setup(String)
        var description: String {
            if case .setup(let message) = self { return "kernel setup failed: \(message)" }
            return "kernel error"
        }
    }

    // MARK: - Lifecycle

    /// Serve until a shutdown_request arrives. Blocks the calling
    /// thread — it becomes the shell thread.
    func run() {
        installCaptures()

        let heartbeatThread = Thread { [weak self] in self?.heartbeatLoop() }
        heartbeatThread.name = "aro.kernel.heartbeat"
        heartbeatThread.start()

        let controlThread = Thread { [weak self] in self?.channelLoop(socket: self!.control) }
        controlThread.name = "aro.kernel.control"
        controlThread.start()

        log("[aro kernel] serving on \(connection.transport)://\(connection.ip) " +
            "(shell \(connection.shellPort), iopub \(connection.iopubPort))")

        channelLoop(socket: shell)

        // Unblock the sibling loops and let the process exit.
        context.shutdown()
        shell.close()
        control.close()
        iopub.close()
        stdinSocket.close()
        heartbeat.close()
    }

    private var isStopping: Bool {
        stateLock.withLock { stopping }
    }

    private func heartbeatLoop() {
        while !isStopping {
            guard let frames = heartbeat.receiveMultipart() else { return }
            heartbeat.sendMultipart(frames)
        }
    }

    /// Shared by shell and control: both are ROUTERs answering the
    /// same request vocabulary, and Jupyter may send shutdown on
    /// either.
    private func channelLoop(socket: ZMQSocket) {
        while !isStopping {
            guard let frames = socket.receiveMultipart() else { return }
            guard let message = JupyterWire.parse(frames: frames, signer: signer) else { continue }
            handle(message, on: socket)
            if isStopping, socket === shell { return }
        }
    }

    // MARK: - Dispatch

    private func handle(_ message: JupyterWireMessage, on socket: ZMQSocket) {
        stateLock.withLock { currentParent = message.header }
        publishStatus("busy", parent: message.header)
        defer { publishStatus("idle", parent: message.header) }

        switch message.msgType {
        case "kernel_info_request":
            reply(to: message, on: socket, type: "kernel_info_reply",
                  content: kernelInfoContent())
        case "execute_request":
            handleExecute(message, on: socket)
        case "complete_request":
            handleComplete(message, on: socket)
        case "inspect_request":
            handleInspect(message, on: socket)
        case "is_complete_request":
            handleIsComplete(message, on: socket)
        case "comm_open":
            comms.handleCommOpen(content: message.content)
        case "comm_msg":
            comms.handleCommMsg(content: message.content)
        case "comm_close":
            comms.handleCommClose(content: message.content)
        case "comm_info_request":
            reply(to: message, on: socket, type: "comm_info_reply",
                  content: comms.commInfo(
                      targetFilter: message.content["target_name"] as? String))
        case "debug_request":
            reply(to: message, on: socket, type: "debug_reply",
                  content: debugAdapter.handle(message.content))
        case "history_request":
            reply(to: message, on: socket, type: "history_reply",
                  content: ["status": "ok", "history": [Any]()])
        case "shutdown_request":
            let restart = (message.content["restart"] as? Bool) ?? false
            reply(to: message, on: socket, type: "shutdown_reply",
                  content: ["status": "ok", "restart": restart])
            stateLock.withLock { stopping = true }
            context.shutdown()
        case "interrupt_request":
            // Declared interrupt mode is `signal`, so this only
            // arrives from nonstandard clients. The honest answer is
            // the documented one: a running cell cannot be unwound.
            reply(to: message, on: socket, type: "interrupt_reply",
                  content: ["status": "ok"])
        default:
            log("[aro kernel] ignoring unknown msg_type '\(message.msgType)'")
        }
    }

    // MARK: - Requests

    private func handleExecute(_ message: JupyterWireMessage, on socket: ZMQSocket) {
        let code = message.content["code"] as? String ?? ""
        let silent = (message.content["silent"] as? Bool) ?? false

        let count = stateLock.withLock { () -> Int in
            executionCount += 1
            return executionCount
        }

        if !silent {
            publish(type: "execute_input", parent: message.header,
                    content: ["code": code, "execution_count": count])
        }

        // `:widget` cells belong to the kernel, not the engine — the
        // widget lives in the comm layer only this transport has.
        if KernelCommRegistry.isWidgetCommand(code) {
            if let usage = comms.runWidgetCommand(code) {
                publishStream(name: "stderr", text: usage + "\n")
            }
            reply(to: message, on: socket, type: "execute_reply", content: [
                "status": "ok",
                "execution_count": count,
                "payload": [Any](),
                "user_expressions": [String: Any](),
            ])
            return
        }

        stateLock.withLock { executingCell = true }
        let outcome = runBlocking { [engine] in
            await engine.executeCell(code)
        }
        stateLock.withLock { executingCell = false }
        drainCaptures()
        // A cell that moved a bound variable moves its control.
        comms.syncWidgetsFromSession()

        if let error = outcome.error {
            let payload = error.payload
            publish(type: "error", parent: message.header, content: payload)
            var replyContent = payload
            replyContent["status"] = "error"
            replyContent["execution_count"] = count
            reply(to: message, on: socket, type: "execute_reply", content: replyContent)
            return
        }

        if let display = outcome.display, !display.isEmpty, !silent {
            publish(type: "execute_result", parent: message.header, content: [
                "execution_count": count,
                "data": display,
                "metadata": [String: Any](),
            ])
        }

        reply(to: message, on: socket, type: "execute_reply", content: [
            "status": "ok",
            "execution_count": count,
            "payload": [Any](),
            "user_expressions": [String: Any](),
        ])
    }

    private func handleComplete(_ message: JupyterWireMessage, on socket: ZMQSocket) {
        let code = message.content["code"] as? String ?? ""
        let cursor = message.content["cursor_pos"] as? Int ?? code.count
        let answer = engine.complete(code: code, cursor: cursor)
        reply(to: message, on: socket, type: "complete_reply", content: [
            "status": "ok",
            "matches": answer.matches,
            "cursor_start": answer.cursorStart,
            "cursor_end": answer.cursorEnd,
            "metadata": [String: Any](),
        ])
    }

    private func handleInspect(_ message: JupyterWireMessage, on socket: ZMQSocket) {
        let code = message.content["code"] as? String ?? ""
        let cursor = message.content["cursor_pos"] as? Int ?? code.count
        let answer = engine.inspect(code: code, cursor: cursor)
        var content: [String: Any] = [
            "status": "ok",
            "found": answer.found,
            "metadata": [String: Any](),
        ]
        content["data"] = answer.found && answer.text != nil
            ? ["text/plain": answer.text!]
            : [String: Any]()
        reply(to: message, on: socket, type: "inspect_reply", content: content)
    }

    private func handleIsComplete(_ message: JupyterWireMessage, on socket: ZMQSocket) {
        let code = message.content["code"] as? String ?? ""
        var content: [String: Any]
        switch MultilineDetector.check(code) {
        case .complete:
            content = ["status": "complete"]
        case .needsMore:
            content = ["status": "incomplete", "indent": "    "]
        case .error:
            content = ["status": "invalid"]
        }
        reply(to: message, on: socket, type: "is_complete_reply", content: content)
    }

    private func kernelInfoContent() -> [String: Any] {
        [
            "status": "ok",
            "protocol_version": "5.3",
            "implementation": "aro",
            "implementation_version": AROVersion.shortVersion,
            "language_info": [
                "name": "aro",
                "version": AROVersion.shortVersion,
                "mimetype": "text/x-aro",
                "file_extension": ".aro",
                "pygments_lexer": "text",
                "codemirror_mode": "aro",
            ],
            "banner": "ARO \(AROVersion.shortVersion) — native kernel (ARO-0091)",
            "help_links": [
                ["text": "ARO Language", "url": "https://github.com/arolang/aro"],
            ],
        ]
    }

    // MARK: - Wire helpers

    private func reply(
        to request: JupyterWireMessage,
        on socket: ZMQSocket,
        type: String,
        content: [String: Any]
    ) {
        let message = JupyterWireMessage(
            identities: request.identities,
            header: JupyterWire.header(msgType: type, session: kernelSession),
            parentHeader: request.header,
            metadata: [:],
            content: content
        )
        // shell and control are each confined to the thread running
        // their loop; `handle` is always called on that thread, so
        // sending here needs no lock.
        socket.sendMultipart(JupyterWire.serialize(message, signer: signer))
    }

    private func publish(type: String, parent: [String: Any], content: [String: Any]) {
        let message = JupyterWireMessage(
            identities: [Data(type.utf8)],
            header: JupyterWire.header(msgType: type, session: kernelSession),
            parentHeader: parent,
            metadata: [:],
            content: content
        )
        let frames = JupyterWire.serialize(message, signer: signer)
        iopubLock.lock()
        iopub.sendMultipart(frames)
        iopubLock.unlock()
    }

    private func publishStatus(_ state: String, parent: [String: Any]) {
        publish(type: "status", parent: parent, content: ["execution_state": state])
    }

    private func publishStream(name: String, text: String) {
        let parent = stateLock.withLock { currentParent }
        publish(type: "stream", parent: parent, content: ["name": name, "text": text])
    }

    // MARK: - Output capture

    /// Redirect fd 1 / fd 2 into iopub `stream` messages — the same
    /// `OutputCapture` machinery (and ordering sentinel) the JSON
    /// server uses.
    private func installCaptures() {
        let emit: @Sendable (String, String) -> Void = { [weak self] name, text in
            self?.publishStream(name: name, text: text)
        }
        if let out = OutputCapture(name: "stdout", targetFD: STDOUT_FILENO, emit: emit) {
            captures.append(out)
        }
        if let err = OutputCapture(name: "stderr", targetFD: STDERR_FILENO, emit: emit) {
            captures.append(err)
        }
    }

    /// Flush captured output and wait for it, so every `stream` for a
    /// cell is on iopub before that cell's reply.
    private func drainCaptures() {
        let token = stateLock.withLock { () -> Int in
            drainToken += 1
            return drainToken
        }
        for capture in captures {
            capture.drain(token: token)
        }
    }

    /// Kernel-side logging on the *real* stderr — fd 2 is captured.
    private func log(_ text: String) {
        let line = text + "\n"
        _ = line.utf8CString.withUnsafeBufferPointer { buffer in
            write(logFD, buffer.baseAddress, buffer.count - 1)
        }
    }

    /// Bridge the engine's async execution onto this blocking
    /// channel thread. One request at a time by protocol, so
    /// blocking here is the design, not an accident.
    private func runBlocking<T: Sendable>(_ operation: @escaping @Sendable () async -> T) -> T {
        let box = ResultBox<T>()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = await operation()
            semaphore.signal()
        }
        semaphore.wait()
        return box.value!
    }

    private final class ResultBox<T>: @unchecked Sendable {
        var value: T?
    }
}
#endif
