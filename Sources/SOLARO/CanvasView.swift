// ============================================================
// CanvasView.swift
// SOLARO — statement-level canvas (Phase 2)
// ============================================================
//
// Renders the nodes of a `CanvasGraph` as rounded-rectangle cards
// laid out by their `(x, y)` positions. Wire rendering needs a
// Bézier-path primitive that SwiftCrossUI v0.6.0 doesn't expose —
// see the Phase 2 follow-up issue for the path-API ask.

import Foundation
import SwiftCrossUI

struct CanvasView: View {
    let graph: CanvasGraph

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Canvas").font(.system(.headline))
                Spacer()
                Text("\(graph.nodes.count) node(s) · \(graph.edges.count) edge(s)")
                    .foregroundColor(.gray)
            }

            if graph.nodes.isEmpty {
                Text("This feature set has no AROStatement to render yet.")
                    .foregroundColor(.gray)
            } else {
                // Phase 2 placeholder: list nodes in their laid-out
                // order with a position annotation. Phase 2 follow-up
                // renders them as positioned rounded cards on a
                // Path-aware canvas.
                ForEach(graph.nodes, id: \.id) { node in
                    nodeRow(node)
                }
                if !graph.edges.isEmpty {
                    Text("Connections").font(.system(.headline)).padding(.top, 8)
                    ForEach(graph.edges, id: \.id) { edge in
                        edgeRow(edge)
                    }
                }
            }
        }
        .padding(8)
    }

    @ViewBuilder
    private func nodeRow(_ node: CanvasNode) -> some View {
        HStack(spacing: 8) {
            Text("●").foregroundColor(.gray)
            Text(node.verb).font(.system(.headline))
            Text("·").foregroundColor(.gray)
            Text(node.summary).foregroundColor(.gray)
            Spacer()
            Text("(\(Int(node.x)), \(Int(node.y)))").foregroundColor(.gray)
        }
    }

    @ViewBuilder
    private func edgeRow(_ edge: CanvasEdge) -> some View {
        HStack {
            Text("→")
            Text(edge.fromNodeID).foregroundColor(.gray)
            Text("→")
            Text(edge.toNodeID).foregroundColor(.gray)
            if let p = edge.preposition {
                Text("[\(p)]").foregroundColor(.gray)
            }
        }
    }
}
