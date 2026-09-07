// ============================================================
// FeatureGraphTests.swift
// AROParser — application-wide feature graph + diff (GitLab #443)
// ============================================================

import Testing
@testable import AROParser

@Suite("Feature graph (#443)")
struct FeatureGraphTests {

    // MARK: - Fixtures

    private let users = """
    (createUser: User API) {
        Extract the <data> from the <request: body>.
        Store the <data> to the <user-repository>.
        Emit a <UserCreated: event> with <data>.
        Return a <Created: status> with <data>.
    }

    (listUsers: User API) {
        Retrieve the <users> from the <user-repository>.
        Return an <OK: status> with <users>.
    }
    """

    private let events = """
    (Send Welcome Email: UserCreated Handler) {
        Extract the <user> from the <event: data>.
        Log <user> to the <console>.
        Return an <OK: status> for the <notification>.
    }

    (Audit Users: user-repository Observer) {
        Log "changed" to the <console>.
        Return an <OK: status> for the <audit>.
    }
    """

    private func graph(_ files: [String: String]) throws -> FeatureGraph {
        var sources: [String: FeatureGraph.Source] = [:]
        for (path, text) in files {
            sources[path] = FeatureGraph.Source(text: text, program: try Parser.parse(text))
        }
        return FeatureGraph.build(files: sources)
    }

    private func edge(_ from: String, _ to: String,
                      _ kind: FeatureGraph.Edge.Kind, _ label: String) -> FeatureGraph.Edge {
        FeatureGraph.Edge(from: from, to: to, kind: kind, label: label)
    }

    // MARK: - Nodes

    @Test("Every feature set in every file becomes one node")
    func nodesSpanFiles() throws {
        let result = try graph(["users.aro": users, "events.aro": events])
        #expect(result.nodes.count == 4)
        #expect(result.node(named: "createUser")?.file == "users.aro")
        #expect(result.node(named: "Audit Users")?.file == "events.aro")
    }

    @Test("A node's kind comes from its business activity")
    func nodeKinds() throws {
        let source = """
        (Application-Start: Demo) {
            Log "up" to the <console>.
        }

        (Normalize: Action takes <user>) {
            Return an <OK: status> with <user>.
        }
        """
        let result = try graph(["main.aro": source, "u.aro": users, "e.aro": events])
        #expect(result.node(named: "Application-Start")?.kind == .lifecycle)
        #expect(result.node(named: "Normalize")?.kind == .action)
        #expect(result.node(named: "Send Welcome Email")?.kind == .eventHandler)
        #expect(result.node(named: "Audit Users")?.kind == .observer)
        // An operationId is only a route if openapi.yaml says so,
        // and that isn't an ARO source — so it stays a plain feature.
        #expect(result.node(named: "createUser")?.kind == .feature)
    }

