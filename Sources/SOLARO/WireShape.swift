// ============================================================
// WireShape.swift
// SOLARO — Bézier wire rendering for canvas + project map (#232)
// ============================================================
//
// SwiftCrossUI v0.6.0 ships a working `Path` with `addCubicCurve`,
// `Shape`, and per-backend path rendering. Earlier reading of the
// surface missed it; #232 is implementable here directly without
// a per-backend escape hatch.
//
// Each wire is a cubic Bézier from `start` to `end` with control
// points offset horizontally — produces the gentle S-curve from
// the wireframes (note 8467 figure 1). Multiple wires render
// inside a single `WiresShape` to keep the view graph compact.

import Foundation
import SwiftCrossUI

/// One wire to draw. Coordinates are in the parent Canvas's
/// coordinate space (pixels relative to the canvas's top-left).
struct WireSegment: Equatable, Hashable {
    let id: String
    let start: SIMD2<Double>
    let end: SIMD2<Double>
}

/// Shape that draws every wire in `segments` as a cubic Bézier
/// inside the bounds it's given. The shape is intended to fill
/// the parent view so the segments' absolute coordinates are
/// honored.
struct WiresShape: Shape {
    let segments: [WireSegment]

    func path(in bounds: Path.Rect) -> Path {
        var path = Path()
        for seg in segments {
            // Control points sit one-third of the way along the
            // horizontal axis, producing a smooth S-curve that
            // matches the wireframes' visual style.
            let dx = abs(seg.end.x - seg.start.x)
            let curveOffset = max(dx * 0.5, 30)
            let c1 = SIMD2<Double>(seg.start.x + curveOffset, seg.start.y)
            let c2 = SIMD2<Double>(seg.end.x - curveOffset, seg.end.y)
            path = path
                .move(to: seg.start)
                .addCubicCurve(control1: c1, control2: c2, to: seg.end)
        }
        return path
    }
}

/// Maps a preposition string to one of the wire colors documented
/// in note 8467 figure 5 (the connection-typology card).
enum WireColor {
    static func color(for preposition: String?) -> Color {
        guard let preposition else { return .gray }
        switch preposition {
        case "from":    return .blue
        case "to":      return .yellow      // amber-ish
        case "with":    return .purple
        case "into":    return .green
        case "against": return .red
        case "for":     return .gray
        case "at":      return .gray
        case "by":      return .gray
        case "via":     return .blue
        case "on":      return .gray
        default:        return .gray
        }
    }
}
