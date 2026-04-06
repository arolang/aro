// ============================================================
// SearchTool.swift
// AROLM - exposes the project vector store as a model-callable tool
// ============================================================

import Foundation

public enum SearchTool {
    public static func searchProject(
        store: VectorStore,
        embedder: any Embedder
    ) -> LMToolDescriptor {
        let params: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "query": .object([
                    "type": .string("string"),
                    "description": .string("Search query")
                ]),
                "k": .object([
                    "type": .string("integer"),
                    "description": .string("Number of results to return (default 5)")
                ])
            ]),
            "required": .array([.string("query")])
        ])
        return LMToolDescriptor(
            name: "search_project",
            description: "Semantic search over the indexed project files. Returns the top-k chunks with file path and line range.",
            parameters: params
        ) { args in
            guard let q = args["query"]?.stringValue else {
                throw LMToolError.invalidArguments("missing 'query'")
            }
            let k = args["k"]?.intValue ?? 5
            let queryVector = try await embedder.embed(q)
            let results = await store.search(query: queryVector, k: k)
            if results.isEmpty {
                return "no results — run `/index` to build the project index first"
            }
            var lines: [String] = []
            for r in results {
                lines.append("\(r.chunk.path):\(r.chunk.startLine)-\(r.chunk.endLine)  (score \(String(format: "%.3f", r.score)))")
                lines.append(r.chunk.text)
                lines.append("---")
            }
            return lines.joined(separator: "\n")
        }
    }
}
