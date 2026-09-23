// ============================================================
// SamplingDefaults.swift
// AROAsk - how the decoding is tuned, and why
// ============================================================
//
// GitLab #877. `temperature` was the only decoding parameter the session
// set. `NativeMLXBackend` hardcoded `topP: 0.9` at its own call site; nothing
// set `top_k`; the llama-server and OpenAI-compatible paths set neither. So
// the three backends decoded differently, and the difference was written
// down nowhere.
//
// The numbers matter more here than the defaults of a chat assistant would
// suggest, because of what the tail holds. Temperature flattens the
// distribution; only truncation makes a token *unreachable*. For ARO output
// the reachable tail is full of invented verbs and qualifiers — `Transmute`,
// `<x: sortDescending>` — which are plausible-looking, wrong, and rejected by
// `aro check` at the cost of a repair round. Tightening `top_p`/`top_k` is
// cheaper than repairing.
//
// The choices this answer is supposed to have are wording. The ones it is
// not are which verb exists.

import Foundation

/// Decoding parameters, shared by every backend.
public struct SamplingDefaults: Sendable, Equatable {
    /// Softmax temperature.
    public var temperature: Double
    /// Nucleus mass kept after truncation.
    public var topP: Double
    /// Top-k cutoff applied before sampling.
    public var topK: Int

    public init(temperature: Double, topP: Double, topK: Int) {
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
    }

    /// Tuned for generating a language with a closed vocabulary, not prose.
    ///
    /// `temperature` 0.2 is what `aro ask` already used; it is kept, and now
    /// has its reason written next to it. The model is producing ARO, whose
    /// verbs, qualifiers and prepositions are a fixed set — `aro actions`
    /// prints it — so there is nothing for a warmer temperature to find. It
    /// can only reach further into a tail where the invented ones are.
    ///
    /// `topP` 0.9 is the value the MLX backend was already using, promoted
    /// from a hardcoded call-site argument to a stated default so the other
    /// two backends stop disagreeing with it.
    ///
    /// `topK` 40 is new. `top_p` alone leaves the tail wide when the
    /// distribution is flat — which is exactly the case that produces an
    /// invented verb, because the model is unsure and several wrong tokens
    /// share the remaining mass. A hard cutoff bounds that case; on a
    /// confident distribution it binds nothing.
    public static let aroCoding = SamplingDefaults(temperature: 0.2, topP: 0.9, topK: 40)

    /// For the self-repair loop, which deliberately varies temperature so a
    /// retry does not reproduce the failure it is retrying (AskSession's
    /// `repairTempOffsets`). Truncation stays put: the point of a retry is a
    /// different *wording*, not a wider vocabulary.
    public func withTemperature(_ value: Double) -> SamplingDefaults {
        SamplingDefaults(temperature: value, topP: topP, topK: topK)
    }
}
