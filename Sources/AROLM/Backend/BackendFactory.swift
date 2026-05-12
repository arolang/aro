// ============================================================
// BackendFactory.swift
// AROLM - detects the best available backend
// ============================================================

import Foundation

/// Chooses an `LMBackend` based on environment and available runners.
///
/// Priority:
///   1. `ARO_LM_ENDPOINT` set -> `RemoteBackend`
///   2. `llama-server` on PATH -> `LlamaCppBackend`
///   3. `mlx_lm.server` on PATH -> `MLXBackend`
public enum BackendFactory {
    public static func detect(
        modelIdentifier: String,
        modelPath: URL
    ) throws -> LMBackend {
        let env = ProcessInfo.processInfo.environment

        if let endpointString = env["ARO_LM_ENDPOINT"],
           let endpoint = URL(string: endpointString) {
            return RemoteBackend(
                endpoint: endpoint,
                model: modelIdentifier,
                apiKey: env["ARO_LM_API_KEY"]
            )
        }

        if ProcessRunner.which("llama-server") != nil {
            return try LlamaCppBackend(
                modelIdentifier: modelIdentifier,
                modelPath: modelPath
            )
        }

        if ProcessRunner.which("mlx_lm.server") != nil {
            return try MLXBackend(
                modelIdentifier: modelIdentifier,
                modelPath: modelPath
            )
        }

        throw LMBackendError.noBackendAvailable
    }
}
