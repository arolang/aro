// ============================================================
// RemoteBackend.swift
// AROLM - talks to an already-running OpenAI-compatible endpoint
// ============================================================

import Foundation

/// Backend that does not spawn any runner — it assumes a compatible server is
/// already listening at the configured endpoint. Used when the user sets
/// `ARO_LM_ENDPOINT`, or as a fallback when no local runner is available.
public actor RemoteBackend: LMBackend {
    public nonisolated let name: String = "remote"
    public nonisolated let modelIdentifier: String
    private let client: OpenAIClient

    public init(endpoint: URL, model: String, apiKey: String? = nil) {
        self.modelIdentifier = model
        self.client = OpenAIClient(endpoint: endpoint, apiKey: apiKey)
    }

    public func start() async throws {
        // Nothing to start — assume the endpoint is live.
    }

    public func stop() async {}

    public func chat(request: LMChatRequest) async throws -> LMChatResponse.Choice.Message {
        try await client.chat(request)
    }
}
