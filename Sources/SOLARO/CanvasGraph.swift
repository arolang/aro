// ============================================================
// CanvasGraph.swift
// SOLARO — statement-level canvas: data model
// ============================================================
//
// One node per `AROStatement`; edges follow the data flow of
// `<result>` / `<object>` pin references between statements.
// Per the wireframes on issue #228 (note 8467, figure 1).
//
// Phase 2 scope intentionally limited to the data model + layout
// + persistence. Rendering uses RoundedRectangle nodes for now;
// Bézier wires need a SwiftCrossUI Path primitive that v0.6.0
// doesn't expose. The Path follow-up is tracked separately as
// part of the Phase 2 issue thread (see #228 note 8519 followups).

import Foundation
import AROParser

/// One node on the canvas. Identity comes from the statement's
/// source span — stable across reparses as long as the statement
/// stays at the same byte offset.
struct CanvasNode: Identifiable, Equatable {
    let id: String              // "<file>:<offset>"
    let verb: String            // "Create", "Emit", "Return", …
    let summary: String         // human-readable "Create the <user> with <data>."
    let resultName: String?     // pin label, lowercase: "user"
    let objectPreposition: String?  // "with", "from", …
    let objectName: String?     // "data"
    /// All identifiers referenced by this statement (from the object
    /// slot, the valueSource expression, and with/to clauses). The
    /// edge builder matches these against previous statements'
    /// results. Synthetic placeholder names (`_expression_`) are
    /// filtered out.
    let referencedIdentifiers: [String]
    let lineHint: Int           // for tooltips
    /// Which feature set this statement belongs to. Drives the
    /// colored-container grouping in the multi-feature-set canvas.
    let featureSetName: String

    var x: Double
    var y: Double

    /// Build a node from an AST statement. `fileKey` distinguishes
    /// statements with the same offset in different files.
    static func make(from statement: AROStatement,
                     fileKey: String,
                     featureSetName: String,
                     x: Double = 0, y: Double = 0) -> CanvasNode {
        let refs = collectReferenced(statement)
        return CanvasNode(
            id: "\(fileKey):\(statement.span.start.offset)",
            verb: statement.action.verb,
            summary: statement.description,
            resultName: statement.result.base,
            objectPreposition: prepositionLabel(statement.object.preposition),
            objectName: statement.object.noun.base,
            referencedIdentifiers: refs,
            lineHint: statement.span.start.line,
            featureSetName: featureSetName,
            x: x,
            y: y
        )
    }

    /// Build a synthetic "loop header" node for a `ForEachLoop`.
    /// The body's real statements still emit their own nodes via
    /// `make(from:)`; this node is what the canvas draws so the
    /// user can see the loop boundary, jump to it in the editor,
    /// and follow data-flow into the iteration variable.
    static func makeForEach(
        loop: ForEachLoop,
        fileKey: String,
        featureSetName: String
    ) -> CanvasNode {
        var refs: Set<String> = []
        if accept(loop.collection.base) { refs.insert(loop.collection.base) }
        let collection = loop.collection.fullName
        let summary = "for each <\(loop.itemVariable)> in <\(collection)>"
        return CanvasNode(
            id: "\(fileKey):\(loop.span.start.offset):foreach",
            verb: "ForEach",
            summary: summary,
            // The iteration variable IS the loop's "result" — body
            // statements that read `<entry>` should wire back to here.
            resultName: loop.itemVariable,
            objectPreposition: "in",
            objectName: loop.collection.base,
            referencedIdentifiers: Array(refs).sorted(),
            lineHint: loop.span.start.line,
            featureSetName: featureSetName,
            x: 0, y: 0
        )
    }

    /// Same idea for the C-style `for <var> from <low> to <high>`.
    static func makeRangeLoop(
        loop: RangeLoop,
        fileKey: String,
        featureSetName: String
    ) -> CanvasNode {
        let summary = "for <\(loop.variable)> in range"
        return CanvasNode(
            id: "\(fileKey):\(loop.span.start.offset):range",
            verb: "For",
            summary: summary,
            resultName: loop.variable,
            objectPreposition: "from",
            objectName: nil,
            referencedIdentifiers: [],
            lineHint: loop.span.start.line,
            featureSetName: featureSetName,
            x: 0, y: 0
        )
    }

