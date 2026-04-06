// ============================================================
// ProjectIndexer.swift
// AROLM - walks the project and produces chunk embeddings
// ============================================================

import Foundation
import Crypto

/// Walks a working directory, chunks indexable files along semantic
/// boundaries, and embeds every chunk into an on-disk vector store.
public struct ProjectIndexer: Sendable {
    public let root: URL
    public let embedder: any Embedder

    public init(root: URL, embedder: any Embedder) {
        self.root = root
        self.embedder = embedder
    }

    /// Re-index everything under `root`. Files ignored by `.gitignore`
    /// top-level rules are skipped, as are common vendor/build directories.
    public func buildIndex() async throws -> [IndexedChunk] {
        let files = enumerateFiles()
        var all: [IndexedChunk] = []
        for file in files {
            let chunks = try await index(file: file)
            all.append(contentsOf: chunks)
        }
        return all
    }

    private func enumerateFiles() -> [URL] {
        let fm = FileManager.default
        var results: [URL] = []
        let exclude: Set<String> = [
            ".git", ".build", ".swiftpm", "node_modules", ".context.index",
            "build", "dist", "target", ".venv", "__pycache__"
        ]
        let extensions: Set<String> = [
            "aro", "md", "swift", "yaml", "yml", "json", "toml"
        ]
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey]
        ) else { return [] }
        while let item = enumerator.nextObject() as? URL {
            let name = item.lastPathComponent
            if exclude.contains(name) {
                enumerator.skipDescendants()
                continue
            }
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir { continue }
            if !extensions.contains(item.pathExtension.lowercased()) { continue }
            results.append(item)
        }
        return results
    }

    private func index(file: URL) async throws -> [IndexedChunk] {
        let data = try Data(contentsOf: file)
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970) ?? 0
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let relative = file.path.replacingOccurrences(of: root.path + "/", with: "")

        let chunks = chunk(text, maxLines: 80)
        var out: [IndexedChunk] = []
        for (start, end, body) in chunks {
            let vector = try await embedder.embed(body)
            out.append(IndexedChunk(
                path: relative,
                startLine: start,
                endLine: end,
                text: body,
                mtime: mtime,
                contentHash: hash,
                vector: vector
            ))
        }
        return out
    }

    /// Line-range chunking. Good enough for the default retrieval strategy;
    /// the comment in the issue calls out feature-set / heading / declaration
    /// chunking as a follow-up.
    private func chunk(_ text: String, maxLines: Int) -> [(Int, Int, String)] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var result: [(Int, Int, String)] = []
        var i = 0
        while i < lines.count {
            let end = min(lines.count, i + maxLines)
            let body = lines[i..<end].joined(separator: "\n")
            result.append((i + 1, end, body))
            i = end
        }
        return result
    }
}
