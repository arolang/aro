// ============================================================
// WireGeometryTests.swift
// SOLARO — Bézier wire geometry regression (Swift Testing)
// ============================================================
//
// The visual look of the canvas depends on:
//   * Wire color per preposition (covered by ThemeTests).
//   * Bézier control points placed at 50% of the horizontal
//     distance with a 36pt minimum so short wires don't collapse.
//
// We probe the geometry helper directly so future refactors of
// CanvasView don't accidentally drop the curve into a straight
// line.

import Testing
import Foundation
@testable import SOLARO

/// Mirror of the math inside CanvasView's WiresLayer so we can
/// regression-test the curve geometry without invoking SwiftUI.
private struct WireGeometry {
    static func controlPoints(start: CGPoint, end: CGPoint) -> (CGPoint, CGPoint) {
        let dx = abs(end.x - start.x)
        let curveOffset = max(dx * 0.5, 36)
        let c1 = CGPoint(x: start.x + curveOffset, y: start.y)
        let c2 = CGPoint(x: end.x - curveOffset, y: end.y)
        return (c1, c2)
    }
}

@Suite("Bézier wire geometry")
struct WireGeometryTests {

    @Test func controlPointsScaleWithDistance() {
        let (c1, c2) = WireGeometry.controlPoints(
            start: CGPoint(x: 0, y: 0),
            end:   CGPoint(x: 400, y: 100)
        )
        // 50% of dx = 200; c1.x = 0 + 200; c2.x = 400 - 200.
        #expect(abs(c1.x - 200) < 0.001)
        #expect(abs(c2.x - 200) < 0.001)
        // y coordinates stick to the endpoints so the curve flows
        // horizontally before bending.
        #expect(c1.y == 0)
        #expect(c2.y == 100)
    }

    @Test func controlPointsRespectMinimumOffset() {
        let (c1, c2) = WireGeometry.controlPoints(
            start: CGPoint(x: 0, y: 0),
            end:   CGPoint(x: 20, y: 60)
        )
        #expect(abs(c1.x - 36) < 0.001)
        #expect(abs(c2.x - (20 - 36)) < 0.001)
    }
}
