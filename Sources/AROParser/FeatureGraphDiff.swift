// ============================================================
// FeatureGraphDiff.swift
// AROParser — graph-level diff between two revisions (GitLab #443)
// ============================================================
//
// Two `FeatureGraph`s in, one comparison out: which feature sets
// were added, removed or edited, and — the part a textual diff can
// never show — which *wires* between them appeared or vanished.
//
// Node identity is the feature-set name, which is what the runtime
// keys registration by. So a feature set that moved to another file
// is one unchanged node that reports `movedFile`, not a deletion in
// one file facing an insertion in another. Statement-level changes
// inside a matched pair reuse the LCS matcher in `AROGraphDiff`, so
// an edited statement stays one node marked `modified` — which is
// what keeps a comment or a conflict marker anchored to it.
//
// An edge is added or removed with no in-between: a wire either
// exists or it does not. A wire whose *ends* changed is a different
// wire.

import Foundation

/// The comparison of two application graphs.
public struct FeatureGraphDiff: Sendable {

    /// One feature set's fate across the two revisions.
    public struct NodeDiff: Sendable, Identifiable {
        /// The node's address (`FeatureGraph.Node.id`) — unique
        /// even in a repository holding many applications, where a
        /// name alone is not.
        public let id: String

        public let name: String
        /// Business activity on the surviving side (the "after"
        /// side when there is one).
        public let businessActivity: String
        public let kind: FeatureNodeKind
        public let change: GraphChange
        public let beforeFile: String?
        public let afterFile: String?
        public let statements: [StatementDiff]
        /// Activity on the before side, when it differs.
        public let previousBusinessActivity: String?

        public init(id: String? = nil, name: String, businessActivity: String,
                    kind: FeatureNodeKind, change: GraphChange,
                    beforeFile: String?, afterFile: String?,
                    statements: [StatementDiff], previousBusinessActivity: String? = nil) {
            self.id = id ?? "\(afterFile ?? beforeFile ?? "")#\(name)"
            self.name = name
            self.businessActivity = businessActivity
            self.kind = kind
            self.change = change
            self.beforeFile = beforeFile
            self.afterFile = afterFile
            self.statements = statements
            self.previousBusinessActivity = previousBusinessActivity
        }

        public func count(of change: GraphChange) -> Int {
            statements.filter { $0.change == change }.count
        }

        public var isUntouched: Bool { change == .unchanged }

        /// The feature set is the same but lives somewhere else now.
        /// A file-level diff calls that a delete plus an add; here
        /// it is a node with a new address.
        public var movedFile: Bool {
            guard let before = beforeFile, let after = afterFile else { return false }
            return before != after
        }

        /// Where to show it: the after side normally, the before
        /// side for a node that was removed.
        public var file: String { afterFile ?? beforeFile ?? "" }
    }

    /// One wire's fate. Wires are added or removed, never modified.
    public struct EdgeDiff: Sendable, Hashable {
        public let edge: FeatureGraph.Edge
        public let change: GraphChange

        public init(edge: FeatureGraph.Edge, change: GraphChange) {
            self.edge = edge
            self.change = change
        }
    }

    public let nodes: [NodeDiff]
    public let edges: [EdgeDiff]
    /// Labels for the two sides, e.g. `main` and `my-branch`.
    public let beforeLabel: String
    public let afterLabel: String

    public init(nodes: [NodeDiff], edges: [EdgeDiff],
                beforeLabel: String = "before", afterLabel: String = "after") {
        self.nodes = nodes
        self.edges = edges
        self.beforeLabel = beforeLabel
        self.afterLabel = afterLabel
    }

    // MARK: - Queries

    public func nodes(_ change: GraphChange) -> [NodeDiff] {
        nodes.filter { $0.change == change }
    }

    public func edges(_ change: GraphChange) -> [EdgeDiff] {
        edges.filter { $0.change == change }
    }

    public func node(named name: String) -> NodeDiff? {
        nodes.first { $0.name == name }
    }

