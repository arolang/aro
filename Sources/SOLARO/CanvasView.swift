// ============================================================
// CanvasView.swift
// SOLARO — statement-level canvas with Bézier wires (#232)
// ============================================================
//
// Renders nodes as rounded-rectangle outlines and wires as cubic
// Béziers, color-coded per receiving preposition (see
// `WireColor`). All drawn via SwiftCrossUI's `Shape` protocol +
// `Path` cubic curves.
//
// Layered as:
//   1. One `WiresShape` per preposition color (so each color
//      gets its own stroke)
//   2. `NodesShape` (rounded-rectangle outlines)
//   3. Text labels positioned via padding for the verb + summary
//
// Hit-testing — clicking individual nodes to enter their detail
// view — is the next layer; v1 of #232 ships the visual.

import Foundation
import SwiftCrossUI

struct CanvasView: View {
    let graph: CanvasGraph

    /// Fixed canvas size — Phase 2 follow-up wires this to the
    /// containing pane's bounds when pan/zoom land.
    private let width: Double = 900
    private let height: Double = 600
    /// Node box dimensions for hit-area calculations and labels.
    private let nodeWidth: Double = 180
    private let nodeHeight: Double = 56

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
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
                ZStack(alignment: .topLeading) {
                    // Wires — one shape per preposition color so
                    // each gets its own stroke color via
                    // `.foregroundColor(_)`. Empty preposition
                    // segments are drawn last in grey.
                    ForEach(prepositionGroups, id: \.0) { entry in
                        WiresShape(segments: entry.1)
                            .foregroundColor(WireColor.color(for: entry.0))
                            .frame(width: width, height: height)
                    }
                    // Node bodies — rounded outlines per node.
                    NodesShape(
                        nodes: graph.nodes,
                        nodeWidth: nodeWidth,
                        nodeHeight: nodeHeight
                    )
                    .foregroundColor(.gray)
                    .frame(width: width, height: height)
                }
                .frame(width: width, height: height)
            }
        }
        .padding(8)
    }

    /// Segments grouped by their preposition string. Each group
    /// renders as one WiresShape so its color stays consistent.
    private var prepositionGroups: [(String, [WireSegment])] {
        let segments = buildSegments()
        let grouped = Dictionary(grouping: segments.0, by: { segments.1[$0.id] ?? "" })
        // Stable order for the ForEach.
        return grouped.keys.sorted().map { ($0, grouped[$0] ?? []) }
    }

    /// Build the WireSegment array + a sidecar map from segment
    /// id → preposition (used to color the group).
    private func buildSegments() -> ([WireSegment], [String: String]) {
        var segs: [WireSegment] = []
        var prepBySegId: [String: String] = [:]
        let nodeIndex: [String: CanvasNode] = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
        for edge in graph.edges {
            guard
                let fromNode = nodeIndex[edge.fromNodeID],
                let toNode = nodeIndex[edge.toNodeID]
            else { continue }
            // Wire from the right edge of the from-node to the
            // left edge of the to-node, both at vertical center.
            let start = SIMD2<Double>(fromNode.x + nodeWidth, fromNode.y + nodeHeight / 2)
            let end = SIMD2<Double>(toNode.x, toNode.y + nodeHeight / 2)
            let seg = WireSegment(id: edge.id, start: start, end: end)
            segs.append(seg)
            prepBySegId[edge.id] = edge.preposition ?? ""
        }
        return (segs, prepBySegId)
    }
}

// MARK: - NodesShape

/// Shape that draws every node as a rounded-rectangle outline at
/// its `(x, y)` position. Single foregroundColor for now; the
/// wire-color-from-preposition mapping for *nodes* is a Phase 2
/// follow-up.
struct NodesShape: Shape {
    let nodes: [CanvasNode]
    let nodeWidth: Double
    let nodeHeight: Double

    func path(in bounds: Path.Rect) -> Path {
        var path = Path()
        let r = 10.0
        // de Casteljau constant for approximating a quarter circle
        // with a cubic Bézier. Magic constant; keeps the corners
        // visually smooth.
        let k = 0.5522847498 * r
        for node in nodes {
            let x = node.x
            let y = node.y
            let w = nodeWidth
            let h = nodeHeight
            // Inline the rounded-rect actions into the outer path so
            // the renderer sees one continuous outline per node. We
            // deliberately do NOT use `addSubpath` because that wraps
            // sub-actions in a `.subpath(...)` envelope, which both
            // hides the curves from path-walking tooling and (on at
            // least one backend) disables the stroke pass.
            path = path
                .move(to: SIMD2(x + r, y))
                .addLine(to: SIMD2(x + w - r, y))
                .addCubicCurve(
                    control1: SIMD2(x + w - r + k, y),
                    control2: SIMD2(x + w, y + r - k),
                    to: SIMD2(x + w, y + r))
                .addLine(to: SIMD2(x + w, y + h - r))
                .addCubicCurve(
                    control1: SIMD2(x + w, y + h - r + k),
                    control2: SIMD2(x + w - r + k, y + h),
                    to: SIMD2(x + w - r, y + h))
                .addLine(to: SIMD2(x + r, y + h))
                .addCubicCurve(
                    control1: SIMD2(x + r - k, y + h),
                    control2: SIMD2(x, y + h - r + k),
                    to: SIMD2(x, y + h - r))
                .addLine(to: SIMD2(x, y + r))
                .addCubicCurve(
                    control1: SIMD2(x, y + r - k),
                    control2: SIMD2(x + r - k, y),
                    to: SIMD2(x + r, y))
        }
        return path
    }
}
