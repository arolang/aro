// ============================================================
// BackendFactory.swift
// AROAsk - detects the best available backend
// ============================================================

import Foundation

/// One detection strategy. Backends register themselves so the
/// factory doesn't have to enumerate every platform combination
/// (#360). Returns nil when this backend can't run in the
/// current environment; throws on harder-to-recover failures
/// (e.g. an llama binary was found but couldn't be opened).
public protocol LMBackendProvider: Sendable {
    /// Human-readable name for logging.
    var name: String { get }
    /// Try to construct an `LMBackend` for the given model. Nil
    /// means "not this one, try the next provider" — leave
    /// errors for situations where the user clearly intended
    /// this backend (e.g. \`ARO_ASK_ENDPOINT\` set but invalid).
    func tryCreate(
        modelIdentifier: String,
        modelPath: URL
    ) async throws -> (any LMBackend)?
}

/// Chooses an `LMBackend` based on environment and available runners.
///
/// Priority:
///   macOS:  Remote > NativeMLX (in-process) > llama-server > Python mlx_lm
///   Linux:  Remote > llama-server (auto-downloaded if needed)
public enum BackendFactory {
    /// Provider list in priority order. The factory iterates
    /// and returns the first one whose `tryCreate` produces a
    /// backend. Each provider hides its own platform / dep
    /// checks behind the `tryCreate` boundary.
    static let providers: [any LMBackendProvider] = {
        var list: [any LMBackendProvider] = [
            RemoteEndpointProvider(),
        ]
        #if arch(arm64) && canImport(MLXLLM)
        list.append(NativeMLXProvider())
        #endif
        list.append(LlamaServerOnPathProvider())
        list.append(LlamaServerProvisionProvider())
        #if os(macOS)
        list.append(PythonMLXProvider())
        #endif
        return list
    }()

    public static func detect(
        modelIdentifier: String,
        modelPath: URL
    ) async throws -> any LMBackend {
        for provider in providers {
            if let backend = try await provider.tryCreate(
                modelIdentifier: modelIdentifier,
                modelPath: modelPath
            ) {
                return backend
            }
        }
        throw LMBackendError.noBackendAvailable
    }
}

// MARK: - Providers

struct RemoteEndpointProvider: LMBackendProvider {
    let name = "remote-endpoint"
    func tryCreate(modelIdentifier: String, modelPath: URL) async throws -> (any LMBackend)? {
        let env = ProcessInfo.processInfo.environment
        guard let endpointString = env["ARO_ASK_ENDPOINT"] ?? env["ARO_LM_ENDPOINT"],
              let endpoint = URL(string: endpointString) else {
            return nil
        }
        return RemoteBackend(
            endpoint: endpoint,
            model: modelIdentifier,
            apiKey: env["ARO_ASK_API_KEY"] ?? env["ARO_LM_API_KEY"]
        )
    }
}

#if arch(arm64) && canImport(MLXLLM)
struct NativeMLXProvider: LMBackendProvider {
    let name = "native-mlx"
    func tryCreate(modelIdentifier: String, modelPath: URL) async throws -> (any LMBackend)? {
        NativeMLXBackend(
            modelIdentifier: modelIdentifier,
            modelDirectory: modelPath.deletingLastPathComponent()
        )
    }
}
#endif

struct LlamaServerOnPathProvider: LMBackendProvider {
    let name = "llama-server-on-path"
    func tryCreate(modelIdentifier: String, modelPath: URL) async throws -> (any LMBackend)? {
        guard let llamaBinary = ProcessRunner.which("llama-server")
                            ?? LlamaServerProvisioner.cachedBinaryIfExists() else {
            return nil
        }
        return try LlamaCppBackend(
            modelIdentifier: modelIdentifier,
            modelPath: modelPath,
            runnerBinary: llamaBinary
        )
    }
}

struct LlamaServerProvisionProvider: LMBackendProvider {
    let name = "llama-server-provision"
    func tryCreate(modelIdentifier: String, modelPath: URL) async throws -> (any LMBackend)? {
        guard let provisioned = await LlamaServerProvisioner.findOrProvision(confirm: {
            FileHandle.standardError.write(Data(
                "  Download llama-server (~100 MB) from GitHub? [y/N] ".utf8
            ))
            guard let line = readLine() else { return false }
            return line.lowercased().hasPrefix("y")
        }) else {
            return nil
        }
        return try LlamaCppBackend(
            modelIdentifier: modelIdentifier,
            modelPath: modelPath,
            runnerBinary: provisioned
        )
    }
}

#if os(macOS)
struct PythonMLXProvider: LMBackendProvider {
    let name = "python-mlx"
    func tryCreate(modelIdentifier: String, modelPath: URL) async throws -> (any LMBackend)? {
        guard let mlx = MLXBackend.detect() else { return nil }
        return try MLXBackend(
            modelIdentifier: modelIdentifier,
            modelPath: modelPath,
            executable: mlx.executable,
            prefixArgs: mlx.prefixArgs
        )
    }
}
#endif
