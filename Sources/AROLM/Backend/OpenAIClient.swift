// ============================================================
// OpenAIClient.swift
// AROLM - shared HTTP client that speaks the OpenAI chat dialect
// ============================================================

import Foundation

/// Thin client around an OpenAI-compatible `/v1/chat/completions` endpoint.
/// Used by both the llama.cpp and MLX backends once their runners are up.
final class OpenAIClient: Sendable {
    let endpoint: URL
    let apiKey: String?
    private let session: URLSession

    init(endpoint: URL, apiKey: String? = nil, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.session = session
    }

    func chat(_ request: LMChatRequest) async throws -> LMChatResponse.Choice.Message {
        let url = endpoint.appendingPathComponent("v1/chat/completions")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = apiKey {
            urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        urlRequest.httpBody = try encoder.encode(request)

        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw LMBackendError.invalidResponse("non-HTTP response")
        }
        if http.statusCode < 200 || http.statusCode >= 300 {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            throw LMBackendError.httpError(http.statusCode, body)
        }
        let decoded = try JSONDecoder().decode(LMChatResponse.self, from: data)
        guard let first = decoded.choices.first else {
            throw LMBackendError.invalidResponse("no choices in response")
        }
        return first.message
    }
}
