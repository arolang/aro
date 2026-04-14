// ============================================================
// VectorStoreTests.swift
// ============================================================

import XCTest
@testable import AROLM

final class VectorStoreTests: XCTestCase {
    func testEmbedderProducesDeterministicUnitVectors() async throws {
        let embedder = HashingEmbedder(dimensions: 128)
        let v1 = try await embedder.embed("hello world")
        let v2 = try await embedder.embed("hello world")
        XCTAssertEqual(v1, v2)
        let norm = v1.reduce(Float(0)) { $0 + $1 * $1 }
        XCTAssertEqual(norm, 1, accuracy: 0.001)
    }

    func testSearchReturnsClosestChunk() async throws {
        let embedder = HashingEmbedder(dimensions: 128)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("aro-lm-vec-\(UUID().uuidString).json")
        let store = VectorStore(storeURL: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let chunk1 = IndexedChunk(
            path: "a.md",
            startLine: 1, endLine: 1,
            text: "openapi contract yaml schema",
            mtime: 0,
            contentHash: "",
            vector: try await embedder.embed("openapi contract yaml schema")
        )
        let chunk2 = IndexedChunk(
            path: "b.md",
            startLine: 1, endLine: 1,
            text: "event bus handler",
            mtime: 0,
            contentHash: "",
            vector: try await embedder.embed("event bus handler")
        )
        await store.replaceAll([chunk1, chunk2])

        let query = try await embedder.embed("openapi")
        let results = await store.search(query: query, k: 1)
        XCTAssertEqual(results.first?.chunk.path, "a.md")
    }
}
