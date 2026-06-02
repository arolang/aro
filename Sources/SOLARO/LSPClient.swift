// ============================================================
// LSPClient.swift
// SOLARO — minimum-viable LSP client for `aro lsp` (Phase 14)
// ============================================================
//
// Spawns `aro lsp` as a subprocess, talks JSON-RPC 2.0 over stdio
// using LSP's `Content-Length: N\r\n\r\n{body}` framing, and
// exposes the published diagnostics back to SwiftUI via
// @Observable.
//
// Scope: initialize / initialized handshake, textDocument/didOpen
// + didChange, and the textDocument/publishDiagnostics notification.
// Hover, completion, semantic tokens, and code actions are
// follow-ups (the server supports them but the editor doesn't
// surface them yet).

import Foundation

@MainActor
@Observable
final class AROLSPClient {

    struct Diagnostic: Identifiable, Equatable {
        let id = UUID()
        let line: Int          // 1-indexed for SOLARO UX
        let character: Int     // 1-indexed
        let endLine: Int
        let endCharacter: Int
        let severity: Severity
        let message: String

        enum Severity: Int { case error = 1, warning = 2, info = 3, hint = 4 }
    }

    /// Live diagnostics keyed by file URL. Updated whenever the
    /// server pushes `textDocument/publishDiagnostics`.
    var diagnostics: [URL: [Diagnostic]] = [:]

    /// `true` once the initialize → initialized handshake completes.
    private(set) var isReady: Bool = false

    /// Last stderr line. Surfaces server crashes / setup errors in
    /// the inspector when something goes wrong.
    private(set) var lastErrorLine: String?

    // MARK: - Lifecycle

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var partialBuffer = Data()
    private var nextID: Int = 1
    private var documentVersions: [URL: Int] = [:]

    func start() {
        guard process == nil else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["aro", "lsp"]
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        task.standardInput = stdin
        task.standardOutput = stdout
        task.standardError = stderr
        stdinPipe = stdin
        stdoutPipe = stdout
        stderrPipe = stderr

        // Drain stdout (LSP frames) and stderr (server logs).
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.feedStdout(data)
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let line = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                self?.lastErrorLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        task.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.process = nil
                self?.isReady = false
            }
        }

        do {
            try task.run()
            process = task
            sendInitialize()
        } catch {
            lastErrorLine = "Could not launch `aro lsp`: \(error.localizedDescription)"
        }
    }

    func stop() {
        process?.terminate()
        process = nil
        isReady = false
    }

    // MARK: - Document lifecycle

    func didOpen(url: URL, text: String) {
        guard isReady else { return }
        documentVersions[url] = 1
        sendNotification(method: "textDocument/didOpen", params: [
            "textDocument": [
                "uri": url.absoluteString,
                "languageId": "aro",
                "version": 1,
                "text": text,
            ],
        ])
    }

    func didChange(url: URL, text: String) {
        guard isReady else { return }
        let version = (documentVersions[url] ?? 0) + 1
        documentVersions[url] = version
        sendNotification(method: "textDocument/didChange", params: [
            "textDocument": [
                "uri": url.absoluteString,
                "version": version,
            ],
            "contentChanges": [
                ["text": text],
            ],
        ])
    }

    func didClose(url: URL) {
        guard isReady else { return }
        documentVersions.removeValue(forKey: url)
        diagnostics.removeValue(forKey: url)
        sendNotification(method: "textDocument/didClose", params: [
            "textDocument": ["uri": url.absoluteString],
        ])
    }

    // MARK: - JSON-RPC plumbing

    private func sendInitialize() {
        let id = nextID
        nextID += 1
        let initParams: [String: Any] = [
            "processId": Int(ProcessInfo.processInfo.processIdentifier),
            "rootUri": NSNull(),
            "capabilities": [
                "textDocument": [
                    "publishDiagnostics": [
                        "relatedInformation": true,
                    ],
                ],
            ],
        ]
        send(jsonObject: [
            "jsonrpc": "2.0",
            "id": id,
            "method": "initialize",
            "params": initParams,
        ])
    }

    private func sendNotification(method: String, params: [String: Any]) {
        send(jsonObject: [
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
        ])
    }

    private func send(jsonObject: [String: Any]) {
        guard
            let stdinPipe,
            let body = try? JSONSerialization.data(withJSONObject: jsonObject)
        else { return }
        let header = "Content-Length: \(body.count)\r\n\r\n"
        guard let headerData = header.data(using: .utf8) else { return }
        stdinPipe.fileHandleForWriting.write(headerData)
        stdinPipe.fileHandleForWriting.write(body)
    }

    // MARK: - Reading

    private func feedStdout(_ data: Data) {
        partialBuffer.append(data)
        while let (frame, rest) = takeFrame(from: partialBuffer) {
            partialBuffer = rest
            handleFrame(frame)
        }
    }

    /// Try to take one full LSP frame off the front of `buffer`.
    /// Returns nil if a complete frame isn't available yet.
    private func takeFrame(from buffer: Data) -> (Data, Data)? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8))
        else { return nil }
        let headerData = buffer.subdata(in: 0..<headerEnd.lowerBound)
        guard let headerString = String(data: headerData, encoding: .utf8)
        else { return nil }
        var length = 0
        for line in headerString.split(separator: "\r\n") {
            let pair = line.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if pair.count == 2, pair[0].lowercased() == "content-length",
               let n = Int(pair[1]) {
                length = n
            }
        }
        let bodyStart = headerEnd.upperBound
        let bodyEnd = bodyStart + length
        guard buffer.count >= bodyEnd else { return nil }
        let body = buffer.subdata(in: bodyStart..<bodyEnd)
        let rest = buffer.subdata(in: bodyEnd..<buffer.count)
        return (body, rest)
    }

    private func handleFrame(_ data: Data) {
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        if let method = obj["method"] as? String {
            handleServerMessage(method: method, params: obj["params"])
        } else if obj["result"] != nil, let id = obj["id"] as? Int, id == 1 {
            // The initialize response — finish handshake.
            isReady = true
            sendNotification(method: "initialized", params: [:])
        }
    }

    private func handleServerMessage(method: String, params: Any?) {
        switch method {
        case "textDocument/publishDiagnostics":
            handlePublishDiagnostics(params)
        default:
            break  // hover / completion / etc. are follow-ups
        }
    }

    private func handlePublishDiagnostics(_ params: Any?) {
        guard
            let dict = params as? [String: Any],
            let uriStr = dict["uri"] as? String,
            let url = URL(string: uriStr),
            let raw = dict["diagnostics"] as? [[String: Any]]
        else { return }

        let parsed = raw.compactMap { record -> Diagnostic? in
            guard
                let rangeDict = record["range"] as? [String: Any],
                let start = rangeDict["start"] as? [String: Any],
                let end   = rangeDict["end"] as? [String: Any],
                let sLine = start["line"] as? Int,
                let sChar = start["character"] as? Int,
                let eLine = end["line"] as? Int,
                let eChar = end["character"] as? Int
            else { return nil }
            let severity = Diagnostic.Severity(
                rawValue: (record["severity"] as? Int) ?? 1
            ) ?? .error
            let message = record["message"] as? String ?? ""
            // LSP positions are 0-indexed; convert to 1-indexed.
            return Diagnostic(
                line: sLine + 1, character: sChar + 1,
                endLine: eLine + 1, endCharacter: eChar + 1,
                severity: severity, message: message
            )
        }
        diagnostics[url] = parsed
    }
}
