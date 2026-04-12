// ============================================================
// LlamaCppBackend.swift
// AROAsk - spawns llama-server and speaks its OpenAI-compatible API
// ============================================================

import Foundation

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
        if ProcessInfo.processInfo.environment["ARO_ASK_VERBOSE"] == nil {
            p.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
            p.standardError = FileHandle(forWritingAtPath: "/dev/null")
        }
        try p.run()
        self.process = p
        let endpoint = URL(string: "http://127.0.0.1:\(port)")!
        self.client = OpenAIClient(endpoint: endpoint)
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
