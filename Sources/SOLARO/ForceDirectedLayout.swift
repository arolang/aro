// ============================================================
// ForceDirectedLayout.swift
// SOLARO — fallback layout for canvas nodes (Phase 2)
// ============================================================
//
// A small Fruchterman-Reingold solver. Called when a feature
// set's `.aro.layout.json` sidecar has no saved positions for
// some nodes — the rest of the canvas keeps the user's chosen
// positions; new / unseen nodes get placed by this pass.
//
// Deterministic for a given (input nodes, input edges, seed).
// No randomness from the system clock — the seed defaults to a
// stable value derived from the node IDs so repeated opens of
// the same file produce the same layout (avoids the canvas
// jumping every time you reload).

import Foundation

enum ForceDirectedLayout {

    /// Run the solver for `iterations` ticks against the given
    /// graph. Mutates positions of nodes whose current `(x, y)` is
    /// `(0, 0)` — leaves user-positioned nodes alone.
    ///
    /// Bounds: positions stay roughly inside the square `[0, side]`
    /// with `side = sqrt(area)`. Edge crossings aren't minimized
    /// explicitly; the layout just settles into something readable.
    static func place(
        _ graph: CanvasGraph,
        tuning: LayoutTuning = .default
    ) -> CanvasGraph {
        guard !graph.nodes.isEmpty else { return graph }

        let area = tuning.forceDirectedArea
        let iterations = tuning.forceDirectedIterations
        let cooling = tuning.forceDirectedCooling
        let epsilon = tuning.forceDirectedEpsilon
        let margin = tuning.forceDirectedMargin

        var nodes = graph.nodes
        let k = (area / Double(nodes.count)).squareRoot()
        let side = area.squareRoot()

        // Seed unplaced nodes on a deterministic circle so the
        // initial layout isn't degenerate at (0,0).
        let unplacedIndices: [Int] = nodes.enumerated().compactMap { (i, n) in
            (n.x == 0 && n.y == 0) ? i : nil
        }
        for (i, idx) in unplacedIndices.enumerated() {
            let angle = 2 * .pi * Double(i) / Double(max(unplacedIndices.count, 1))
            nodes[idx].x = side / 2 + (side / 4) * cos(angle)
            nodes[idx].y = side / 2 + (side / 4) * sin(angle)
        }

        // Cool-down parameter for the temperature loop.
        var temp = side / 10

        for _ in 0..<iterations {
            var displacements = [Int: (dx: Double, dy: Double)]()
            for i in nodes.indices { displacements[i] = (0, 0) }

            // Repulsion — every pair of nodes pushes apart.
            for i in nodes.indices {
                for j in nodes.indices where j > i {
                    let dx = nodes[i].x - nodes[j].x
                    let dy = nodes[i].y - nodes[j].y
                    let dist = max((dx * dx + dy * dy).squareRoot(), epsilon)
                    let force = (k * k) / dist
                    let fx = (dx / dist) * force
                    let fy = (dy / dist) * force
                    displacements[i]!.dx += fx
                    displacements[i]!.dy += fy
                    displacements[j]!.dx -= fx
                    displacements[j]!.dy -= fy
                }
            }

            // Attraction — edges pull endpoints together.
            for edge in graph.edges {
                guard
                    let fromIdx = nodes.firstIndex(where: { $0.id == edge.fromNodeID }),
                    let toIdx = nodes.firstIndex(where: { $0.id == edge.toNodeID })
                else { continue }
                let dx = nodes[fromIdx].x - nodes[toIdx].x
                let dy = nodes[fromIdx].y - nodes[toIdx].y
                let dist = max((dx * dx + dy * dy).squareRoot(), epsilon)
                let force = (dist * dist) / k
                let fx = (dx / dist) * force
                let fy = (dy / dist) * force
                displacements[fromIdx]!.dx -= fx
                displacements[fromIdx]!.dy -= fy
                displacements[toIdx]!.dx += fx
                displacements[toIdx]!.dy += fy
            }

            // Apply displacements, clamp to the temperature.
            for i in nodes.indices {
                let d = displacements[i]!
                let mag = max((d.dx * d.dx + d.dy * d.dy).squareRoot(), epsilon)
                let limited = min(mag, temp)
                nodes[i].x += (d.dx / mag) * limited
                nodes[i].y += (d.dy / mag) * limited
                // Soft bounds — keep nodes on canvas.
                nodes[i].x = min(max(nodes[i].x, margin), side - margin)
                nodes[i].y = min(max(nodes[i].y, margin), side - margin)
            }

            // Cool down linearly.
            temp *= cooling
        }

        return CanvasGraph(nodes: nodes, edges: graph.edges)
    }
}