    /// Walks the object slot + valueSource + range modifiers to
    /// collect every `<name>` reference. Used by the edge builder.
    private static func collectReferenced(_ statement: AROStatement) -> [String] {
        var found: Set<String> = []
        if accept(statement.object.noun.base) {
            found.insert(statement.object.noun.base)
        }
        if case .expression(let e) = statement.valueSource { walk(e, into: &found) }
        if case .sinkExpression(let e) = statement.valueSource { walk(e, into: &found) }
        if let w = statement.withClause { walk(w, into: &found) }
        if let t = statement.toClause { walk(t, into: &found) }
        return Array(found).sorted()
    }

    private static func walk(_ expression: any AROParser.Expression, into out: inout Set<String>) {
        if let varRef = expression as? VariableRefExpression {
            if accept(varRef.noun.base) { out.insert(varRef.noun.base) }
        }
        // Composite expressions (binary, sub-expression, etc.) get
        // handled in a Phase 2 follow-up — VariableRef is the
        // overwhelming common case in real `.aro` source.
    }

    private static func accept(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("_")
    }
}

/// Directed edge between two nodes. Either:
/// - `.dataFlow`: A's `<result>` is consumed by B (the colored wire
///   in the canvas, drawn along the receiver's preposition).
/// - `.sequence`: B is the next statement after A in source order
///   and they're not already connected by data flow — a thin gray
///   dotted line that makes the normal program flow visible.
struct CanvasEdge: Identifiable, Equatable {
    let id: String
    let fromNodeID: String
    let toNodeID: String
    /// Preposition flavor of the receiving pin (for color on data-
    /// flow wires): "from", "to", "with", "into", "against", "for".
    /// Always nil for `.sequence` and repo edges.
    let preposition: String?
    /// What this edge represents — used by the renderer to pick
    /// stroke style + color.
    let kind: Kind

    enum Kind: Equatable, Hashable {
        case dataFlow
        case sequence
        /// Statement reads from / writes to / watches a repository
        /// node. The renderer picks a colour and arrow style per
        /// operation: read = blue solid, write = amber solid +
        /// filled arrow, watch = purple dashed.
        case repoAccess(RepoOperation)
    }

    enum RepoOperation: String, Equatable, Hashable {
        case read, write, watch
    }

    init(id: String, fromNodeID: String, toNodeID: String,
         preposition: String?, kind: Kind = .dataFlow) {
        self.id = id
        self.fromNodeID = fromNodeID
        self.toNodeID = toNodeID
        self.preposition = preposition
        self.kind = kind
    }
}

/// A repository / store entity. Lives outside any feature set —
/// it's a shared data resource the feature sets read from, write
/// to, or observe. Rendered as a separate column in the canvas so
/// the user can see at a glance which feature sets touch what.
struct RepositoryNode: Identifiable, Equatable, Hashable {
    let id: String            // "repo:<name>"
    let name: String          // "user-repository" (object-name form)
    /// Which kinds of access the program does against this repo.
    /// Drives the icon hint and the wire-typology legend.
    var usage: Usage
    var x: Double
    var y: Double

    struct Usage: OptionSet, Equatable, Hashable {
        let rawValue: Int
        static let read   = Usage(rawValue: 1 << 0)
        static let write  = Usage(rawValue: 1 << 1)
        static let watch  = Usage(rawValue: 1 << 2)
    }
}

/// Wraps a feature set's statements into a node + edge list ready
/// for layout. Pure value type — no SwiftCrossUI dependency.
struct CanvasGraph: Equatable {
    var nodes: [CanvasNode]
    var edges: [CanvasEdge]
    /// Repository entities referenced anywhere in the program.
    /// Rendered as a separate right-hand column by the canvas so
    /// reads/writes/watches connect to one shared instance per
    /// repo regardless of which feature set owns the statement.
    var repositories: [RepositoryNode] = []

    /// Build a graph spanning every feature set in `program`. Each
    /// statement is tagged with its parent feature-set name so the
    /// canvas can group / color them. Data-flow edges are still
    /// derived per feature set (no cross-feature-set edges — those
    /// belong to the Project Map view).
    static func build(program: Program, fileKey: String) -> CanvasGraph {
        var allNodes: [CanvasNode] = []
        var allEdges: [CanvasEdge] = []
        for fs in program.featureSets {
            let sub = build(featureSet: fs, fileKey: fileKey)
            allNodes.append(contentsOf: sub.nodes)
            allEdges.append(contentsOf: sub.edges)
        }
        // Detect repository entities + the wires that touch them.
        let (repos, repoEdges) = detectRepositories(
            program: program,
            statementNodes: allNodes
        )
        allEdges.append(contentsOf: repoEdges)
        return CanvasGraph(
            nodes: allNodes,
            edges: allEdges,
            repositories: repos
        )
    }

