// ============================================================
// SearchTool.swift
// AROAsk - semantic search over the project index
// ============================================================

import Foundation

public enum SearchTool {
    public static func searchProject(store: VectorStore, embedder: any Embedder) -> AskToolDescriptor {
        let params: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "query": .object([
                    "type": .string("string"),
                    "description": .string("Search query")
                ]),
                "k": .object([
                    "type": .string("integer"),
                    "description": .string("Number of results (default 5)")
                ])
            ]),
            "required": .array([.string("query")])
        ])
        return AskToolDescriptor(
            name: "search_project",
            description: "Semantic search over the indexed project files. Run /index first.",
            parameters: params
        ) { args in
            guard let query = args["query"]?.stringValue else {
                throw AskToolError.invalidArguments("missing 'query'")
            }
            let k = args["k"]?.intValue ?? 5
            let vec = try await embedder.embed(query)
            let results = await store.search(query: vec, k: k)
            if results.isEmpty {
                return "No results. Run /index to build the project index first."
            }
            var lines: [String] = []
            for r in results {
                lines.append("\(r.chunk.path):\(r.chunk.startLine)-\(r.chunk.endLine) (score: \(String(format: "%.3f", r.score)))")
                // Include a preview of the chunk text
                let preview = r.chunk.text.prefix(200)
                lines.append("  \(preview)")
            }
            return lines.joined(separator: "\n")
        }
    }
}
