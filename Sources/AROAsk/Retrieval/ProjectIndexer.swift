// ============================================================
// ProjectIndexer.swift
// AROAsk - walks project directory, chunks files, embeds
// ============================================================

import Foundation

/// Walks the working directory, splits files into chunks, and embeds them.
public struct ProjectIndexer: Sendable {
    public let root: URL
    public let embedder: any Embedder
    private let chunkSize: Int
    private let extensions: Set<String>

    public init(
        root: URL,
        embedder: any Embedder,
        chunkSize: Int = 40,
        extensions: Set<String> = ["aro", "md", "swift", "yaml", "json", "toml", "py", "rs", "c"]
    ) {
        self.root = root
        self.embedder = embedder
        self.chunkSize = chunkSize
        self.extensions = extensions
    }

    public func buildIndex() async throws -> [IndexChunk] {
        var chunks: [IndexChunk] = []
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }

        while let item = enumerator.nextObject() as? URL {
            // Skip hidden dirs and common noise
            let components = item.pathComponents
            if components.contains(where: { $0.hasPrefix(".") || $0 == "node_modules" || $0 == ".build" }) {
                continue
            }
            guard extensions.contains(item.pathExtension) else { continue }
            guard let isFile = try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile, isFile else { continue }
            guard let data = try? Data(contentsOf: item),
                  let text = String(data: data, encoding: .utf8) else { continue }

            let relativePath = item.path.replacingOccurrences(of: root.path + "/", with: "")
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

            // Split into overlapping chunks
            var start = 0
            while start < lines.count {
                let end = min(start + chunkSize, lines.count)
                let chunkText = lines[start..<end].joined(separator: "\n")
                let vector = try await embedder.embed(chunkText)
                chunks.append(IndexChunk(
                    path: relativePath,
                    startLine: start + 1,
                    endLine: end,
                    text: chunkText,
                    vector: vector
                ))
                start += chunkSize / 2  // 50% overlap
            }
        }
        return chunks
    }
}
