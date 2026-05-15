// ============================================================
// VectorStore.swift
// AROLM - flat in-memory cosine similarity store
// ============================================================

import Foundation

/// A chunk of project text with the vector it was embedded to.
public struct IndexedChunk: Codable, Sendable {
    public let path: String
    public let startLine: Int
    public let endLine: Int
    public let text: String
    public let mtime: TimeInterval
    public let contentHash: String
    public let vector: [Float]

    public init(
        path: String,
        startLine: Int,
        endLine: Int,
        text: String,
        mtime: TimeInterval,
        contentHash: String,
        vector: [Float]
    ) {
        self.path = path
        self.startLine = startLine
        self.endLine = endLine
        self.text = text
        self.mtime = mtime
        self.contentHash = contentHash
        self.vector = vector
    }
}

public struct SearchResult: Sendable {
    public let chunk: IndexedChunk
    public let score: Float
}

/// Flat cosine-similarity vector store, backed by a JSON file on disk.
///
/// Works well for project-sized corpora (<100k chunks). Load once per session
/// and search in memory — no external dependency.
public actor VectorStore {
    public let storeURL: URL
    public private(set) var chunks: [IndexedChunk] = []

    public init(storeURL: URL) {
        self.storeURL = storeURL
    }

    public func load() throws {
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            chunks = []
            return
        }
        let data = try Data(contentsOf: storeURL)
        chunks = try JSONDecoder().decode([IndexedChunk].self, from: data)
    }

    public func save() throws {
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(chunks)
        try data.write(to: storeURL, options: [.atomic])
    }

    public func replaceAll(_ newChunks: [IndexedChunk]) {
        self.chunks = newChunks
    }

    public func search(query: [Float], k: Int) -> [SearchResult] {
        guard !chunks.isEmpty else { return [] }
        var scored: [(Float, Int)] = []
        scored.reserveCapacity(chunks.count)
        for (i, chunk) in chunks.enumerated() {
            let score = cosine(query, chunk.vector)
            scored.append((score, i))
        }
        scored.sort { $0.0 > $1.0 }
        return scored.prefix(k).map { SearchResult(chunk: chunks[$0.1], score: $0.0) }
    }

    private nonisolated func cosine(_ a: [Float], _ b: [Float]) -> Float {
        let n = min(a.count, b.count)
        var dot: Float = 0
        for i in 0..<n { dot += a[i] * b[i] }
        return dot
    }
}