    /// Statement-level totals across every feature set.
    public func statementCount(of change: GraphChange) -> Int {
        nodes.reduce(0) { $0 + $1.count(of: change) }
    }

    /// True when the two revisions describe the same graph — no
    /// node touched and no wire moved.
    public var isEmpty: Bool {
        nodes.allSatisfy { $0.isUntouched && !$0.movedFile }
            && edges.allSatisfy { $0.change == .unchanged }
    }

    /// Nodes worth rendering by default: everything a reviewer has
    /// to look at. An untouched node that a changed wire lands on
    /// counts, because that wire is the change.
    public var touchedNodes: [NodeDiff] {
        let wired = Set(edges.filter { $0.change != .unchanged }
            .flatMap { [$0.edge.from, $0.edge.to] })
        return nodes.filter { !$0.isUntouched || $0.movedFile || wired.contains($0.name) }
    }

    /// One-line summary for a CLI header or a status bar.
    public var summaryLine: String {
        let touched = nodes.filter { !$0.isUntouched }.count
        let addedEdges = edges(.added).count
        let removedEdges = edges(.removed).count
        var line = "\(touched) feature set\(touched == 1 ? "" : "s") touched · "
            + "+\(statementCount(of: .added)) −\(statementCount(of: .removed))"
            + " ~\(statementCount(of: .modified)) statements"
        if addedEdges > 0 || removedEdges > 0 {
            line += " · +\(addedEdges) −\(removedEdges) wires"
        }
        return line
    }

    // MARK: - Comparison

    public static func compare(before: FeatureGraph,
                               after: FeatureGraph,
                               beforeLabel: String = "before",
                               afterLabel: String = "after") -> FeatureGraphDiff
    {
        // Matching is by address (file + name) first, so two
        // applications in one repository that both declare
        // `Application-Start` stay two feature sets rather than one
        // that appears to be rewritten. A node whose address is
        // gone is then matched by name — that is a file move, and
        // only when the name is unambiguous on both sides.
        let pairs = match(before: before.nodes, after: after.nodes)

        var nodeDiffs: [NodeDiff] = []

        // "After" order first, so the result reads like the branch.
        for node in after.nodes {
            guard let old = pairs.beforeFor[node.id] else {
                nodeDiffs.append(NodeDiff(
                    id: node.id,
                    name: node.name,
                    businessActivity: node.businessActivity,
                    kind: node.kind,
                    change: .added,
                    beforeFile: nil,
                    afterFile: node.file,
                    statements: node.featureSet.statements.map { added($0, node.source) }))
                continue
            }
            let statements = AROGraphDiff.diffStatements(
                before: old.featureSet, after: node.featureSet,
                beforeSource: old.source, afterSource: node.source)
            let activityChanged = old.businessActivity != node.businessActivity
            let changed = statements.contains { $0.change != .unchanged } || activityChanged
            nodeDiffs.append(NodeDiff(
                id: node.id,
                name: node.name,
                businessActivity: node.businessActivity,
                kind: node.kind,
                change: changed ? .modified : .unchanged,
                beforeFile: old.file,
                afterFile: node.file,
                statements: statements,
                previousBusinessActivity: activityChanged ? old.businessActivity : nil))
        }

        for node in before.nodes where pairs.afterFor[node.id] == nil {
            nodeDiffs.append(NodeDiff(
                id: node.id,
                name: node.name,
                businessActivity: node.businessActivity,
                kind: node.kind,
                change: .removed,
                beforeFile: node.file,
                afterFile: nil,
                statements: node.featureSet.statements.map { removed($0, node.source) }))
        }

        // Edges.
        let beforeEdges = Set(before.edges)
        let afterEdges = Set(after.edges)
        var edgeDiffs: [EdgeDiff] = []
        for edge in afterEdges.union(beforeEdges).sorted() {
            let change: GraphChange
            switch (beforeEdges.contains(edge), afterEdges.contains(edge)) {
            case (true, true):   change = .unchanged
            case (false, true):  change = .added
            case (true, false):  change = .removed
            case (false, false): continue
            }
            edgeDiffs.append(EdgeDiff(edge: edge, change: change))
        }

        return FeatureGraphDiff(nodes: nodeDiffs, edges: edgeDiffs,
                                beforeLabel: beforeLabel, afterLabel: afterLabel)
    }

