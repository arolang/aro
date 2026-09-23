// ============================================================
// SearchTool.swift
// AROAsk - semantic search over the project index
// ============================================================

import Foundation

public enum SearchTool {
    /// - Parameter memory: what this run has already been given. `nil` —
    ///   a tool built outside a run, or a test — behaves exactly as before
    ///   (GitLab #874).
    public static func searchProject(store: VectorStore, embedder: any Embedder,
                                     memory: RetrievalMemory? = nil) -> AskToolDescriptor {
        AskToolDescriptor(
            name: "search_project",
            description: "Semantic search over the indexed project files. Run /index first.",
            schema: ToolParameterSchema([
                .required("query", .string, "Search query"),
                .optional("k", .integer, "Number of results (default 5)"),
            ])
        ) { args in
            let query = try args.requireString("query")
            let k = args.int("k") ?? 5
            let vec = try await embedder.embed(query)

            // Ask for more than will be returned, so repeats can be dropped
            // and the gap filled from the next-best hits (GitLab #874). Only
            // when there is something to drop: a first search pays nothing.
            let alreadyDelivered = await memory?.isEmpty == false
            let overFetch = alreadyDelivered ? k * 3 : k
            let results = await store.search(query: vec, k: overFetch)
            if results.isEmpty {
                return ToolResultEnvelope
                    .plain("No results. Run /index to build the project index first.")
                    .encoded()
            }

            let candidates = results.map { r in
                ToolResultItem(
                    title: "\(r.chunk.path):\(r.chunk.startLine)-\(r.chunk.endLine)",
                    source: r.chunk.path,
                    body: String(r.chunk.text.prefix(200)))
            }
            let selection = await memory?.selectUnseen(from: candidates, limit: k)
            let items = selection?.kept ?? Array(candidates.prefix(k))

            if items.isEmpty {
                return ToolResultEnvelope.plain(
                    "No new results — everything this query matches has already been "
                    + "returned to you in this session.").encoded()
            }

            var lines: [String] = []
            for (item, result) in zip(items, results) {
                lines.append("\(item.title) (score: \(String(format: "%.3f", result.score)))")
                lines.append("  \(item.body ?? "")")
            }
            // Say that repeats were withheld. A result set that is quietly
            // shorter than asked for reads as "there is nothing more".
            if let notice = RetrievalMemory.skippedNotice(selection?.skipped ?? 0) {
                lines.append(notice)
            }
            return ToolResultEnvelope(count: results.count, items: items,
                                      text: lines.joined(separator: "\n")).encoded()
        }
    }
}