    /// Walk every statement + feature-set header for repository
    /// references. Returns the deduped repos and the wires that
    /// connect statement nodes to them.
    ///
    /// Heuristics:
    /// - Any `<foo-repository>` or `<foo-store>` object slot is a
    ///   read or a write depending on the action verb.
    /// - A feature set whose business activity ends in `Observer`
    ///   becomes a watcher of the repo named in the prefix.
    private static func detectRepositories(
        program: Program,
        statementNodes: [CanvasNode]
    ) -> (repos: [RepositoryNode], edges: [CanvasEdge]) {
        var repoUsage: [String: RepositoryNode.Usage] = [:]
        var edges: [CanvasEdge] = []

        // Statement-level read/write detection.
        for node in statementNodes {
            guard let target = repoName(in: node) else { continue }
            let op = repoOperation(for: node.verb)
            switch op {
            case .read:  repoUsage[target, default: []].insert(.read)
            case .write: repoUsage[target, default: []].insert(.write)
            case .watch: repoUsage[target, default: []].insert(.watch)
            }
            edges.append(CanvasEdge(
                id: "\(node.id)→repo:\(target)→\(op.rawValue)",
                fromNodeID: node.id,
                toNodeID: "repo:\(target)",
                preposition: nil,
                kind: .repoAccess(op)
            ))
        }

        // Feature-set-level watcher detection (`<repo> Observer`).
        for fs in program.featureSets {
            guard let watched = watchedRepoName(from: fs.businessActivity)
            else { continue }
            repoUsage[watched, default: []].insert(.watch)
            // Anchor the watch wire on the feature set's first
            // statement — gives us a real node to draw from.
            guard let first = statementNodes.first(where: { $0.featureSetName == fs.name })
            else { continue }
            edges.append(CanvasEdge(
                id: "\(first.id)→repo:\(watched)→watch-fs",
                fromNodeID: first.id,
                toNodeID: "repo:\(watched)",
                preposition: nil,
                kind: .repoAccess(.watch)
            ))
        }

        let repos = repoUsage
            .map { name, usage in
                RepositoryNode(
                    id: "repo:\(name)",
                    name: name,
                    usage: usage,
                    x: 0, y: 0
                )
            }
            .sorted { $0.name < $1.name }
        return (repos, edges)
    }

    /// Returns the repo name a statement references, if any. Looks
    /// at the object slot first; falls through to the with/to
    /// clauses by scanning `referencedIdentifiers`.
    private static func repoName(in node: CanvasNode) -> String? {
        if let obj = node.objectName, isRepoLikeName(obj) {
            return obj
        }
        for ref in node.referencedIdentifiers where isRepoLikeName(ref) {
            return ref
        }
        return nil
    }