    // MARK: - Node matching

    /// Which "before" node each "after" node continues, and back.
    private struct Pairing {
        /// After node id → the before node it continues.
        var beforeFor: [String: FeatureGraph.Node] = [:]
        /// Before node id → the after node that continues it.
        var afterFor: [String: FeatureGraph.Node] = [:]

        mutating func pair(_ old: FeatureGraph.Node, _ new: FeatureGraph.Node) {
            beforeFor[new.id] = old
            afterFor[old.id] = new
        }

        /// Pair up what is still unmatched, keyed by `key`, and
        /// only where the key is unambiguous on both sides.
        mutating func matchLeftovers(before: [FeatureGraph.Node],
                                     after: [FeatureGraph.Node],
                                     by key: (FeatureGraph.Node) -> String)
        {
            var leftoverBefore: [String: [FeatureGraph.Node]] = [:]
            for node in before where afterFor[node.id] == nil {
                leftoverBefore[key(node), default: []].append(node)
            }
            var leftoverAfter: [String: [FeatureGraph.Node]] = [:]
            for node in after where beforeFor[node.id] == nil {
                leftoverAfter[key(node), default: []].append(node)
            }
            for (value, candidates) in leftoverAfter {
                guard candidates.count == 1,
                      let old = leftoverBefore[value], old.count == 1 else { continue }
                pair(old[0], candidates[0])
            }
        }
    }

    private static func match(before: [FeatureGraph.Node],
                              after: [FeatureGraph.Node]) -> Pairing
    {
        var pairs = Pairing()

        var beforeByID: [String: FeatureGraph.Node] = [:]
        for node in before where beforeByID[node.id] == nil { beforeByID[node.id] = node }

        // Pass 1 — same file, same name. The overwhelming case.
        for node in after {
            if let old = beforeByID[node.id] { pairs.pair(old, node) }
        }

        // Pass 2 — same file and name, different activity: a
        // feature set re-pointed at another trigger. Pass 3 — the
        // file moved. Both match only when the key identifies
        // exactly one leftover on each side; a key that several
        // leftovers share is genuinely ambiguous, and guessing
        // would report an edit where there was a delete and an
        // unrelated add.
        pairs.matchLeftovers(before: before, after: after) { "\($0.file)#\($0.name)" }
        pairs.matchLeftovers(before: before, after: after) { $0.name }

        return pairs
    }

    private static func added(_ statement: any Statement, _ source: SourceText?) -> StatementDiff {
        StatementDiff(change: .added,
                      before: nil,
                      after: AROGraphDiff.render(statement, in: source),
                      beforeLine: nil,
                      afterLine: statement.span.start.line,
                      verb: AROGraphDiff.verb(of: statement))
    }

    private static func removed(_ statement: any Statement, _ source: SourceText?) -> StatementDiff {
        StatementDiff(change: .removed,
                      before: AROGraphDiff.render(statement, in: source),
                      after: nil,
                      beforeLine: statement.span.start.line,
                      afterLine: nil,
                      verb: AROGraphDiff.verb(of: statement))
    }
}

// MARK: - Layout

/// A deterministic layered placement of the diffed graph, computed
/// once over the *union* of both revisions so a node sits at the
/// same coordinates on both sides. That is what makes two panels
/// side by side readable: the eye tracks a feature set straight
/// across instead of hunting for it.
///
/// Layer = longest path from a node with no incoming wire, which
/// puts emitters above the handlers they trigger. Cycles (ARO
/// allows them; `aro check` warns) are broken by a visit guard, so
/// the layout always terminates.
public struct FeatureGraphLayout: Sendable {
    public struct Placement: Sendable {
        /// The node's address (`file#name`).
        public let id: String
        public let name: String
        public let layer: Int
        /// Index within the layer, left to right.
        public let column: Int
    }

