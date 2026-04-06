// ============================================================
// LlamaCppBackend.swift
// AROLM - spawns llama-server and speaks its OpenAI-compatible API
// ============================================================

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Backend that spawns `llama-server` as a child process and routes chat
/// requests to its OpenAI-compatible `/v1/chat/completions` endpoint.
///
/// The process is reused for the lifetime of the `LMSession`. A PID file in
/// `~/.cache/aro/lm/` is written so future invocations in the same shell can
/// reuse the runner (handled at a higher level).
public actor LlamaCppBackend: LMBackend {
    public nonisolated let name: String = "llama.cpp"
    public nonisolated let modelIdentifier: String
    private let modelPath: URL
    private let runnerBinary: String
    private let port: Int
    private var process: Process?
    private var client: OpenAIClient?

    public init(
        modelIdentifier: String,
        modelPath: URL,
        runnerBinary: String? = nil,
        port: Int? = nil
    ) throws {
        self.modelIdentifier = modelIdentifier
        self.modelPath = modelPath
        if let r = runnerBinary {
            self.runnerBinary = r
        } else if let found = ProcessRunner.which("llama-server") {
            self.runnerBinary = found
        } else {
            throw LMBackendError.runnerNotFound("llama-server")
        }
        self.port = port ?? ProcessRunner.randomPort()
    }

    public func start() async throws {
        if process != nil { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: runnerBinary)
        p.arguments = [
            "--model", modelPath.path,
            "--host", "127.0.0.1",
            "--port", String(port),
            "--ctx-size", "8192",
            "--jinja",
        ]
        // Silence runner stdout/stderr into /dev/null so it doesn't interleave
        // with our REPL output. Logs can be re-enabled with ARO_LM_VERBOSE=1.
        if ProcessInfo.processInfo.environment["ARO_LM_VERBOSE"] == nil {
            p.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
            p.standardError = FileHandle(forWritingAtPath: "/dev/null")
        }
        try p.run()
        self.process = p

        let endpoint = URL(string: "http://127.0.0.1:\(port)")!
        self.client = OpenAIClient(endpoint: endpoint)

        // Poll until the server accepts requests or we give up.
        try await waitForReady()
    }

    private func waitForReady() async throws {
        let url = URL(string: "http://127.0.0.1:\(port)/health")!
        for _ in 0..<60 {
            var req = URLRequest(url: url)
            req.timeoutInterval = 1
            if let (_, response) = try? await URLSession.shared.data(for: req),
               let http = response as? HTTPURLResponse,
               http.statusCode == 200 {
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        throw LMBackendError.invalidResponse("llama-server did not become ready within 30s")
    }

    public func stop() async {
        process?.terminate()
        process = nil
        client = nil
    }

    public func chat(request: LMChatRequest) async throws -> LMChatResponse.Choice.Message {
        guard let client = client else { throw LMBackendError.notStarted }
        return try await client.chat(request)
    }
}
