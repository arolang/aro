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
    ///
    /// When the graph contains multiple feature sets, each gets its
    /// own pair of horizontal columns (with `featureSetGap` between
    /// neighbouring feature sets) so the canvas can render colored
    /// containing boxes around each group.
    static func place(
        _ graph: CanvasGraph,
        rowPitch: Double = 78,
        columnPitch: Double = 320,
        featureSetGap: Double = 80,
        leftPadding: Double = 40,
        topPadding: Double = 56,    // extra room for the FS header
        repoColumnGap: Double = 120,
        repoRowPitch: Double = 96
    ) -> CanvasGraph {
        var nodes = graph.nodes
        var repos = graph.repositories
        guard !nodes.isEmpty else { return graph }

        let edgesByTo: [String: [CanvasEdge]] = Dictionary(
            grouping: graph.edges,
            by: { $0.toNodeID }
        )

        // Walk in source order. Track:
        //   * which feature set we're currently laying out,
        //   * the X origin of that feature set's first column,
        //   * the local row + column inside the feature set.
        var currentFS: String? = nil
        var fsBaseX: Double = leftPadding
        var localColumn = 0
        var localRow = 0
        var lastNodeWasUserPositioned = false

        for i in nodes.indices {
            if currentFS != nodes[i].featureSetName {
                // New feature set — flush to the right of the
                // previous one. The previous feature set's footprint
                // is bounded by whatever node X+columnPitch reached.
                if currentFS != nil {
                    fsBaseX += Double(localColumn + 1) * columnPitch + featureSetGap
                }
                currentFS = nodes[i].featureSetName
                localColumn = 0
                localRow = 0
                lastNodeWasUserPositioned = false
            }

            // Preserve user-saved positions.
            if nodes[i].x != 0 || nodes[i].y != 0 {
                lastNodeWasUserPositioned = true
                continue
            }

            // Branch right inside the feature set when a node has
            // incoming edges from outside the immediately preceding
            // row.
            if localRow > 0, !lastNodeWasUserPositioned {
                let incoming = edgesByTo[nodes[i].id] ?? []
                let previousID = nodes[i - 1].id
                let comesOnlyFromPrev = incoming.allSatisfy { $0.fromNodeID == previousID }
                if !incoming.isEmpty, !comesOnlyFromPrev {
                    localColumn += 1
                    localRow = 0
                }
            }
            lastNodeWasUserPositioned = false

            nodes[i].x = fsBaseX + Double(localColumn) * columnPitch
            nodes[i].y = topPadding + Double(localRow) * rowPitch
            localRow += 1
        }

        // Place repository entities in a column to the right of every
        // laid-out feature set. Repos with a non-zero saved position
        // (from the sidecar) keep their spot — the user moved them.
        let rightmost = nodes.map(\.x).max() ?? 0
        let repoX = rightmost + columnPitch + repoColumnGap
        for i in repos.indices where repos[i].x == 0 && repos[i].y == 0 {
            repos[i].x = repoX
            repos[i].y = topPadding + Double(i) * repoRowPitch
        }

        return CanvasGraph(
            nodes: nodes,
            edges: graph.edges,
            repositories: repos,
            loops: graph.loops
        )
    }
}
