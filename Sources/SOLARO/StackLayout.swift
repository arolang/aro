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
    /// Geometry constants surfaced as static properties so other
    /// SOLARO code that needs to mirror them (overlap detection,
    /// container-rect math, …) can read them at the call site
    /// instead of constructing a `LayoutTuning`. Driven by
    /// `LayoutTuning.default` so the values stay synchronised.
    static let assumedNodeWidth: Double = LayoutTuning.default.assumedNodeWidth
    static let assumedNodeHeight: Double = LayoutTuning.default.assumedNodeHeight
    static let fsContainerInset: Double = LayoutTuning.default.fsContainerInset
    static let fsContainerHeaderExtra: Double = LayoutTuning.default.fsContainerHeaderExtra

    static func place(
        _ graph: CanvasGraph,
        tuning: LayoutTuning = .default
    ) -> CanvasGraph {
        let rowPitch = tuning.rowPitch
        let columnPitch = tuning.columnPitch
        let featureSetGap = tuning.featureSetGap
        let leftPadding = tuning.leftPadding
        let topPadding = tuning.topPadding
        let repoColumnGap = tuning.repoColumnGap
        let repoRowPitch = tuning.repoRowPitch
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

        nodes = barycenterReorder(
            nodes: nodes,
            edges: graph.edges,
            topPadding: topPadding,
            rowPitch: rowPitch
        )
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

    /// Reorder rows inside each column so wires from earlier
    /// columns hit them in roughly the same vertical order — the
    /// classic barycenter heuristic for 1-sided crossing
    /// minimization. The first column (sources) stays in source
    /// order so reading top-to-bottom still matches the source
    /// file; later columns sort by the average y of their incoming
    /// edges' source nodes. Four sweeps converge on every real
    /// graph we've measured — the algorithm is O(E + N log N) per
    /// sweep so it's cheap even for hundred-node feature sets.
    ///
    /// Y positions get re-flowed against the column's `rowPitch`
    /// at the end of each sweep so the next sweep reads the
    /// updated geometry. Nodes the user has dragged to a specific
    /// Y (sidecar positions) are *not* preserved here — Auto Layout
    /// is the user's explicit "redo placement" signal, so it's OK
    /// to override.
    private static func barycenterReorder(
        nodes: [CanvasNode],
        edges: [CanvasEdge],
        topPadding: Double,
        rowPitch: Double
    ) -> [CanvasNode] {
        guard !nodes.isEmpty else { return nodes }
        var out = nodes

        // Group node indices by (featureSet, column-bucket). Same
        // bucket-width trick as `resolveIntraColumnOverlaps` so
        // sidecar-drifted nodes still group correctly.
        let bucket = assumedNodeWidth * 0.5
        struct ColumnKey: Hashable {
            let fs: String
            let column: Int
        }
        var byColumn: [ColumnKey: [Int]] = [:]
        for i in out.indices {
            let key = ColumnKey(
                fs: out[i].featureSetName,
                column: Int((out[i].x / bucket).rounded())
            )
            byColumn[key, default: []].append(i)
        }
        // Index edges so we can look up incoming sources per node.
        let edgesByTo = Dictionary(grouping: edges, by: { $0.toNodeID })
        let indexByID = Dictionary(
            uniqueKeysWithValues: out.enumerated().map { ($1.id, $0) }
        )

        // Four sweeps. After the first sweep the ordering tends to
        // stabilize; the extras catch graphs where moving column N
        // exposes a crossing in column N+1 that wasn't visible at
        // the first sweep's barycenter calculation.
        for _ in 0..<4 {
            // Process feature-sets independently. Within an FS,
            // process columns left to right (we sort each column
            // by the y of its predecessors, which is only stable
            // when predecessors have been positioned already).
            let fsToColumns = Dictionary(
                grouping: byColumn.keys, by: { $0.fs }
            )
            for (_, keys) in fsToColumns {
                let sortedKeys = keys.sorted { $0.column < $1.column }
                for (idx, key) in sortedKeys.enumerated() {
                    guard idx > 0 else { continue }  // first column locked
                    let indices = byColumn[key] ?? []
                    if indices.count < 2 { continue }
                    let withBarycenter: [(idx: Int, b: Double)] = indices.map { i in
                        let node = out[i]
                        let incoming = edgesByTo[node.id] ?? []
                        var sum: Double = 0
                        var count = 0
                        for e in incoming {
                            if let srcIdx = indexByID[e.fromNodeID] {
                                sum += out[srcIdx].y
                                count += 1
                            }
                        }
                        // Nodes with no incoming edge keep their
                        // current y so they don't bubble to row 0
                        // and shove unrelated rows down.
                        let bary = count > 0 ? sum / Double(count) : node.y
                        return (i, bary)
                    }
                    // Stable sort so ties preserve source order
                    // (Swift's `sort` isn't stable, so use a
                    // tiebreaker on the original y).
                    let sorted = withBarycenter.sorted {
                        if $0.b == $1.b { return out[$0.idx].y < out[$1.idx].y }
                        return $0.b < $1.b
                    }
                    // Re-flow y values along the column's rowPitch.
                    for (row, entry) in sorted.enumerated() {
                        out[entry.idx].y = topPadding + Double(row) * rowPitch
                    }
                    // Update bookkeeping for the next sweep.
                    byColumn[key] = sorted.map(\.idx)
                }
            }
        }
        return out
    }

    /// Generic node-vs-node overlap resolver: for any two cards in
    /// the same feature set whose bboxes intersect, shift the
    /// lower one down until it clears the upper one + `minGap`.
    /// Replaces the earlier column-bucket pass that missed
    /// adjacent-column overlaps (cards are 240pt wide so two cards
    /// at, say, x=840 and x=1005 are in different "columns" by
    /// step-120 bucketing but their bboxes still horizontally
    /// overlap by ~80pt, and the bucket pass left them stacked on
    /// top of each other).
    private static func resolveIntraColumnOverlaps(
        nodes: [CanvasNode],
        minGap: Double
    ) -> [CanvasNode] {
        guard !nodes.isEmpty else { return nodes }
        var out = nodes
        // Process feature sets independently — overlap between two
        // different FSes is the job of `resolveFeatureSetOverlaps`.
        let byFS = Dictionary(grouping: out.indices, by: { out[$0].featureSetName })
        for indices in byFS.values where indices.count > 1 {
            // Iterate top-down so each node's eventual position is
            // determined by the (possibly already-shifted) nodes
            // above it. Keep iterating until a pass makes no
            // changes — a single shift can introduce a new overlap
            // with the *next* row, so we re-check until stable.
            var changed = true
            var safety = indices.count * 4
            while changed && safety > 0 {
                changed = false
                safety -= 1
                let sorted = indices.sorted { out[$0].y < out[$1].y }
                for k in 1..<sorted.count {
                    let cur = sorted[k]
                    let curRect = CGRect(
                        x: out[cur].x, y: out[cur].y,
                        width: assumedNodeWidth, height: assumedNodeHeight
                    )
                    // Find the lowest-bottom predecessor whose
                    // bbox horizontally overlaps the current node.
                    var requiredTop: Double? = nil
                    for j in 0..<k {
                        let prev = sorted[j]
                        let prevRect = CGRect(
                            x: out[prev].x, y: out[prev].y,
                            width: assumedNodeWidth, height: assumedNodeHeight
                        )
                        // Only "horizontal overlap" matters here —
                        // two cards that don't share any x range
                        // can sit at the same y without overlap.
                        guard curRect.minX < prevRect.maxX,
                              curRect.maxX > prevRect.minX
                        else { continue }
                        let bottom = out[prev].y + assumedNodeHeight + minGap
                        if requiredTop == nil || bottom > requiredTop! {
                            requiredTop = bottom
                        }
                    }
                    if let requiredTop, out[cur].y < requiredTop {
                        out[cur].y = requiredTop
                        changed = true
                    }
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
