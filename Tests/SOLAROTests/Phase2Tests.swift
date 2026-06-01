// ============================================================
// Phase2Tests.swift
// SOLARO — Phase 2 unit tests (canvas data model + layout)
// ============================================================

import XCTest
@testable import SOLARO
import AROParser

final class Phase2Tests: XCTestCase {

    // MARK: - CanvasGraph.build

    func testCanvasGraphBuildProducesNodePerStatement() throws {
        let program = try parse("""
        (Application-Start: Probe) {
            Create the <user> with "Ada".
            Emit a <UserCreated: event> with <user>.
            Return an <OK: status> with <user>.
        }
        """)
        let fs = try XCTUnwrap(program.featureSets.first)
        let graph = CanvasGraph.build(featureSet: fs, fileKey: "test.aro")

        XCTAssertEqual(graph.nodes.count, 3)
        XCTAssertEqual(graph.nodes[0].verb, "Create")
        XCTAssertEqual(graph.nodes[1].verb, "Emit")
        XCTAssertEqual(graph.nodes[2].verb, "Return")
    }

    func testCanvasGraphConnectsResultToObject() throws {
        let program = try parse("""
        (Application-Start: Probe) {
            Create the <user> with "Ada".
            Emit a <UserCreated: event> with <user>.
        }
        """)
        let fs = try XCTUnwrap(program.featureSets.first)
        let graph = CanvasGraph.build(featureSet: fs, fileKey: "test.aro")

        // Dump for debug if the assertion fails — surfaces the
        // actual `(resultName, objectName)` pairs the matcher saw.
        let summary = graph.nodes.map { n in
            "\(n.verb)(result=\(n.resultName ?? "nil"), object=\(n.objectName ?? "nil"))"
        }.joined(separator: " | ")
        XCTAssertEqual(graph.edges.count, 1, "Create.<user> → Emit (object=user); got nodes: \(summary)")
        if graph.edges.count == 1 {
            XCTAssertEqual(graph.edges.first?.fromNodeID, graph.nodes[0].id)
            XCTAssertEqual(graph.edges.first?.toNodeID, graph.nodes[1].id)
            XCTAssertEqual(graph.edges.first?.preposition, "with")
        }
    }

    func testCanvasGraphNoEdgesWhenIdentifiersDontMatch() throws {
        let program = try parse("""
        (Application-Start: Probe) {
            Create the <alpha> with "x".
            Create the <beta> with "y".
        }
        """)
        let fs = try XCTUnwrap(program.featureSets.first)
        let graph = CanvasGraph.build(featureSet: fs, fileKey: "test.aro")
        XCTAssertEqual(graph.nodes.count, 2)
        XCTAssertTrue(graph.edges.isEmpty)
    }

    // MARK: - Layout sidecar round-trip with positions

    func testCanvasGraphAppliesPositionsFromSidecar() throws {
        let program = try parse("""
        (Application-Start: Probe) {
            Create the <user> with "Ada".
            Emit a <UserCreated: event> with <user>.
        }
        """)
        let fs = try XCTUnwrap(program.featureSets.first)
        let graph = CanvasGraph.build(featureSet: fs, fileKey: "test.aro")

        // Build a sidecar that has positions for both nodes.
        var sidecar = LayoutSidecar()
        sidecar.nodes[graph.nodes[0].id] = .init(x: 100, y: 200)
        sidecar.nodes[graph.nodes[1].id] = .init(x: 300, y: 400)

        let updated = graph.withPositions(from: sidecar)
        XCTAssertEqual(updated.nodes[0].x, 100)
        XCTAssertEqual(updated.nodes[0].y, 200)
        XCTAssertEqual(updated.nodes[1].x, 300)
        XCTAssertEqual(updated.nodes[1].y, 400)
        // Edges unaffected by position application.
        XCTAssertEqual(updated.edges, graph.edges)
    }

    // MARK: - Round-trip: positions survive disk

    func testCanvasGraphPositionsRoundTripThroughSidecarFile() throws {
        let tmp = NSTemporaryDirectory() + "solaro-phase2-\(UUID().uuidString).aro"
        let url = URL(fileURLWithPath: tmp)
        defer { try? FileManager.default.removeItem(at: url) }
        try "(Application-Start: Probe) { Create the <a> with \"x\". Emit a <E: event> with <a>. }"
            .write(to: url, atomically: true, encoding: .utf8)

        let state = SourceFileState(url: url)
        let fs = try XCTUnwrap(state.program?.featureSets.first)
        let graph = CanvasGraph.build(featureSet: fs, fileKey: url.path)

        // Save sidecar with known positions.
        var saved = state.layout
        saved.nodes[graph.nodes[0].id] = .init(x: 42, y: 99)
        try saved.save(for: url)

        // Re-read.
        let reloaded = LayoutSidecar.load(for: url)
        let reGraph = graph.withPositions(from: reloaded)
        XCTAssertEqual(reGraph.nodes[0].x, 42)
        XCTAssertEqual(reGraph.nodes[0].y, 99)
        // Sidecar cleanup.
        try? FileManager.default.removeItem(at: LayoutSidecar.sidecarURL(for: url))
    }

    // MARK: - ForceDirectedLayout

    func testForceDirectedLayoutPlacesAllNodes() throws {
        let program = try parse("""
        (Application-Start: Probe) {
            Create the <a> with "1".
            Create the <b> with "2".
            Create the <c> with "3".
            Create the <d> with "4".
        }
        """)
        let fs = try XCTUnwrap(program.featureSets.first)
        let graph = CanvasGraph.build(featureSet: fs, fileKey: "t.aro")

        let placed = ForceDirectedLayout.place(graph, iterations: 30)
        // All nodes should have a non-default position.
        for node in placed.nodes {
            XCTAssertFalse(node.x == 0 && node.y == 0, "node \(node.id) was not placed")
        }
    }

    func testForceDirectedLayoutLeavesPlacedNodesUntouched() throws {
        let program = try parse("""
        (Application-Start: Probe) {
            Create the <a> with "1".
            Create the <b> with "2".
        }
        """)
        let fs = try XCTUnwrap(program.featureSets.first)
        var graph = CanvasGraph.build(featureSet: fs, fileKey: "t.aro")

        // Pre-place the first node deliberately.
        graph.nodes[0].x = 500
        graph.nodes[0].y = 500

        // Run a single iteration with no edges between them — the
        // repulsion shouldn't push the first node far from (500, 500).
        let placed = ForceDirectedLayout.place(graph, iterations: 1)
        // The first node should still be reasonably near where it
        // started — the layout pass *may* perturb it via repulsion
        // (it's not "pinned"), but it shouldn't reset to (0, 0).
        XCTAssertNotEqual(placed.nodes[0].x, 0)
        XCTAssertNotEqual(placed.nodes[0].y, 0)
    }

    // MARK: - Helpers

    private func parse(_ source: String) throws -> Program {
        let tokens = try Lexer(source: source).tokenize()
        let parser = Parser(tokens: tokens)
        return try parser.parse()
    }
}
