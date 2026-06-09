// ============================================================
// ProjectMap.swift
// SOLARO — Project Map data model (note 8519, Phase 3)
// ============================================================
//
// Feature-set-level graph: one node per feature set, grouped by
// business activity (the "domain" rectangle in the wireframe).
// Edges follow event emit → handler relationships across feature
// sets.
//
// Like the statement-level canvas (Phase 2), this ships the data
// model + grouping + edge derivation. Visual polish (colored
// containing rectangles, Bézier wires) needs the same Path
// primitive #232 tracks.

import Foundation
import AROParser

/// One feature set as a node in the Project Map.
struct ProjectMapNode: Identifiable, Equatable {
    let id: String              // featureSet name (unique within program)
    let featureSetName: String
    let businessActivity: String   // "User API", "Order API", … (the domain)
    let trigger: Trigger
    let statementCount: Int

    enum Trigger: Equatable {
        case applicationStart
        case applicationEnd
        case http(operationId: String)
        case eventHandler(eventName: String)
        case repositoryObserver(repoName: String)
        case userAction        // ARO-0081 — `Application.<Name>`
        case unknown
    }
}

/// Edge between two feature sets at the project level. The kind
/// distinguishes the visual treatment (dashed for event,
/// solid for `Application.X` call) from the wireframe note 8519.
struct ProjectMapEdge: Identifiable, Equatable {
    let id: String
    let from: String                // source feature-set name
    let to: String                  // target feature-set name
    let kind: Kind

    enum Kind: Equatable {
        case eventEmitSubscribe(eventName: String)
        case applicationCall(actionName: String)
    }
}

/// The full graph of one analyzed program.
struct ProjectMap: Equatable {
    let nodes: [ProjectMapNode]
    let edges: [ProjectMapEdge]

    /// All distinct business activities — used to draw the colored
    /// containing rectangles in the Phase 3 follow-up renderer.
    var domains: [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for n in nodes where !seen.contains(n.businessActivity) {
            seen.insert(n.businessActivity)
            out.append(n.businessActivity)
        }
        return out
    }

    /// Build from an array of parsed programs (one per `.aro` file
    /// in the project). Deduplicates feature sets that show up in
    /// multiple sources by name.
    static func build(from programs: [Program]) -> ProjectMap {
        var nodes: [ProjectMapNode] = []
        var emits: [(emitter: String, eventName: String)] = []

        for program in programs {
            for fs in program.featureSets {
                guard !nodes.contains(where: { $0.id == fs.name }) else { continue }
                let trigger = trigger(for: fs)
                nodes.append(.init(
                    id: fs.name,
                    featureSetName: fs.name,
                    businessActivity: fs.businessActivity,
                    trigger: trigger,
                    statementCount: fs.statements.count
                ))
                // Collect every Emit in this feature set's body so
                // we can wire edges to subscribers below.
                for s in fs.statements {
                    guard let aro = s as? AROStatement else { continue }
                    if aro.action.verb == "Emit" {
                        emits.append((emitter: fs.name, eventName: aro.result.base))
                    }
                }
            }
        }

        // Build edges.
        var edges: [ProjectMapEdge] = []

        // 1. Event emit → handler. A handler's business activity
        // doubles as the event name in ARO (`UserCreated Handler`).
        for emit in emits {
            for candidate in nodes {
                if case let .eventHandler(eventName) = candidate.trigger,
                   eventName == emit.eventName {
                    edges.append(.init(
                        id: "\(emit.emitter)→\(candidate.id)→evt(\(emit.eventName))",
                        from: emit.emitter,
                        to: candidate.id,
                        kind: .eventEmitSubscribe(eventName: emit.eventName)
                    ))
                }
            }
        }

        // 2. Application.<Name> call edges. Walk every statement's
        // verb; an action verb like `Application.SendEmail` means
        // the calling feature set depends on the user-action
        // feature set named `SendEmail`.
        for program in programs {
            for fs in program.featureSets {
                for s in fs.statements {
                    guard let aro = s as? AROStatement else { continue }
                    let verb = aro.action.verb
                    guard verb.hasPrefix("Application.") else { continue }
                    let actionName = String(verb.dropFirst("Application.".count))
                    if nodes.contains(where: { $0.id == actionName }) {
                        edges.append(.init(
                            id: "\(fs.name)→\(actionName)→call",
                            from: fs.name,
                            to: actionName,
                            kind: .applicationCall(actionName: actionName)
                        ))
                    }
                }
            }
        }

        return ProjectMap(nodes: nodes, edges: edges)
    }

    private static func trigger(for fs: FeatureSet) -> ProjectMapNode.Trigger {
        if fs.name == "Application-Start" { return .applicationStart }
        if fs.name.hasPrefix("Application-End") { return .applicationEnd }
        if fs.businessActivity.isEmpty { return .unknown }
        // The business activity carries the trigger semantics in
        // ARO. A trailing " Handler" means event-driven; the part
        // before is the event name.
        if fs.businessActivity.hasSuffix(" Handler") {
            let evt = String(fs.businessActivity.dropLast(" Handler".count))
            return .eventHandler(eventName: evt)
        }
        if fs.businessActivity.hasSuffix(" Observer") {
            let repo = String(fs.businessActivity.dropLast(" Observer".count))
            return .repositoryObserver(repoName: repo)
        }
        if fs.businessActivity == "Action" {
            return .userAction
        }
        // Anything else with a non-empty business activity is most
        // likely an HTTP feature set named after its operationId.
        return .http(operationId: fs.name)
    }
}
