// ============================================================
// MLXBackend.swift
// AROAsk - spawns mlx_lm.server on Apple Silicon
// ============================================================

import Foundation

public actor MLXBackend: LMBackend {
    public nonisolated let name: String = "mlx"
    public nonisolated let modelIdentifier: String
    private let modelPath: URL
    /// Either the path to a standalone `mlx_lm.server` binary, or the path to
    /// `python3` when the module is invoked as `python3 -m mlx_lm.server`.
    private let executable: String
    /// Extra arguments inserted before the model flags.
    /// Empty when using a standalone binary; `["-m", "mlx_lm.server"]` when
    /// launching through python3.
    private let prefixArgs: [String]
    private let port: Int
    private var process: Process?
    private var client: OpenAIClient?

    /// Detect whether mlx-lm is available and how to invoke it.
    ///
    /// Checks in order:
    ///   1. Standalone `mlx_lm.server` binary on PATH
    ///   2. `python3 -m mlx_lm.server` (module installed in Python)
    ///
    /// Returns `nil` if neither is available.
    public static func detect() -> (executable: String, prefixArgs: [String])? {
        // 1. Standalone binary
        if let bin = ProcessRunner.which("mlx_lm.server") {
            return (bin, [])
        }
        // 2. Python module — check if the module exists
        if let python = ProcessRunner.which("python3") {
            let result = try? ProcessRunner.runAndCapture(
                executable: python,
                arguments: ["-c", "import mlx_lm; print('ok')"],
                timeout: 5
            )
            if result?.exitCode == 0 {
                return (python, ["-m", "mlx_lm.server"])
            }
        }
        return nil
    }

    public init(
        modelIdentifier: String,
        modelPath: URL,
        executable: String? = nil,
        prefixArgs: [String]? = nil,
        port: Int? = nil
    ) throws {
        self.modelIdentifier = modelIdentifier
        self.modelPath = modelPath
        if let exe = executable {
            self.executable = exe
            self.prefixArgs = prefixArgs ?? []
        } else if let detected = Self.detect() {
            self.executable = detected.executable
            self.prefixArgs = detected.prefixArgs
        } else {
            throw LMBackendError.runnerNotFound("mlx_lm (install with: pip3 install mlx-lm)")
        }
        self.port = port ?? ProcessRunner.randomPort()
    }

    public func start() async throws {
        if process != nil { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = prefixArgs + [
            "--model", modelPath.path,
            "--host", "127.0.0.1",
            "--port", String(port),
        ]
        if ProcessInfo.processInfo.environment["ARO_ASK_VERBOSE"] == nil {
            p.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
            p.standardError = FileHandle(forWritingAtPath: "/dev/null")
        }
        try p.run()
        self.process = p
        self.client = OpenAIClient(endpoint: URL(string: "http://127.0.0.1:\(port)")!)

        let probe = URL(string: "http://127.0.0.1:\(port)/v1/models")!
        for _ in 0..<120 {
            var req = URLRequest(url: probe)
            req.timeoutInterval = 1
            if let (_, response) = try? await URLSession.shared.data(for: req),
               let http = response as? HTTPURLResponse,
               http.statusCode == 200 {
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        throw LMBackendError.invalidResponse("mlx_lm.server did not become ready within 60s")
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