    /// Anything ending in `-repository`, `-repo`, `-store` reads as
    /// a repository to the canvas. Deliberately heuristic — ARO's
    /// repository nouns follow this convention everywhere we've
    /// seen it.
    private static func isRepoLikeName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasSuffix("-repository")
            || lower.hasSuffix("-repo")
            || lower.hasSuffix("-store")
    }

    /// Map a verb to the kind of repo access it performs. Read
    /// verbs are the REQUEST role; write verbs are EXPORT plus
    /// Create/Update/Delete; everything else is treated as read so
    /// we never silently drop a wire.
    private static func repoOperation(for verb: String) -> CanvasEdge.RepoOperation {
        switch verb.lowercased() {
        case "retrieve", "fetch", "pull", "request", "load", "read":
            return .read
        case "store", "save", "insert", "update", "delete", "create",
             "commit", "push", "publish":
            return .write
        default:
            return .read
        }
    }

    /// `(Send Welcome Email: UserCreated Handler)` — not a repo.
    /// `(Audit User Changes: user-repository Observer)` — watches
    /// the `user-repository`.
    private static func watchedRepoName(from activity: String) -> String? {
        let trimmed = activity.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasSuffix(" observer") else { return nil }
        let prefix = String(trimmed.dropLast(" observer".count))
            .trimmingCharacters(in: .whitespaces)
        return prefix.isEmpty ? nil : prefix
    }

    /// Build a graph from a single `FeatureSet`. `fileKey` should be
    /// a stable string per `.aro` source — typically the file path.
    static func build(featureSet: FeatureSet, fileKey: String) -> CanvasGraph {
        var nodes: [CanvasNode] = []
        var edges: [CanvasEdge] = []

        // Walk depth-first so for-each / range loops expose their
        // body nodes too. Without the recursion the canvas silently
        // dropped any statement nested inside a loop (e.g.
        // DirectoryLister's `Log <entry: name>`), so the user saw
        // no nodes for code that was actually running.
        flattenStatements(
            featureSet.statements,
            featureSetName: featureSet.name,
            fileKey: fileKey,
            into: &nodes
        )

        // Build edges by `<result>` → referenced-identifier match.
        // A statement `B` reads identifier `<x>` (via object slot,
        // valueSource, or with/to clause); the most recent earlier
        // statement `A` that produces `<x>` as its result is the
        // wire's source. This catches both:
        //   - the simple form `Emit a <e: event> with <user>` where
        //     `<user>` lives in the with clause, and
        //   - the object form `Send <email> to <user>` where it's
        //     in the object slot.
        for (j, rhs) in nodes.enumerated() {
            for refName in rhs.referencedIdentifiers {
                // Scan earlier statements only — most recent
                // producer wins.
                for i in stride(from: j - 1, through: 0, by: -1) {
                    if nodes[i].resultName == refName {
                        edges.append(CanvasEdge(
                            id: "\(nodes[i].id)→\(rhs.id)→\(refName)",
                            fromNodeID: nodes[i].id,
                            toNodeID: rhs.id,
                            preposition: rhs.objectPreposition,
                            kind: .dataFlow
                        ))
                        break
                    }
                }
            }
        }

        // Sequence edges: for every adjacent pair of statements in
        // source order, draw a gray dotted line so the normal
        // execution flow reads visually — e.g. two adjacent `Log`
        // statements that share no data still flow first→second.
        // Suppressed when a data-flow edge already connects them so
        // the canvas doesn't double-wire the same pair.
        for i in 0..<max(nodes.count - 1, 0) {
            let a = nodes[i]
            let b = nodes[i + 1]
            let alreadyConnected = edges.contains { e in
                e.fromNodeID == a.id && e.toNodeID == b.id
            }
            if !alreadyConnected {
                edges.append(CanvasEdge(
                    id: "\(a.id)→\(b.id)→seq",
                    fromNodeID: a.id,
                    toNodeID: b.id,
                    preposition: nil,
                    kind: .sequence
                ))
            }
        }
        return CanvasGraph(nodes: nodes, edges: edges)
    }

    /// Flatten `statements` into the canvas-node list, recursing
    /// into ForEachLoop / RangeLoop bodies so nested AROStatements
    /// appear too. Each loop also emits a synthetic header node so
    /// the loop boundary is visible.
    private static func flattenStatements(
        _ statements: [Statement],
        featureSetName: String,
        fileKey: String,
        into nodes: inout [CanvasNode]
    ) {
        for statement in statements {
            if let aro = statement as? AROStatement {
                nodes.append(.make(from: aro,
                                   fileKey: fileKey,
                                   featureSetName: featureSetName))
            } else if let loop = statement as? ForEachLoop {
                nodes.append(.makeForEach(loop: loop,
                                          fileKey: fileKey,
                                          featureSetName: featureSetName))
                flattenStatements(loop.body,
                                  featureSetName: featureSetName,
                                  fileKey: fileKey,
                                  into: &nodes)
            } else if let loop = statement as? RangeLoop {
                nodes.append(.makeRangeLoop(loop: loop,
                                            fileKey: fileKey,
                                            featureSetName: featureSetName))
                flattenStatements(loop.body,
                                  featureSetName: featureSetName,
                                  fileKey: fileKey,
                                  into: &nodes)
            }
            // PublishStatement / MatchStatement / RequireStatement
            // intentionally skipped at this layer — they're either
            // pure metadata or have their own renderers elsewhere.
        }
    }

    /// Apply saved positions from a `LayoutSidecar`. Nodes not
    /// covered by the sidecar keep whatever position they came in
    /// with (typically 0,0; the layout pass after this fills them
    /// in).
    func withPositions(from sidecar: LayoutSidecar) -> CanvasGraph {
        var updated = self
        for i in updated.nodes.indices {
            if let saved = sidecar.nodes[updated.nodes[i].id] {
                updated.nodes[i].x = saved.x
                updated.nodes[i].y = saved.y
            }
        }
        for i in updated.repositories.indices {
            if let saved = sidecar.nodes[updated.repositories[i].id] {
                updated.repositories[i].x = saved.x
                updated.repositories[i].y = saved.y
            }
        }
        return updated
    }
}

private func prepositionLabel(_ preposition: Preposition) -> String {
    // `Preposition` is a String-backed enum; rawValue is the
    // lowercase word.
    preposition.rawValue
}
