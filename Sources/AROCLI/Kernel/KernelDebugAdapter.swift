// ============================================================
// KernelDebugAdapter.swift
// aro kernel — Jupyter debug protocol (DAP subset, ARO-0091)
// ============================================================
//
// Jupyter tunnels the Debug Adapter Protocol through
// `debug_request` / `debug_reply` on the control channel. This
// adapter serves the subset that is true for ARO today:
//
//   · the session's variables (JupyterLab's variable inspector) —
//     `inspectVariables` / `richInspectVariables` / `variables`
//   · expression evaluation against the live session — `evaluate`
//   · cell dumping with Murmur2 naming, so the front-end can map
//     cells to source paths — `dumpCell` / `debugInfo`
//   · the lifecycle handshake — `initialize` / `attach` /
//     `configurationDone` / `disconnect`
//
// Breakpoints are answered `verified: false`, with the reason in
// the message: ARO cells run to completion — pausing mid-cell
// needs the runtime's pause engine wired into the kernel, which
// this subset does not promise. Answering `verified: true` and
// never stopping would be a lie; JupyterLab renders the honest
// version as a hollow breakpoint dot.
//
// Transport-free: the kernel server hands in a synchronous
// evaluator and reads plain dictionaries back, so every command is
// unit-testable.

#if !os(Windows)
import Foundation
import ARORuntime

final class KernelDebugAdapter: @unchecked Sendable {

    private let session: REPLSession
    /// Evaluates one ARO statement block against the session and
    /// returns its text rendering (nil on failure). Injected because
    /// execution is async and owned by the server's bridge.
    private let evaluator: (String) -> String?

    private let temporaryDirectory: URL
    /// Arbitrary but stable — "aro\0" as a little-endian word. The
    /// front-end reads it from `debugInfo`, so any value works as
    /// long as it never changes within a session.
    private let hashSeed: UInt32 = 0x006F_7261

    private var sequence = 1
    private let lock = NSLock()

    init(session: REPLSession, evaluator: @escaping (String) -> String?) {
        self.session = session
        self.evaluator = evaluator
        self.temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aro-kernel-cells-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(
            at: temporaryDirectory, withIntermediateDirectories: true)
    }

    private var tmpFilePrefix: String {
        temporaryDirectory.path + "/"
    }
    private let tmpFileSuffix = ".aro"

    // MARK: - Dispatch

    /// Handle one DAP request (the content of a `debug_request`) and
    /// return the DAP response (the content of the `debug_reply`).
    func handle(_ request: [String: Any]) -> [String: Any] {
        let command = request["command"] as? String ?? ""
        let arguments = request["arguments"] as? [String: Any] ?? [:]

        switch command {
        case "initialize":
            return respond(to: request, body: [
                "supportsConfigurationDoneRequest": true,
                "supportsSetVariable": false,
                "supportsConditionalBreakpoints": false,
                "supportsEvaluateForHovers": true,
                "exceptionBreakpointFilters": [Any](),
            ])
        case "debugInfo":
            return respond(to: request, body: [
                "isStarted": true,
                "hashMethod": "Murmur2",
                "hashSeed": Int(hashSeed),
                "tmpFilePrefix": tmpFilePrefix,
                "tmpFileSuffix": tmpFileSuffix,
                "breakpoints": [Any](),
                "stoppedThreads": [Any](),
                "richRendering": true,
                "exceptionPaths": [Any](),
                "copyToGlobals": false,
            ])
        case "dumpCell":
            let code = arguments["code"] as? String ?? ""
            let path = cellPath(for: code)
            try? Data(code.utf8).write(to: URL(fileURLWithPath: path))
            return respond(to: request, body: ["sourcePath": path])
        case "inspectVariables":
            return respond(to: request, body: ["variables": variableList()])
        case "richInspectVariables":
            let name = arguments["variableName"] as? String ?? ""
            let rendered = session.getVariable(name)
                .map { ResponseFormatter.formatValue($0, for: .human) }
            return respond(to: request, body: [
                "data": ["text/plain": rendered ?? "undefined"],
                "metadata": [String: Any](),
            ])
        case "evaluate":
            let expression = arguments["expression"] as? String ?? ""
            if let result = evaluator(expression) {
                return respond(to: request, body: [
                    "result": result, "variablesReference": 0,
                ])
            }
            return respond(to: request, success: false,
                           message: "evaluation failed")
        case "variables":
            // Only the top-level scope exists (no pause, no frames);
            // reference 0/1 both answer with the session variables.
            return respond(to: request, body: ["variables": variableList()])
        case "setBreakpoints":
            let requested = (arguments["breakpoints"] as? [[String: Any]]) ?? []
            let answered = requested.map { breakpoint -> [String: Any] in
                [
                    "verified": false,
                    "line": breakpoint["line"] ?? 0,
                    "message": "ARO cells run to completion — pausing mid-cell is not supported by this kernel yet.",
                ]
            }
            return respond(to: request, body: ["breakpoints": answered])
        case "threads":
            return respond(to: request, body: ["threads": [Any]()])
        case "stackTrace":
            return respond(to: request, body: ["stackFrames": [Any](), "totalFrames": 0])
        case "scopes":
            return respond(to: request, body: ["scopes": [Any]()])
        case "source":
            return respond(to: request, success: false, message: "no source for reference")
        case "attach", "configurationDone", "disconnect",
             "setExceptionBreakpoints", "terminate":
            return respond(to: request, body: [:])
        default:
            return respond(to: request, success: false,
                           message: "unsupported command '\(command)'")
        }
    }

