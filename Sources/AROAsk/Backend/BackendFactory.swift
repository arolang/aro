// ============================================================
// BackendFactory.swift
// AROAsk - detects the best available backend
// ============================================================

import Foundation

/// Chooses an `LMBackend` based on environment and available runners.
///
/// Priority:
///   macOS:  Remote > NativeMLX (in-process) > llama-server > Python mlx_lm
///   Linux:  Remote > llama-server (auto-downloaded if needed)
public enum BackendFactory {
    public static func detect(
        modelIdentifier: String,
        modelPath: URL
    ) async throws -> any LMBackend {
        let env = ProcessInfo.processInfo.environment

        // 1. Explicit remote endpoint (any platform)
        if let endpointString = env["ARO_ASK_ENDPOINT"] ?? env["ARO_LM_ENDPOINT"],
           let endpoint = URL(string: endpointString) {
            return RemoteBackend(
                endpoint: endpoint,
                model: modelIdentifier,
                apiKey: env["ARO_ASK_API_KEY"] ?? env["ARO_LM_API_KEY"]
            )
        }

        // 2. macOS: native MLX (in-process, no external deps)
        #if arch(arm64) && canImport(MLXLLM)
        return NativeMLXBackend(modelIdentifier: modelIdentifier)
        #else

        // 3. llama-server — on PATH, in cache, or auto-downloaded
        if let llamaBinary = ProcessRunner.which("llama-server")
                          ?? LlamaServerProvisioner.cachedBinaryIfExists() {
            return try LlamaCppBackend(
                modelIdentifier: modelIdentifier,
                modelPath: modelPath,
                runnerBinary: llamaBinary
            )
        }

        // 4. Auto-provision llama-server (Linux: download from GitHub releases)
        if let provisioned = await LlamaServerProvisioner.findOrProvision(confirm: {
            FileHandle.standardError.write(Data(
                "  Download llama-server (~100 MB) from GitHub? [y/N] ".utf8
            ))
            guard let line = readLine() else { return false }
            return line.lowercased().hasPrefix("y")
        }) {
            return try LlamaCppBackend(
                modelIdentifier: modelIdentifier,
                modelPath: modelPath,
                runnerBinary: provisioned
            )
        }

        // 5. macOS fallback: Python mlx_lm subprocess
        #if os(macOS)
        if let mlx = MLXBackend.detect() {
            return try MLXBackend(
                modelIdentifier: modelIdentifier,
                modelPath: modelPath,
                executable: mlx.executable,
                prefixArgs: mlx.prefixArgs
            )
        }
        #endif

        throw LMBackendError.noBackendAvailable
        #endif
    }
}
