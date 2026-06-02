// ============================================================
// StackLayoutTests.swift
// SOLARO — default column-stack placement coverage
// ============================================================

import XCTest
@testable import SOLARO

final class StackLayoutTests: XCTestCase {

    private func makeNode(_ id: String, verb: String = "Log",
                          x: Double = 0, y: Double = 0) -> CanvasNode {
        CanvasNode(
            id: id, verb: verb, summary: "Log to console",
            resultName: nil, objectPreposition: "to",
            objectName: "console", referencedIdentifiers: [],
            lineHint: 1, x: x, y: y
        )
    }

    func testNodesStackTopToBottomInSourceOrder() {
        let nodes = [makeNode("a"), makeNode("b"), makeNode("c")]
        let graph = CanvasGraph(nodes: nodes, edges: [])
        let placed = StackLayout.place(graph)

        XCTAssertEqual(placed.nodes[0].y, 40)
        XCTAssertEqual(placed.nodes[1].y, 40 + 78)
        XCTAssertEqual(placed.nodes[2].y, 40 + 156)
        // All in column 0 → same x.
        let xs = placed.nodes.map(\.x)
        XCTAssertEqual(Set(xs).count, 1)
    }

    func testIncomingFromNonImmediatePredecessorOpensNewColumn() {
        // a → b → c, plus d which reads from a (not b).
        let nodes = [makeNode("a"), makeNode("b"), makeNode("c"), makeNode("d")]
        let edges = [
            CanvasEdge(id: "a-b", fromNodeID: "a", toNodeID: "b", preposition: "with"),
            CanvasEdge(id: "b-c", fromNodeID: "b", toNodeID: "c", preposition: "with"),
            CanvasEdge(id: "a-d", fromNodeID: "a", toNodeID: "d", preposition: "with"),
        ]
        let placed = StackLayout.place(CanvasGraph(nodes: nodes, edges: edges))
        let xd = placed.nodes.first { $0.id == "d" }!.x
        let xa = placed.nodes.first { $0.id == "a" }!.x
        XCTAssertGreaterThan(xd, xa, "d should branch into a new column")
    }

    func testSavedPositionsArePreserved() {
        let nodes = [
            makeNode("a", x: 0, y: 0),
            makeNode("b", x: 555, y: 222),   // user-dragged
            makeNode("c", x: 0, y: 0),
        ]
        let placed = StackLayout.place(CanvasGraph(nodes: nodes, edges: []))
        let b = placed.nodes.first { $0.id == "b" }!
        XCTAssertEqual(b.x, 555)
        XCTAssertEqual(b.y, 222)
    }
}