    public let placements: [Placement]
    public let layerCount: Int
    public let widestLayer: Int
    /// Address → index into `placements`. A renderer looks a node
    /// up once per node and twice per wire, so the linear scan this
    /// replaces was quadratic in the size of the graph.
    private let index: [String: Int]
    /// Name → address, for the one node that answers to that name.
    /// Wires are named, not addressed — the runtime resolves them
    /// by name too — so a name shared by several rendered nodes
    /// cannot be drawn, and is left out rather than guessed at.
    private let addressOfName: [String: String?]

    init(placements: [Placement], layerCount: Int, widestLayer: Int) {
        self.placements = placements
        self.layerCount = layerCount
        self.widestLayer = widestLayer
        var index: [String: Int] = [:]
        var addresses: [String: String?] = [:]
        for (offset, placement) in placements.enumerated() {
            if index[placement.id] == nil { index[placement.id] = offset }
            if let existing = addresses[placement.name] {
                // Seen before: ambiguous from here on.
                if existing != placement.id { addresses[placement.name] = .some(nil) }
            } else {
                addresses[placement.name] = .some(placement.id)
            }
        }
        self.index = index
        self.addressOfName = addresses
    }

    public func placement(of id: String) -> Placement? {
        index[id].map { placements[$0] }
    }

    /// The rendered node a wire endpoint refers to, or nil when the
    /// name is absent or ambiguous.
    public func placement(named name: String) -> Placement? {
        guard let address = addressOfName[name], let address else { return nil }
        return placement(of: address)
    }

    public static func compute(_ diff: FeatureGraphDiff,
                               nodes: [FeatureGraphDiff.NodeDiff]) -> FeatureGraphLayout
    {
        // Wires are named; nodes are addressed. Resolve each wire
        // endpoint to an address, dropping the ones that are
        // ambiguous — several applications in one repository can
        // each have a `createUser`.
        var addressOfName: [String: String?] = [:]
        for node in nodes {
            if let existing = addressOfName[node.name] {
                if existing != node.id { addressOfName[node.name] = .some(nil) }
            } else {
                addressOfName[node.name] = .some(node.id)
            }
        }
        func address(_ name: String) -> String? {
            guard let entry = addressOfName[name] else { return nil }
            return entry
        }

        let ids = nodes.map(\.id)

        var incoming: [String: [String]] = [:]
        for edge in diff.edges.map(\.edge) {
            guard let from = address(edge.from), let to = address(edge.to),
                  from != to else { continue }
            incoming[to, default: []].append(from)
        }

        var layer: [String: Int] = [:]
        func depth(_ id: String, _ visiting: Set<String>) -> Int {
            if let known = layer[id] { return known }
            // A cycle stops here: the node keeps the depth its
            // other parents give it rather than recursing forever.
            if visiting.contains(id) { return 0 }
            let parents = incoming[id] ?? []
            guard !parents.isEmpty else {
                layer[id] = 0
                return 0
            }
            let deepest = parents
                .map { depth($0, visiting.union([id])) }
                .max() ?? -1
            let value = deepest + 1
            layer[id] = value
            return value
        }
        for id in ids { _ = depth(id, []) }

        // Stable ordering inside a layer: source order of `nodes`,
        // which is "after" revision order then removals.
        var columnCursor: [Int: Int] = [:]
        var placements: [Placement] = []
        for node in nodes {
            let l = layer[node.id] ?? 0
            let column = columnCursor[l] ?? 0
            columnCursor[l] = column + 1
            placements.append(Placement(id: node.id, name: node.name,
                                        layer: l, column: column))
        }

        return FeatureGraphLayout(
            placements: placements,
            layerCount: (layer.values.max() ?? -1) + 1,
            widestLayer: columnCursor.values.max() ?? 0)
    }
}
