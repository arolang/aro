// ============================================================
// MLXBackend.swift
// AROLM - spawns mlx_lm.server on Apple Silicon
// ============================================================

import Foundation

/// Backend that spawns `mlx_lm.server` (Python, ships with the `mlx-lm`
/// package) and routes chat requests to its OpenAI-compatible endpoint.
///
/// Used as an Apple-Silicon fallback when `llama-server` is not available.
public actor MLXBackend: LMBackend {
    public nonisolated let name: String = "mlx"
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
        } else if let found = ProcessRunner.which("mlx_lm.server") {
            self.runnerBinary = found
        } else {
            throw LMBackendError.runnerNotFound("mlx_lm.server")
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
        ]
        if ProcessInfo.processInfo.environment["ARO_LM_VERBOSE"] == nil {
            p.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
            p.standardError = FileHandle(forWritingAtPath: "/dev/null")
        }
        try p.run()
        self.process = p
        self.client = OpenAIClient(endpoint: URL(string: "http://127.0.0.1:\(port)")!)

        // mlx_lm.server has no /health endpoint — probe /v1/models.
        let probe = URL(string: "http://127.0.0.1:\(port)/v1/models")!
        for _ in 0..<60 {
            var req = URLRequest(url: probe)
            req.timeoutInterval = 1
            if let (_, response) = try? await URLSession.shared.data(for: req),
               let http = response as? HTTPURLResponse,
               http.statusCode == 200 {
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        throw LMBackendError.invalidResponse("mlx_lm.server did not become ready within 30s")
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
