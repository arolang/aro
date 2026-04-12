// ============================================================
// Embedder.swift
// AROAsk - text embedding protocol + hashing fallback
// ============================================================

import Foundation
import Crypto

/// Protocol for embedding text into a fixed-dimension vector.
public protocol Embedder: Sendable {
    var dimension: Int { get }
    func embed(_ text: String) async throws -> [Float]
}

/// A zero-dependency embedder that hashes n-grams into a fixed vector.
/// Not as good as a real embedding model but works offline with zero setup.
public struct HashingEmbedder: Embedder, Sendable {
    public let dimension: Int

    public init(dimension: Int = 256) {
        self.dimension = dimension
    }

    public func embed(_ text: String) async throws -> [Float] {
        let tokens = tokenize(text)
        var vector = [Float](repeating: 0, count: dimension)

        for i in 0..<tokens.count {
            // Unigrams
            let hash1 = stableHash(tokens[i])
            vector[hash1 % dimension] += 1.0

            // Bigrams
            if i + 1 < tokens.count {
                let hash2 = stableHash(tokens[i] + " " + tokens[i + 1])
                vector[hash2 % dimension] += 0.5
            }
        }

        // L2 normalize
        let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        if norm > 0 {
            vector = vector.map { $0 / norm }
        }
        return vector
    }

    private func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private func stableHash(_ s: String) -> Int {
        let digest = SHA256.hash(data: Data(s.utf8))
        let bytes = Array(digest)
        return abs(Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3]))
    }
}
