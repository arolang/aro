// ============================================================
// RemoteBackend.swift
// AROAsk - talks to an already-running OpenAI-compatible endpoint
// ============================================================

import Foundation

public actor RemoteBackend: LMBackend {
    public nonisolated let name: String = "remote"
    public nonisolated let modelIdentifier: String
    private let client: OpenAIClient

    public init(endpoint: URL, model: String, apiKey: String? = nil) {
        self.modelIdentifier = model
        self.client = OpenAIClient(endpoint: endpoint, apiKey: apiKey)
    }

    public func start() async throws {}
    public func stop() async {}

    private var lastUsage: LMUsage?

    public func chat(request: LMChatRequest) async throws -> LMChatResponse.Choice.Message {
        let (message, usage) = try await client.chatWithUsage(request)
        lastUsage = usage
        return message
    }

    public func usageOfLastChat() async -> LMUsage? { lastUsage }
}
