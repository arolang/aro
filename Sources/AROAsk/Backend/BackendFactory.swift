// ============================================================
// BackendFactory.swift
// AROAsk - detects the best available backend
// ============================================================

import Foundation

/// Chooses an `LMBackend` based on environment and available runners.
///
/// Priority:
///   1. `ARO_ASK_ENDPOINT` set        -> `RemoteBackend`
///   2. macOS Apple Silicon            -> `NativeMLXBackend` (in-process, no deps)
///   3. `llama-server` on PATH         -> `LlamaCppBackend`
///   4. `mlx_lm` Python module         -> `MLXBackend` (subprocess)
public enum BackendFactory {
    public static func detect(
        modelIdentifier: String,
        modelPath: URL
    ) throws -> any LMBackend {
        let env = ProcessInfo.processInfo.environment

        // 1. Explicit remote endpoint
        if let endpointString = env["ARO_ASK_ENDPOINT"] ?? env["ARO_LM_ENDPOINT"],
           let endpoint = URL(string: endpointString) {
            return RemoteBackend(
                endpoint: endpoint,
                model: modelIdentifier,
                apiKey: env["ARO_ASK_API_KEY"] ?? env["ARO_LM_API_KEY"]
            )
        }

        // 2. Native MLX on Apple Silicon — preferred, no Python needed
        //    Uses HuggingFace Hub API for download/caching (not ModelManager)
        #if arch(arm64) && canImport(MLXLLM)
        return NativeMLXBackend(modelIdentifier: modelIdentifier)
        #else

        // 3. llama-server subprocess
        if ProcessRunner.which("llama-server") != nil {
            return try LlamaCppBackend(
                modelIdentifier: modelIdentifier,
                modelPath: modelPath
            )
        }

        // 4. Python mlx_lm subprocess (fallback)
        if let mlx = MLXBackend.detect() {
            return try MLXBackend(
                modelIdentifier: modelIdentifier,
                modelPath: modelPath,
                executable: mlx.executable,
                prefixArgs: mlx.prefixArgs
            )
        }

        throw LMBackendError.noBackendAvailable
        #endif
    }
}
