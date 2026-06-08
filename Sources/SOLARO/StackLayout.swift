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
    /// Width and height assumed for statement-node cards during
     /// auto-layout — kept in sync with `CanvasView.nodeWidth` /
     /// `nodeHeight` so the overlap-resolve pass uses the same box
     /// the renderer draws.
    static let assumedNodeWidth: Double = 240
    static let assumedNodeHeight: Double = 84
    /// Padding the feature-set container draws around its child
    /// nodes (see `FeatureSetContainersLayer.groupedFeatureSets`).
    /// Mirrored here so overlap detection uses the same rect the
    /// renderer paints, otherwise resolving "no node overlap" would
    /// still leave visible container borders crossing through cards.
    static let fsContainerInset: Double = 14
    static let fsContainerHeaderExtra: Double = 28

    static func place(
        _ graph: CanvasGraph,
        rowPitch: Double = 104,   // assumedNodeHeight (84) + 20pt gap
        columnPitch: Double = 320,
        featureSetGap: Double = 80,
        leftPadding: Double = 40,
        // Big enough that the *feature-set container's* top edge
        // (which sits `inset + headerExtra` = 42pt above the first
        // node) lands well below the file-tab + breadcrumb strips
        // the workspace stacks on top of the canvas. Previously 56,
        // which put the container ~14pt from the canvas top and
        // visually crowded the breadcrumb row.
        topPadding: Double = 110,
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

        nodes = resolveIntraColumnOverlaps(
            nodes: nodes,
            minGap: 20
        )
        nodes = resolveFeatureSetOverlaps(
            nodes: nodes,
            gap: featureSetGap
        )

        return CanvasGraph(
            nodes: nodes,
            edges: graph.edges,
            repositories: repos,
            loops: graph.loops
        )
    }

    /// Within each feature set, group nodes into columns by their X
    /// coordinate and ensure no two nodes in the same column overlap
    /// vertically. Catches both the auto-layout case where the row
    /// pitch was undersized for a tall card, and the user-dragged
    /// case where the sidecar holds positions that no longer fit
    /// the current node height. Always shifts the *lower* node down
    /// so the existing top-down execution order stays intact.
    private static func resolveIntraColumnOverlaps(
        nodes: [CanvasNode],
        minGap: Double
    ) -> [CanvasNode] {
        guard !nodes.isEmpty else { return nodes }
        var out = nodes
        // Group by (feature set, column bucket). Column bucket uses
        // a quantization step half the assumed card width — any two
        // x positions within that bucket are treated as the same
        // visual column, which tolerates a few pixels of sidecar
        // drift without false-bucketing nearby columns together.
        let bucket = assumedNodeWidth * 0.5
        var groups: [String: [Int]] = [:]   // key → indices into `out`
        for i in out.indices {
            let n = out[i]
            let columnKey = Int((n.x / bucket).rounded())
            groups["\(n.featureSetName)|\(columnKey)", default: []].append(i)
        }
        for indices in groups.values where indices.count > 1 {
            // Sort by current y so the lower node yields, never the
            // upper one. Stable across re-runs.
            let sorted = indices.sorted { out[$0].y < out[$1].y }
            for k in 1..<sorted.count {
                let prev = sorted[k - 1]
                let cur  = sorted[k]
                let minY = out[prev].y + assumedNodeHeight + minGap
                if out[cur].y < minY {
                    out[cur].y = minY
                }
            }
        }
        return out
    }

    /// Walk feature-set bounding rects left to right and shift any
    /// FS whose container rect overlaps an earlier FS's rect to the
    /// right by the overlap amount + `gap`. Catches the case where
    /// the column-stack math placed two FSes side-by-side correctly
    /// but a single tall / dragged statement from one of them
    /// happens to land inside the neighbour's container (#?). The
    /// shift is applied uniformly to every node of the overlapping
    /// FS so its internal layout is preserved.
    private static func resolveFeatureSetOverlaps(
        nodes: [CanvasNode],
        gap: Double
    ) -> [CanvasNode] {
        guard !nodes.isEmpty else { return nodes }
        var out = nodes
        // Iterate until no overlaps remain. A single shift can push
        // FS_n into FS_{n+1}'s space, so we re-check after each pass.
        // Hard-cap at the FS count: each FS can shift at most once
        // per other FS, so n² iterations is the worst case.
        let allNames = Array(NSOrderedSet(array: out.map { $0.featureSetName })) as! [String]
        for _ in 0..<allNames.count {
            var shifted = false
            let rects = featureSetRects(in: out)
            // Walk in left-to-right order so shifting a later FS
            // can't cascade back into already-resolved earlier ones.
            let ordered = rects.sorted { $0.value.minX < $1.value.minX }
            for i in 1..<ordered.count {
                let (name, rect) = ordered[i]
                // Find the largest overlap with any earlier rect —
                // shift just enough to clear them all in one go.
                var maxOverlap: Double = 0
                for j in 0..<i {
                    let other = ordered[j].value
                    if rect.intersects(other) {
                        maxOverlap = max(maxOverlap, other.maxX - rect.minX)
                    }
                }
                if maxOverlap > 0 {
                    let delta = maxOverlap + gap
                    for k in out.indices where out[k].featureSetName == name {
                        out[k].x += delta
                    }
                    shifted = true
                    break  // restart with updated rects
                }
            }
            if !shifted { break }
        }
        return out
    }

    /// Bounding rect per feature set, mirroring
    /// `FeatureSetContainersLayer.groupedFeatureSets()` so overlap
    /// detection matches what the user sees on screen.
    private static func featureSetRects(
        in nodes: [CanvasNode]
    ) -> [String: CGRect] {
        var bounds: [String: CGRect] = [:]
        for node in nodes {
            let rect = CGRect(
                x: node.x, y: node.y,
                width: assumedNodeWidth, height: assumedNodeHeight
            )
            if let existing = bounds[node.featureSetName] {
                bounds[node.featureSetName] = existing.union(rect)
            } else {
                bounds[node.featureSetName] = rect
            }
        }
        let inset = fsContainerInset
        let header = fsContainerHeaderExtra
        return bounds.mapValues { core in
            CGRect(
                x: core.minX - inset,
                y: core.minY - inset - header,
                width: core.width + inset * 2,
                height: core.height + inset * 2 + header
            )
        }
    }
}
