// ============================================================
// Issue232Tests.swift
// SOLARO — Bézier wire renderer unit tests (#232)
// ============================================================

import XCTest
@testable import SOLARO
import SwiftCrossUI

final class Issue232Tests: XCTestCase {

    // MARK: - WiresShape

    func testWiresShapeProducesCubicCurvesForEachSegment() {
        let segs: [WireSegment] = [
            WireSegment(id: "a", start: .init(0, 0),   end: .init(100, 50)),
            WireSegment(id: "b", start: .init(0, 100), end: .init(100, 200)),
        ]
        let shape = WiresShape(segments: segs)
        let path = shape.path(in: .init(x: 0, y: 0, width: 200, height: 200))
        // Each segment emits one moveTo + one cubicCurve, plus
        // the underlying Path has its own implicit moveTo bookkeeping
        // for the empty path.
        let moveCount = path.actions.filter { if case .moveTo = $0 { return true } else { return false } }.count
        let cubicCount = path.actions.filter { if case .cubicCurve = $0 { return true } else { return false } }.count
        XCTAssertEqual(moveCount, segs.count)
        XCTAssertEqual(cubicCount, segs.count)
    }

    func testWiresShapeEmptyInputProducesEmptyPath() {
        let shape = WiresShape(segments: [])
        let path = shape.path(in: .init(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(path.actions.count, 0)
    }

    // MARK: - WireColor mapping

    func testWireColorMapsPrepositions() {
        // Sanity check the documented mapping doesn't drift.
        XCTAssertEqual(WireColor.color(for: "from"),    .blue)
        XCTAssertEqual(WireColor.color(for: "to"),      .yellow)
        XCTAssertEqual(WireColor.color(for: "with"),    .purple)
        XCTAssertEqual(WireColor.color(for: "into"),    .green)
        XCTAssertEqual(WireColor.color(for: "against"), .red)
        XCTAssertEqual(WireColor.color(for: nil),       .gray)
        XCTAssertEqual(WireColor.color(for: "unknown"), .gray)
    }

    // MARK: - NodesShape rounded rectangles

    func testNodesShapeBuildsClosedPathPerNode() {
        let nodes: [CanvasNode] = [
            CanvasNode(
                id: "n1", verb: "Create", summary: "Create the <user> with <data>.",
                resultName: "user", objectPreposition: "with", objectName: "data",
                referencedIdentifiers: ["data"], lineHint: 1, x: 100, y: 100
            ),
            CanvasNode(
                id: "n2", verb: "Emit", summary: "Emit a <e: event> with <user>.",
                resultName: "e", objectPreposition: "with", objectName: "_expression_",
                referencedIdentifiers: ["user"], lineHint: 2, x: 300, y: 100
            ),
        ]
        let shape = NodesShape(nodes: nodes, nodeWidth: 180, nodeHeight: 56)
        let path = shape.path(in: .init(x: 0, y: 0, width: 600, height: 200))
        // Each rounded rect emits four cubic curves + four lines +
        // a moveTo. The path has two such subpaths.
        let cubic = path.actions.filter { if case .cubicCurve = $0 { return true } else { return false } }.count
        XCTAssertEqual(cubic, nodes.count * 4, "expected four corner curves per node")
    }
}
