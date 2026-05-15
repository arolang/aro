// ============================================================
// VectorStore.swift
// AROAsk - flat-file vector store for project search
// ============================================================

import Foundation

/// A chunk of text from the project index.
public struct IndexChunk: Codable, Sendable {
    public var path: String
    public var startLine: Int
    public var endLine: Int
    public var text: String
    public var vector: [Float]
}

/// Search result with score.
public struct SearchResult: Sendable {
    public var chunk: IndexChunk
    public var score: Float
}

/// Flat JSON vector store persisted to disk.
public actor VectorStore {
    private let storeURL: URL
    private var chunks: [IndexChunk] = []

    public init(storeURL: URL) {
        self.storeURL = storeURL
    }

    public func load() throws {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return }
        let data = try Data(contentsOf: storeURL)
        chunks = try JSONDecoder().decode([IndexChunk].self, from: data)
    }

    public func save() throws {
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(chunks)
        try data.write(to: storeURL)
    }

    public func replaceAll(_ newChunks: [IndexChunk]) {
        chunks = newChunks
    }

    public func search(query: [Float], k: Int) -> [SearchResult] {
        chunks.map { chunk in
            SearchResult(chunk: chunk, score: cosineSimilarity(query, chunk.vector))
        }
        .sorted { $0.score > $1.score }
        .prefix(k)
        .map { $0 }
    }

    public var count: Int { chunks.count }

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var dot: Float = 0, normA: Float = 0, normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = sqrt(normA) * sqrt(normB)
        return denom > 0 ? dot / denom : 0
    }
}
