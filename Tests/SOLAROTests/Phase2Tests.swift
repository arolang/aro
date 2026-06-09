// ============================================================
// Phase2Tests.swift
// SOLARO — canvas data model + layout (Swift Testing)
// ============================================================

import Testing
import Foundation
@testable import SOLARO
import AROParser

// Shared parser helper.
func parseARO(_ source: String) throws -> Program {
    let tokens = try Lexer(source: source).tokenize()
    let parser = Parser(tokens: tokens)
    return try parser.parse()
}

@Suite("CanvasGraph.build")
struct CanvasGraphBuildTests {

    @Test func producesNodePerStatement() throws {
        let program = try parseARO("""
        (Application-Start: Probe) {
            Create the <user> with "Ada".
            Emit a <UserCreated: event> with <user>.
            Return an <OK: status> with <user>.
        }
        """)
        let fs = try #require(program.featureSets.first)
        let graph = CanvasGraph.build(featureSet: fs, fileKey: "test.aro")

        #expect(graph.nodes.count == 3)
        #expect(graph.nodes[0].verb == "Create")
        #expect(graph.nodes[1].verb == "Emit")
        #expect(graph.nodes[2].verb == "Return")
    }

    @Test func dataFlowEdgeConnectsResultToObject() throws {
        let program = try parseARO("""
        (Application-Start: Probe) {
            Create the <user> with "Ada".
            Emit a <UserCreated: event> with <user>.
        }
        """)
        let fs = try #require(program.featureSets.first)
        let graph = CanvasGraph.build(featureSet: fs, fileKey: "test.aro")

        let dataEdges = graph.edges.filter { $0.kind == .dataFlow }
        #expect(dataEdges.count == 1)
        let edge = try #require(dataEdges.first)
        #expect(edge.fromNodeID == graph.nodes[0].id)
        #expect(edge.toNodeID == graph.nodes[1].id)
        #expect(edge.preposition == "with")
        // Pair already wired by data flow → no redundant sequence edge.
        #expect(graph.edges.allSatisfy { $0.kind == .dataFlow })
    }

    @Test func sequenceEdgeFillsAdjacentPairsWithoutDataFlow() throws {
        let program = try parseARO("""
        (Application-Start: Probe) {
            Create the <alpha> with "x".
            Create the <beta> with "y".
        }
        """)
        let fs = try #require(program.featureSets.first)
        let graph = CanvasGraph.build(featureSet: fs, fileKey: "test.aro")

        #expect(graph.nodes.count == 2)
        #expect(graph.edges.allSatisfy { $0.kind == .sequence })
        #expect(graph.edges.count == 1)
        #expect(graph.edges.first?.fromNodeID == graph.nodes[0].id)
        #expect(graph.edges.first?.toNodeID == graph.nodes[1].id)
    }

    @Test func sequenceEdgesSpanAdjacentStatements() throws {
        let program = try parseARO("""
        (Application-Start: Probe) {
            Log "first" to the <console>.
            Log "second" to the <console>.
            Log "third" to the <console>.
        }
        """)
        let fs = try #require(program.featureSets.first)
        let graph = CanvasGraph.build(featureSet: fs, fileKey: "test.aro")
        let seq = graph.edges.filter { $0.kind == .sequence }
        #expect(graph.edges.count == 2)
        #expect(seq.count == 2)
        #expect(seq[0].fromNodeID == graph.nodes[0].id)
        #expect(seq[0].toNodeID   == graph.nodes[1].id)
        #expect(seq[1].fromNodeID == graph.nodes[1].id)
        #expect(seq[1].toNodeID   == graph.nodes[2].id)
    }
}

@Suite("Layout sidecar positions")
struct LayoutSidecarPositionTests {

    @Test func appliesSavedPositionsToGraph() throws {
        let program = try parseARO("""
        (Application-Start: Probe) {
            Create the <user> with "Ada".
            Emit a <UserCreated: event> with <user>.
        }
        """)
        let fs = try #require(program.featureSets.first)
        let graph = CanvasGraph.build(featureSet: fs, fileKey: "test.aro")

        var sidecar = LayoutSidecar()
        sidecar.nodes[graph.nodes[0].id] = .init(x: 100, y: 200)
        sidecar.nodes[graph.nodes[1].id] = .init(x: 300, y: 400)

        let updated = graph.withPositions(from: sidecar)
        #expect(updated.nodes[0].x == 100)
        #expect(updated.nodes[0].y == 200)
        #expect(updated.nodes[1].x == 300)
        #expect(updated.nodes[1].y == 400)
        #expect(updated.edges == graph.edges)
    }

    @Test func positionsRoundTripThroughDiskSidecar() throws {
        let tmp = NSTemporaryDirectory() + "solaro-phase2-\(UUID().uuidString).aro"
        let url = URL(fileURLWithPath: tmp)
        defer { try? FileManager.default.removeItem(at: url) }
        try "(Application-Start: Probe) { Create the <a> with \"x\". Emit a <E: event> with <a>. }"
            .write(to: url, atomically: true, encoding: .utf8)

        let state = SourceFileState(url: url)
        let fs = try #require(state.program?.featureSets.first)
        let graph = CanvasGraph.build(featureSet: fs, fileKey: url.path)

        var saved = state.layout
        saved.nodes[graph.nodes[0].id] = .init(x: 42, y: 99)
        try saved.save(for: url)

        let reloaded = LayoutSidecar.load(for: url)
        let reGraph = graph.withPositions(from: reloaded)
        #expect(reGraph.nodes[0].x == 42)
        #expect(reGraph.nodes[0].y == 99)
        try? FileManager.default.removeItem(at: LayoutSidecar.sidecarURL(for: url))
    }
}

@Suite("ForceDirectedLayout (legacy fallback)")
struct ForceDirectedLayoutTests {

    @Test func placesAllNodesAwayFromOrigin() throws {
        let program = try parseARO("""
        (Application-Start: Probe) {
            Create the <a> with "1".
            Create the <b> with "2".
            Create the <c> with "3".
            Create the <d> with "4".
        }
        """)
        let fs = try #require(program.featureSets.first)
        let graph = CanvasGraph.build(featureSet: fs, fileKey: "t.aro")

        let placed = ForceDirectedLayout.place(graph, iterations: 30)
        for node in placed.nodes {
            #expect(!(node.x == 0 && node.y == 0))
        }
    }

    @Test func leavesPlacedNodesNonzero() throws {
        let program = try parseARO("""
        (Application-Start: Probe) {
            Create the <a> with "1".
            Create the <b> with "2".
        }
        """)
        let fs = try #require(program.featureSets.first)
        var graph = CanvasGraph.build(featureSet: fs, fileKey: "t.aro")

        graph.nodes[0].x = 500
        graph.nodes[0].y = 500

        let placed = ForceDirectedLayout.place(graph, iterations: 1)
        #expect(placed.nodes[0].x != 0)
        #expect(placed.nodes[0].y != 0)
    }
}
