// ============================================================
// StackLayout.swift
// SOLARO — default canvas placement (deterministic, readable)
// ============================================================
//
// The force-directed solver in ForceDirectedLayout.swift produces
// chaotic results for feature sets with many statements (Computations
// has 46 in one body) — overlapping cards, wires that loop back on
// themselves. Real source code is sequential, so a sequential column
// layout reads better as the default.
//
// Stack layout rules:
//   * Statements stack top-to-bottom in source order.
//   * Each new "branch" (a statement that depends on more than
//     one earlier statement that isn't its immediate predecessor)
//     starts a new column to the right.
//   * Rows have a fixed vertical pitch; columns a fixed horizontal
//     pitch.
//   * Nodes whose sidecar `(x, y)` is non-zero keep their saved
//     position — the user already moved them.

import Foundation

enum StackLayout {

    /// Apply the column-stack default to `graph`. Saved positions
    /// (non-zero in the input) are preserved.
    static func place(
        _ graph: CanvasGraph,
        rowPitch: Double = 78,
        columnPitch: Double = 320,
        leftPadding: Double = 40,
        topPadding: Double = 40
    ) -> CanvasGraph {
        var nodes = graph.nodes
        guard !nodes.isEmpty else { return graph }

        // Build a quick lookup so we can branch when consecutive
        // statements have multiple incoming edges.
        let edgesByTo: [String: [CanvasEdge]] = Dictionary(
            grouping: graph.edges,
            by: { $0.toNodeID }
        )

        var nextRow = 0
        var column = 0

        for i in nodes.indices {
            // Preserve user-saved positions.
            if nodes[i].x != 0 || nodes[i].y != 0 {
                continue
            }

            // Branch right when this node has incoming edges from
            // outside the immediately preceding row — visually flags
            // a fork in the flow.
            if i > 0 {
                let incoming = edgesByTo[nodes[i].id] ?? []
                let previousID = nodes[i - 1].id
                let comesOnlyFromPrev = incoming.allSatisfy { $0.fromNodeID == previousID }
                if !incoming.isEmpty, !comesOnlyFromPrev {
                    column += 1
                    nextRow = 0
                }
            }

            nodes[i].x = leftPadding + Double(column) * columnPitch
            nodes[i].y = topPadding + Double(nextRow) * rowPitch
            nextRow += 1
        }

        return CanvasGraph(nodes: nodes, edges: graph.edges)
    }
}
