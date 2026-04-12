// ============================================================
// BackendFactory.swift
// AROAsk - detects the best available backend
// ============================================================

import Foundation

/// Chooses an `LMBackend` based on environment and available runners.
///
/// Priority:
///   1. `ARO_ASK_ENDPOINT` set -> `RemoteBackend`
///   2. `llama-server` on PATH -> `LlamaCppBackend`
///   3. `mlx_lm` Python module or standalone binary -> `MLXBackend`
public enum BackendFactory {
    public static func detect(
        modelIdentifier: String,
        modelPath: URL
    ) throws -> any LMBackend {
        let env = ProcessInfo.processInfo.environment

        // Also support legacy ARO_LM_ENDPOINT for backwards compat
        if let endpointString = env["ARO_ASK_ENDPOINT"] ?? env["ARO_LM_ENDPOINT"],
           let endpoint = URL(string: endpointString) {
            return RemoteBackend(
                endpoint: endpoint,
                model: modelIdentifier,
                apiKey: env["ARO_ASK_API_KEY"] ?? env["ARO_LM_API_KEY"]
            )
        }

        if ProcessRunner.which("llama-server") != nil {
            return try LlamaCppBackend(
                modelIdentifier: modelIdentifier,
                modelPath: modelPath
            )
        }

        // Check for mlx_lm as standalone binary OR python3 module
        if let mlx = MLXBackend.detect() {
            return try MLXBackend(
                modelIdentifier: modelIdentifier,
                modelPath: modelPath,
                executable: mlx.executable,
                prefixArgs: mlx.prefixArgs
            )
        }

        throw LMBackendError.noBackendAvailable
    }
}