    // MARK: - Pieces

    private func variableList() -> [[String: Any]] {
        session.variableNames.map { name -> [String: Any] in
            let value = session.getVariable(name)
            let rendered = value.map { ResponseFormatter.formatValue($0, for: .human) } ?? "undefined"
            return [
                "name": name,
                "value": rendered,
                "type": value.map { typeName(of: $0) } ?? "undefined",
                "variablesReference": 0,
            ]
        }
    }

    private func typeName(of value: Any) -> String {
        switch value {
        case is Int: return "Int"
        case is Double: return "Float"
        case is Bool: return "Boolean"
        case is String: return "String"
        case is [Any]: return "List"
        case is [String: Any]: return "Record"
        default: return String(describing: type(of: value))
        }
    }

    /// The path `dumpCell` writes and `debugInfo` lets the front-end
    /// predict: prefix + murmur2(code, seed) + suffix.
    func cellPath(for code: String) -> String {
        tmpFilePrefix + String(Self.murmur2(Array(code.utf8), seed: hashSeed)) + tmpFileSuffix
    }

    private func respond(
        to request: [String: Any],
        success: Bool = true,
        message: String? = nil,
        body: [String: Any] = [:]
    ) -> [String: Any] {
        let nextSeq = lock.withLock { () -> Int in
            sequence += 1
            return sequence
        }
        var response: [String: Any] = [
            "seq": nextSeq,
            "type": "response",
            "request_seq": request["seq"] ?? 0,
            "success": success,
            "command": request["command"] ?? "",
        ]
        if let message { response["message"] = message }
        if !body.isEmpty || success { response["body"] = body }
        return response
    }

    // MARK: - Murmur2

    /// MurmurHash2 (32-bit) — the hash Jupyter's debugger vocabulary
    /// names for cell→file mapping (`hashMethod: "Murmur2"`).
    static func murmur2(_ bytes: [UInt8], seed: UInt32) -> UInt32 {
        let m: UInt32 = 0x5bd1_e995
        let r: UInt32 = 24
        var h: UInt32 = seed ^ UInt32(bytes.count)

        var index = 0
        while bytes.count - index >= 4 {
            var k = UInt32(bytes[index])
                | UInt32(bytes[index + 1]) << 8
                | UInt32(bytes[index + 2]) << 16
                | UInt32(bytes[index + 3]) << 24
            k = k &* m
            k ^= k >> r
            k = k &* m
            h = h &* m
            h ^= k
            index += 4
        }

        let remaining = bytes.count - index
        if remaining >= 3 { h ^= UInt32(bytes[index + 2]) << 16 }
        if remaining >= 2 { h ^= UInt32(bytes[index + 1]) << 8 }
        if remaining >= 1 {
            h ^= UInt32(bytes[index])
            h = h &* m
        }

        h ^= h >> 13
        h = h &* m
        h ^= h >> 15
        return h
    }
}
#endif
