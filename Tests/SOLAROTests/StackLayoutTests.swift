// ============================================================
// StackLayoutTests.swift
// SOLARO — column-stack placement (Swift Testing)
// ============================================================

import Testing
import Foundation
@testable import SOLARO

@Suite("StackLayout")
struct StackLayoutTests {

    private func makeNode(_ id: String, verb: String = "Log",
                          featureSetName: String = "Test",
                          x: Double = 0, y: Double = 0) -> CanvasNode {
        CanvasNode(
            id: id, verb: verb, summary: "Log to console",
            resultName: nil, objectPreposition: "to",
            objectName: "console", referencedIdentifiers: [],
            lineHint: 1, featureSetName: featureSetName, x: x, y: y
        )
    }

    @Test func nodesStackTopToBottomInSourceOrder() {
        let nodes = [makeNode("a"), makeNode("b"), makeNode("c")]
        let graph = CanvasGraph(nodes: nodes, edges: [])
        let placed = StackLayout.place(graph)

        // topPadding is 56 (room for the feature-set header)
        // and rowPitch is 78.
        #expect(placed.nodes[0].y == 56)
        #expect(placed.nodes[1].y == 56 + 78)
        #expect(placed.nodes[2].y == 56 + 156)
        // All in column 0 → same x.
        let xs = placed.nodes.map(\.x)
        #expect(Set(xs).count == 1)
    }

    @Test func multipleFeatureSetsGetTheirOwnHorizontalSlots() {
        let nodes = [
            makeNode("a", featureSetName: "Alpha"),
            makeNode("b", featureSetName: "Alpha"),
            makeNode("c", featureSetName: "Beta"),
            makeNode("d", featureSetName: "Beta"),
        ]
        let placed = StackLayout.place(CanvasGraph(nodes: nodes, edges: []))
        let xA = placed.nodes.first { $0.id == "a" }!.x
        let xC = placed.nodes.first { $0.id == "c" }!.x
        // Each feature set sits at a different X — Beta is to the
        // right of Alpha by at least one column pitch.
        #expect(xC > xA + 250)
    }

    @Test func incomingFromNonImmediatePredecessorOpensNewColumn() {
        let nodes = [makeNode("a"), makeNode("b"), makeNode("c"), makeNode("d")]
        let edges = [
            CanvasEdge(id: "a-b", fromNodeID: "a", toNodeID: "b", preposition: "with"),
            CanvasEdge(id: "b-c", fromNodeID: "b", toNodeID: "c", preposition: "with"),
            CanvasEdge(id: "a-d", fromNodeID: "a", toNodeID: "d", preposition: "with"),
        ]
        let placed = StackLayout.place(CanvasGraph(nodes: nodes, edges: edges))
        let xd = placed.nodes.first { $0.id == "d" }!.x
        let xa = placed.nodes.first { $0.id == "a" }!.x
        #expect(xd > xa)
    }

    @Test func savedPositionsArePreserved() {
        let nodes = [
            makeNode("a", x: 0, y: 0),
            makeNode("b", x: 555, y: 222),    // user-dragged
            makeNode("c", x: 0, y: 0),
        ]
        let placed = StackLayout.place(CanvasGraph(nodes: nodes, edges: []))
        let b = placed.nodes.first { $0.id == "b" }!
        #expect(b.x == 555)
        #expect(b.y == 222)
    }
}
