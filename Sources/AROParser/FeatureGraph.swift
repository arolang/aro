// ============================================================
// FeatureGraph.swift
// AROParser — application-wide feature-set graph (GitLab #443)
// ============================================================
//
// `GraphDiff.swift` answers "what happened inside this file".
// That is half of a review: an ARO application is not a pile of
// files, it is a graph. Feature sets never call each other
// directly — they are wired by events, by `Application.<Name>`
// calls and by repository observers — so the change a reviewer
// most needs to see is a *wire* that appeared or vanished. Moving
// a feature set from `users.aro` to `sources/users/users.aro`
// changes two files and nothing about the program; deleting the
// one `Emit a <UserCreated: event>` changes one line and silences
// a whole handler.
//
// So this builds the graph the runtime will build — same matching
// rules, done statically:
//
//   * `Emit a <X: event>` in A, and a feature set whose activity
//     is `X Handler`   →  A ──event(X)──▶ handler
//     (the rule `EventAnalyzer.extractEventType` applies, so the
//     system handlers it excludes are excluded here too)
//   * `Application.<Name>` called in A, `(Name: Action)` declared
//                        →  A ──call(Name)──▶ Name
//     (resolution via `UserActionRegistry.actionName(fromCallVerb:)`)
//   * `Store`/`Update`/`Delete` … `<r>` in A, and a feature set
//     whose activity is `r Observer`
//                        →  A ──observes(r)──▶ observer
//     (the runtime fires `RepositoryChangedEvent` for exactly
//     those three verbs; see ExecutionEngine.registerRepositoryObservers)
//
// Nodes are keyed by feature-set name, which is what the runtime
// keys them by, so a feature set that moved between files is the
// same node with a different `file` — not a delete plus an add.
//
// Pure AST analysis, no runtime and no UI: `aro diff --graph` and
// SOLARO's side-by-side view are both callers.

import Foundation

// MARK: - Node kind

/// What triggers a feature set. Derived from its business activity
/// with the same rules the runtime registers by.
///
/// `feature` is the fallback and covers HTTP routes: whether
/// `listUsers` is a route depends on `openapi.yaml`, which is not
/// an ARO source, so the graph does not claim to know.
public enum FeatureNodeKind: String, Sendable, Hashable, CaseIterable {
    case lifecycle
    case eventHandler
    case observer
    case action
    case feature

    /// Short label for a node badge.
    public var label: String {
        switch self {
        case .lifecycle:    return "lifecycle"
        case .eventHandler: return "handler"
        case .observer:     return "observer"
        case .action:       return "action"
        case .feature:      return "feature"
        }
    }

    public static func classify(businessActivity activity: String, name: String) -> FeatureNodeKind {
        if name.hasPrefix("Application-Start") || name.hasPrefix("Application-End") {
            return .lifecycle
        }
        if activity == "Action" { return .action }
        if FeatureGraph.observedRepository(in: activity) != nil { return .observer }
        if FeatureGraph.handledEventType(in: activity) != nil { return .eventHandler }
        return .feature
    }
}

// MARK: - Graph

/// Every feature set in an application, plus the wires between
/// them. Built from parsed sources keyed by path.
public struct FeatureGraph: Sendable {

    /// One feature set.
    public struct Node: Sendable {
        /// The node's address: `file#name`, plus the business
        /// activity when one file declares that name twice.
        ///
        /// A feature-set name is unique inside an application, but
        /// a repository can hold many — every one of the 65
        /// examples in this one declares an `Application-Start` —
        /// so the address includes the file. And a single file can
        /// legitimately declare a name twice: `Application-End:
        /// Success` and `Application-End: Error` are two feature
        /// sets that the runtime tells apart by activity.
        public let id: String

        public let name: String
        public let businessActivity: String
        public let kind: FeatureNodeKind
        /// Repo-relative path of the file it was found in.
        public let file: String
        /// The parsed feature set, for the statement-level diff.
        public let featureSet: FeatureSet
        /// The file it was parsed from, indexed for span slicing, so
        /// the diff can show the code as written rather than the
        /// AST's debug form. Nil when the caller had only an AST.
        public let source: SourceText?

        public init(id: String? = nil, name: String, businessActivity: String,
                    kind: FeatureNodeKind, file: String, featureSet: FeatureSet,
                    source: SourceText? = nil) {
            self.id = id ?? "\(file)#\(name)"
            self.name = name
            self.businessActivity = businessActivity
            self.kind = kind
            self.file = file
            self.featureSet = featureSet
            self.source = source
        }
    }

    /// One wire between two feature sets.
    public struct Edge: Sendable, Hashable, Comparable {
        public enum Kind: String, Sendable, Hashable {
            case event
            case call
            case observes
        }

        public let from: String
        public let to: String
        public let kind: Kind
        /// Event type, action name, or repository name — what the
        /// wire is *about*, drawn as the edge label.
        public let label: String

