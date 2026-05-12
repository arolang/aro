// ============================================================
// Embedder.swift
// AROLM - embedding strategies for project retrieval
// ============================================================

import Foundation
import Crypto

/// Strategy for turning a piece of text into a fixed-size vector.
public protocol Embedder: Sendable {
    var dimensions: Int { get }
    func embed(_ text: String) async throws -> [Float]
}

/// Deterministic, dependency-free embedder used as the default. Each token is
/// hashed to a dimension and accumulated, then L2-normalised. This gives a
/// useful "bag of hashed n-grams" similarity that requires no ML backend — a
/// pragmatic default that can later be swapped for a real embedding model
/// served by the same `LMBackend`.
public struct HashingEmbedder: Embedder {
    public let dimensions: Int

    public init(dimensions: Int = 256) {
        self.dimensions = dimensions
    }

    public func embed(_ text: String) async throws -> [Float] {
        var vec = [Float](repeating: 0, count: dimensions)
        let tokens = tokenize(text)

        // Unigrams
        for t in tokens {
            let idx = hash(t) % dimensions
            vec[idx] += 1
        }
        // Bigrams
        for i in 0..<max(0, tokens.count - 1) {
            let bigram = "\(tokens[i])_\(tokens[i + 1])"
            let idx = hash(bigram) % dimensions
            vec[idx] += 0.5
        }

        // L2 normalise
        var norm: Float = 0
        for v in vec { norm += v * v }
        norm = sqrtf(norm)
        if norm > 0 {
            for i in 0..<vec.count { vec[i] /= norm }
        }
        return vec
    }

    private func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count > 1 }
    }

    private func hash(_ s: String) -> Int {
        let digest = SHA256.hash(data: Data(s.utf8))
        var value: UInt64 = 0
        for (i, byte) in digest.prefix(8).enumerated() {
            value |= UInt64(byte) << (8 * i)
        }
        // Avoid negative modulo by bounding to non-negative Int.
        return Int(value & 0x7FFF_FFFF_FFFF_FFFF)
    }
}
