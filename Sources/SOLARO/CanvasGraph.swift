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
    /// Always nil for `.sequence` edges.
    let preposition: String?
    /// What this edge represents — used by the renderer to pick
    /// stroke style + color.
    let kind: Kind

    enum Kind: Equatable, Hashable {
        case dataFlow
        case sequence
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

/// Wraps a feature set's statements into a node + edge list ready
/// for layout. Pure value type — no SwiftCrossUI dependency.
struct CanvasGraph: Equatable {
    var nodes: [CanvasNode]
    var edges: [CanvasEdge]

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
        return CanvasGraph(nodes: allNodes, edges: allEdges)
    }

    /// Build a graph from a single `FeatureSet`. `fileKey` should be
    /// a stable string per `.aro` source — typically the file path.
    static func build(featureSet: FeatureSet, fileKey: String) -> CanvasGraph {
        var nodes: [CanvasNode] = []
        var edges: [CanvasEdge] = []

        for statement in featureSet.statements {
            guard let aro = statement as? AROStatement else { continue }
            nodes.append(.make(from: aro,
                               fileKey: fileKey,
                               featureSetName: featureSet.name))
        }

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
        return updated
    }
}

private func prepositionLabel(_ preposition: Preposition) -> String {
    // `Preposition` is a String-backed enum; rawValue is the
    // lowercase word.
    preposition.rawValue
}