        public init(from: String, to: String, kind: Kind, label: String) {
            self.from = from
            self.to = to
            self.kind = kind
            self.label = label
        }

        public var description: String {
            "\(from) --\(kind.rawValue)(\(label))--> \(to)"
        }

        public static func < (lhs: Edge, rhs: Edge) -> Bool {
            (lhs.from, lhs.to, lhs.kind.rawValue, lhs.label)
                < (rhs.from, rhs.to, rhs.kind.rawValue, rhs.label)
        }
    }

    public let nodes: [Node]
    public let edges: [Edge]

    public init(nodes: [Node], edges: [Edge]) {
        self.nodes = nodes
        self.edges = edges
    }

    public static let empty = FeatureGraph(nodes: [], edges: [])

    public func node(named name: String) -> Node? {
        nodes.first { $0.name == name }
    }

    /// Wires leaving a node.
    public func outgoing(from name: String) -> [Edge] {
        edges.filter { $0.from == name }
    }

    // MARK: - Activity parsing

    /// Business activities the runtime routes somewhere other than
    /// the domain event bus. `AnalyzedProgram.domainHandlers`
    /// excludes exactly these, so the graph excludes them too —
    /// otherwise a `File Event Handler` would appear to be waiting
    /// for a `File Event` nobody emits.
    static let nonDomainHandlerPatterns = [
        "Socket Event Handler",
        "WebSocket Event Handler",
        "File Event Handler",
        "KeyPress Handler",
        "StateTransition Handler",
        "StateObserver",
        "Application-End",
    ]

