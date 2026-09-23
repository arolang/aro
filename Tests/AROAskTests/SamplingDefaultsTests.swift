// ============================================================
// SamplingDefaultsTests.swift
// AROAsk — the decoding is tuned, and the same everywhere (GitLab #877)
// ============================================================

import Testing
import Foundation
@testable import AROAsk

@Suite("Sampling defaults (#877)")
struct SamplingDefaultsTests {

    /// The value `aro ask` already used, kept. The test exists so changing
    /// it is a deliberate act with a diff, rather than a number someone
    /// adjusted while debugging.
    @Test("Temperature stays where it was")
    func temperatureUnchanged() {
        #expect(SamplingDefaults.aroCoding.temperature == 0.2)
    }

    /// The MLX backend was passing 0.9 at its own call site while the other
    /// two backends passed nothing. Promoting it to a stated default is the
    /// point of the issue, so the value must not move in the process.
    @Test("topP is the value the MLX backend was already using")
    func topPMatchesTheOldHardcodedValue() {
        #expect(SamplingDefaults.aroCoding.topP == 0.9)
    }

    /// Temperature flattens the distribution; only truncation makes a token
    /// unreachable. `top_p` alone leaves the tail wide when the distribution
    /// is flat — which is exactly the case that produces an invented verb.
    @Test("topK is set, not left open")
    func topKIsBounded() {
        #expect(SamplingDefaults.aroCoding.topK == 40)
    }

    /// The self-repair loop varies temperature so a retry does not reproduce
    /// the failure it is retrying. The point of that retry is a different
    /// wording, not a wider vocabulary — so truncation must not move with it.
    @Test("Varying temperature leaves the truncation alone")
    func temperatureVariationKeepsTruncation() {
        let warmer = SamplingDefaults.aroCoding.withTemperature(0.9)
        #expect(warmer.temperature == 0.9)
        #expect(warmer.topP == SamplingDefaults.aroCoding.topP)
        #expect(warmer.topK == SamplingDefaults.aroCoding.topK)
    }

    /// The session's defaults are the shared ones — that is what stops the
    /// three backends decoding differently.
    @Test("The session config defaults to the shared values")
    func sessionConfigUsesTheDefaults() {
        let config = AskSessionConfig(workingDirectory: URL(fileURLWithPath: "/tmp"))
        #expect(config.temperature == SamplingDefaults.aroCoding.temperature)
        #expect(config.topP == SamplingDefaults.aroCoding.topP)
        #expect(config.topK == SamplingDefaults.aroCoding.topK)
    }

    @Test("A request carries the knobs to the backend")
    func requestCarriesTheKnobs() throws {
        let request = LMChatRequest(
            model: "m", messages: [], tools: nil, temperature: 0.2,
            stream: false, maxTokens: 1024,
            topP: SamplingDefaults.aroCoding.topP,
            topK: SamplingDefaults.aroCoding.topK)
        let json = try JSONEncoder().encode(request)
        let text = try #require(String(data: json, encoding: .utf8))
        // The wire names, which is what an OpenAI-compatible server reads.
        #expect(text.contains("top_p"))
        #expect(text.contains("top_k"))
        #expect(text.contains("max_tokens"))
    }
}