    @Test("System handlers are not domain event handlers")
    func systemHandlersExcluded() {
        #expect(FeatureGraph.handledEventType(in: "File Event Handler") == nil)
        #expect(FeatureGraph.handledEventType(in: "Socket Event Handler") == nil)
        #expect(FeatureGraph.handledEventType(in: "UserCreated Handler") == "UserCreated")
        // A state guard (ARO-0022) narrows the payload, not the
        // event — the wire is still to `UserCreated`.
        #expect(FeatureGraph.handledEventType(in: "UserCreated Handler<status:paid>")
                == "UserCreated")
    }

    // MARK: - Edges

    @Test("An emitted event wires the emitter to its handler")
    func eventEdge() throws {
        let result = try graph(["users.aro": users, "events.aro": events])
        #expect(result.edges.contains(
            edge("createUser", "Send Welcome Email", .event, "UserCreated")))
    }

    @Test("A repository write wires the writer to the observer")
    func observerEdge() throws {
        let result = try graph(["users.aro": users, "events.aro": events])
        #expect(result.edges.contains(
            edge("createUser", "Audit Users", .observes, "user-repository")))
        // `Retrieve` reads; only Store/Update/Delete notify.
        #expect(!result.edges.contains(
            edge("listUsers", "Audit Users", .observes, "user-repository")))
    }

    @Test("An Application.<Name> call wires the caller to the action")
    func callEdge() throws {
        let source = """
        (createUser: User API) {
            Application.Normalize the <clean> from <data>.
            Return an <OK: status> with <clean>.
        }

        (Normalize: Action takes <user>) {
            Return an <OK: status> with <user>.
        }
        """
        let result = try graph(["a.aro": source])
        #expect(result.edges == [edge("createUser", "Normalize", .call, "Normalize")])
    }

    @Test("Wires inside a loop or a match still count")
    func nestedWires() throws {
        let source = """
        (createUsers: User API) {
            for each <row> in <rows> {
                Emit a <UserCreated: event> with <row>.
            }
            Return an <OK: status> with <rows>.
        }

        (Welcome: UserCreated Handler) {
            Return an <OK: status> for the <mail>.
        }
        """
        let result = try graph(["a.aro": source])
        #expect(result.edges == [edge("createUsers", "Welcome", .event, "UserCreated")])
    }

    @Test("An emission nobody handles is no wire")
    func orphanEmission() throws {
        let result = try graph(["users.aro": users])
        #expect(result.edges.isEmpty)
    }

    // MARK: - Diff

    private func compare(_ before: [String: String],
                         _ after: [String: String]) throws -> FeatureGraphDiff
    {
        FeatureGraphDiff.compare(before: try graph(before), after: try graph(after))
    }

    @Test("An identical application is an empty diff")
    func unchangedApplication() throws {
        let files = ["users.aro": users, "events.aro": events]
        let result = try compare(files, files)
        #expect(result.isEmpty)
        #expect(result.nodes.count == 4)
        #expect(result.nodes.allSatisfy { $0.change == .unchanged })
    }

    @Test("Added, removed and modified feature sets are classified")
    func nodeClassification() throws {
        let after = """
        (createUser: User API) {
            Extract the <data> from the <request: body>.
            Store the <data> to the <user-repository>.
            Emit a <UserCreated: event> with <data>.
            Return an <OK: status> with <data>.
        }

        (deleteUser: User API) {
            Extract the <id> from the <pathParameters: id>.
            Return an <OK: status> with <id>.
        }
        """
        let result = try compare(["users.aro": users], ["users.aro": after])
        #expect(result.nodes(.added).map(\.name) == ["deleteUser"])
        #expect(result.nodes(.removed).map(\.name) == ["listUsers"])
        #expect(result.nodes(.modified).map(\.name) == ["createUser"])
        #expect(!result.isEmpty)
    }

    @Test("A feature set that moved file is one node, not a delete plus an add")
    func movedFile() throws {
        let result = try compare(["events.aro": events],
                                 ["sources/events.aro": events])
        #expect(result.nodes(.added).isEmpty)
        #expect(result.nodes(.removed).isEmpty)
        let moved = try #require(result.node(named: "Audit Users"))
        #expect(moved.change == .unchanged)
        #expect(moved.movedFile)
        #expect(moved.beforeFile == "events.aro")
        #expect(moved.afterFile == "sources/events.aro")
        // A move changes two files and nothing about the program,
        // but it is not "no diff" either.
        #expect(!result.isEmpty)
    }

    @Test("Two applications in one repository keep their own feature sets apart")
    func duplicateNamesAcrossApplications() throws {
        // Every example application declares an `Application-Start`.
        // Keyed by name alone, the second one read looks like a
        // rewrite of the first — 144 phantom "modified" feature
        // sets when this was run over this repository (GitLab #443).
        let a = """
        (Application-Start: Alpha) {
            Log "alpha" to the <console>.
        }
        """
        let b = """
        (Application-Start: Beta) {
            Log "beta" to the <console>.
        }
        """
        let files = ["Examples/A/main.aro": a, "Examples/B/main.aro": b]
        let result = try compare(files, files)
        #expect(result.nodes.count == 2)
        #expect(result.isEmpty)
    }

    @Test("One file declaring a name twice is two feature sets")
    func duplicateNamesInOneFile() throws {
        // `Application-End: Success` and `Application-End: Error`
        // share a name; the runtime tells them apart by activity,
        // and so must the address.
        let source = """
        (Application-End: Success) {
            Log "bye" to the <console>.
        }

        (Application-End: Error) {
            Log "oops" to the <console>.
        }
        """
        let files = ["main.aro": source]
        let result = try compare(files, files)
        #expect(result.nodes.count == 2)
        #expect(Set(result.nodes.map(\.id)).count == 2)
        #expect(result.isEmpty)
    }

    @Test("A wire lands inside its own application, not the neighbour's")
    func wiresStayInTheirApplication() throws {
        let a = """
        (createUser: Alpha API) {
            Emit a <UserCreated: event> with <data>.
        }

        (Welcome Alpha: UserCreated Handler) {
            Log "a" to the <console>.
        }
        """
        let b = """
        (Welcome Beta: UserCreated Handler) {
            Log "b" to the <console>.
        }
        """
        let result = try graph(["Examples/A/app.aro": a, "Examples/B/app.aro": b])
        #expect(result.edges == [edge("createUser", "Welcome Alpha", .event, "UserCreated")])
    }

    @Test("Deleting the emission removes the wire, not the handler")
    func removedWire() throws {
        let after = """
        (createUser: User API) {
            Extract the <data> from the <request: body>.
            Store the <data> to the <user-repository>.
            Return a <Created: status> with <data>.
        }

        (listUsers: User API) {
            Retrieve the <users> from the <user-repository>.
            Return an <OK: status> with <users>.
        }
        """
        let result = try compare(["u.aro": users, "e.aro": events],
                                 ["u.aro": after, "e.aro": events])
        #expect(result.edges(.removed).map(\.edge.label) == ["UserCreated"])
        #expect(result.edges(.added).isEmpty)
        // The handler itself is untouched — and still worth showing,
        // because the wire that vanished landed on it.
        let handler = try #require(result.node(named: "Send Welcome Email"))
        #expect(handler.change == .unchanged)
        #expect(result.touchedNodes.contains { $0.name == "Send Welcome Email" })
    }

    @Test("Adding a handler adds the wire that reaches it")
    func addedWire() throws {
        let result = try compare(["u.aro": users],
                                 ["u.aro": users, "e.aro": events])
        #expect(result.edges(.added).count == 2)
        #expect(Set(result.edges(.added).map(\.edge.kind)) == [.event, .observes])
        #expect(result.summaryLine.contains("+2 −0 wires"))
    }

    @Test("Summary counts statements and wires")
    func summary() throws {
        let result = try compare(["u.aro": users, "e.aro": events],
                                 ["u.aro": users, "e.aro": events])
        #expect(result.summaryLine.contains("0 feature sets touched"))
        #expect(result.summaryLine.contains("+0 −0 ~0 statements"))
        // No wire moved, so the wire clause is left off entirely.
        #expect(!result.summaryLine.contains("wires"))
    }

    // MARK: - Rendering

    @Test("Statements render as the source, not the AST's debug form")
    func rendersSource() throws {
        let after = """
        (createUser: User API) {
            Extract the <data> from the <request: body>.
            Store the <data> to the <user-repository>.
            Emit a <UserCreated: event> with <data>.
            Return an <OK: status> with <data>.
        }
        """
        let result = try compare(["u.aro": users], ["u.aro": after])
        let node = try #require(result.node(named: "createUser"))
        let edited = try #require(node.statements.first { $0.change == .modified })
        #expect(edited.before == "Return a <Created: status> with <data>.")
        #expect(edited.after == "Return an <OK: status> with <data>.")
    }

    @Test("Without the file, statements still render from the AST")
    func rendersWithoutSource() throws {
        let program = try Parser.parse(users)
        let result = FeatureGraph.build(sources: ["u.aro": program])
        let node = try #require(result.node(named: "createUser"))
        #expect(node.source == nil)
        #expect(!AROGraphDiff.render(node.featureSet.statements[0]).isEmpty)
    }

    // MARK: - Layout

    @Test("Layout puts an emitter above the handler it triggers")
    func layering() throws {
        let result = try compare(["u.aro": users, "e.aro": events],
                                 ["u.aro": users, "e.aro": events])
        let layout = FeatureGraphLayout.compute(result, nodes: result.nodes)
        let emitter = try #require(layout.placement(named: "createUser"))
        let handler = try #require(layout.placement(named: "Send Welcome Email"))
        #expect(emitter.layer == 0)
        #expect(handler.layer == 1)
        #expect(layout.layerCount == 2)
    }

    @Test("A cycle in the wires still lays out")
    func cyclicLayout() throws {
        // A ping-pong pair: each handler emits the other's event.
        // `aro check` warns about it; the layout must not hang.
        let source = """
        (Ping: PongDone Handler) {
            Emit a <PingDone: event> with <state>.
        }

        (Pong: PingDone Handler) {
            Emit a <PongDone: event> with <state>.
        }
        """
        let both = try compare(["a.aro": source], ["a.aro": source])
        let layout = FeatureGraphLayout.compute(both, nodes: both.nodes)
        #expect(layout.placements.count == 2)
        #expect(layout.layerCount >= 1)
    }
}