    /// The domain event a business activity handles, or nil.
    ///
    /// Split at the *first* `" Handler"`, like the runtime, so a
    /// state-guarded handler (`UserCreated Handler<status:paid>`,
    /// ARO-0022) resolves to `UserCreated` and keeps its wire. The
    /// guard narrows which payloads reach it, not which event.
    public static func handledEventType(in activity: String) -> String? {
        guard let range = activity.range(of: " Handler") else { return nil }
        guard !nonDomainHandlerPatterns.contains(where: activity.contains) else { return nil }
        let event = String(activity[..<range.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        return event.isEmpty ? nil : event
    }

    /// The repository a business activity observes, or nil. The
    /// `-repository` test mirrors `AnalyzedProgram.repositoryObservers`,
    /// which is the list the runtime actually subscribes.
    public static func observedRepository(in activity: String) -> String? {
        guard activity.contains("-repository"),
              let range = activity.range(of: " Observer") else { return nil }
        let repository = String(activity[..<range.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        return repository.isEmpty ? nil : repository
    }

    // MARK: - Construction

    /// One file of the application: its text, and what it parsed
    /// to. Either may be absent — a file that fails to parse still
    /// belongs in the comparison (a diff is exactly when
    /// half-finished code shows up), it just contributes no nodes.
    public struct Source: Sendable {
        public let text: String?
        public let program: Program?

        public init(text: String?, program: Program?) {
            self.text = text
            self.program = program
        }
    }

    /// Build the graph from every `.aro` source in an application,
    /// keyed by repo-relative path. Files are folded into one
    /// graph because the runtime does the same — there are no
    /// imports and every feature set is globally visible.
    public static func build(files: [String: Source]) -> FeatureGraph {
        var nodes: [Node] = []
        // Deterministic order regardless of dictionary iteration:
        // by file, then by position within the file.
        for path in files.keys.sorted() {
            guard let file = files[path], let program = file.program else { continue }
            let source = file.text.map(SourceText.init)
            // A name declared twice in one file needs its activity
            // in the address to stay two nodes.
            var occurrences: [String: Int] = [:]
            for set in program.featureSets { occurrences[set.name, default: 0] += 1 }
            for set in program.featureSets {
                let id = occurrences[set.name, default: 0] > 1
                    ? "\(path)#\(set.name)#\(set.businessActivity)"
                    : "\(path)#\(set.name)"
                nodes.append(Node(
                    id: id,
                    name: set.name,
                    businessActivity: set.businessActivity,
                    kind: FeatureNodeKind.classify(
                        businessActivity: set.businessActivity, name: set.name),
                    file: path,
                    featureSet: set,
                    source: source))
            }
        }
        return FeatureGraph(nodes: nodes, edges: deriveEdges(nodes))
    }

    /// Build from ASTs alone. Statements then render from the AST
    /// rather than the file they came from.
    public static func build(sources: [String: Program?]) -> FeatureGraph {
        build(files: sources.mapValues { Source(text: nil, program: $0) })
    }

    /// Convenience for a single source (tests, the REPL, SOLARO's
    /// current-file view).
    public static func build(program: Program?, file: String = "", text: String? = nil) -> FeatureGraph {
        build(files: [file: Source(text: text, program: program)])
    }

    /// Resolve every wire. An emission with no handler, or a call
    /// to an action that doesn't exist, produces no edge — this is
    /// a picture of the program, not a diagnostic pass; `aro check`
    /// already reports both.
    static func deriveEdges(_ nodes: [Node]) -> [Edge] {
        // Target indexes, built once. Several nodes can answer to
        // the same name: a repository of examples holds dozens of
        // applications, each with its own `Application-Start` and
        // its own `UserCreated Handler`, and they are not each
        // other's handlers.
        var handlersOfEvent: [String: [Node]] = [:]
        var actionsNamed: [String: [Node]] = [:]
        var observersOfRepository: [String: [Node]] = [:]

        for node in nodes {
            switch node.kind {
            case .eventHandler:
                if let event = handledEventType(in: node.businessActivity) {
                    handlersOfEvent[event, default: []].append(node)
                }
            case .action:
                actionsNamed[node.name, default: []].append(node)
            case .observer:
                if let repository = observedRepository(in: node.businessActivity) {
                    observersOfRepository[repository, default: []].append(node)
                }
            case .lifecycle, .feature:
                break
            }
        }

        var edges: Set<Edge> = []
        for node in nodes {
            let collector = WireCollector()
            for statement in node.featureSet.statements {
                statement.accept(collector)
            }
            for event in collector.emittedEvents {
                if let target = nearest(handlersOfEvent[event], to: node) {
                    edges.insert(Edge(from: node.name, to: target.name,
                                      kind: .event, label: event))
                }
            }
            for action in collector.calledActions {
                if let target = nearest(actionsNamed[action], to: node) {
                    edges.insert(Edge(from: node.name, to: target.name,
                                      kind: .call, label: action))
                }
            }
            for repository in collector.writtenRepositories {
                if let target = nearest(observersOfRepository[repository], to: node) {
                    edges.insert(Edge(from: node.name, to: target.name,
                                      kind: .observes, label: repository))
                }
            }
        }
        return edges.sorted()
    }

    /// Pick the candidate closest to the emitting node in the file
    /// tree — the one sharing the longest directory prefix with it.
    ///
    /// Within a single application any candidate is the right one,
    /// which is the case the runtime cares about. Pointed at a
    /// repository of many applications, this keeps each one's wires
    /// inside it instead of stitching `Examples/A`'s emitter to
    /// `Examples/B`'s handler. Ties keep declaration order.
    static func nearest(_ candidates: [Node]?, to origin: Node) -> Node? {
        guard let candidates, !candidates.isEmpty else { return nil }
        guard candidates.count > 1 else { return candidates[0] }
        let originDirectory = directoryComponents(of: origin.file)
        return candidates.max { lhs, rhs in
            sharedPrefix(originDirectory, directoryComponents(of: lhs.file))
                < sharedPrefix(originDirectory, directoryComponents(of: rhs.file))
        }
    }

    private static func directoryComponents(of path: String) -> [Substring] {
        path.split(separator: "/").dropLast()
    }

    private static func sharedPrefix(_ lhs: [Substring], _ rhs: [Substring]) -> Int {
        var count = 0
        while count < lhs.count, count < rhs.count, lhs[count] == rhs[count] { count += 1 }
        return count
    }

    /// Collects the three things a feature set can be wired by.
    /// A visitor rather than an `as?` chain so a new statement node
    /// surfaces as a missing requirement instead of being silently
    /// skipped (the lesson of #434).
    private final class WireCollector: StatementVisitor {
        typealias Result = Void

        /// Verbs whose execution publishes `RepositoryChangedEvent`.
        static let repositoryWriteVerbs: Set<String> = ["store", "update", "delete"]

        var emittedEvents: Set<String> = []
        var calledActions: Set<String> = []
        var writtenRepositories: Set<String> = []

        func visit(_ node: AROStatement) {
            let verb = node.action.verb
            switch verb.lowercased() {
            case "emit":
                emittedEvents.insert(node.result.base)
            case let lowered where Self.repositoryWriteVerbs.contains(lowered):
                writtenRepositories.insert(node.object.noun.base)
            default:
                break
            }
            if let action = UserActionRegistry.actionName(fromCallVerb: verb) {
                calledActions.insert(action)
            }
        }

        func visit(_ node: WhenStatement) {
            for statement in node.body { statement.accept(self) }
        }

        func visit(_ node: MatchStatement) {
            for clause in node.cases {
                for statement in clause.body { statement.accept(self) }
            }
            for statement in node.otherwise ?? [] { statement.accept(self) }
        }

        func visit(_ node: ForEachLoop) {
            for statement in node.body { statement.accept(self) }
        }

        func visit(_ node: WhileLoop) {
            for statement in node.body { statement.accept(self) }
        }

        func visit(_ node: RangeLoop) {
            for statement in node.body { statement.accept(self) }
        }

        func visit(_ node: PipelineStatement) {
            for stage in node.stages { stage.accept(self) }
        }

        // Nodes that cannot carry a wire.
        func visit(_ node: PublishStatement) {}
        func visit(_ node: RequireStatement) {}
        func visit(_ node: BreakStatement) {}
        func visit(_ node: ErrorStatement) {}
    }
}
