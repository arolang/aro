// ============================================================
// GraphViewportTests.swift
// SOLARO — pan and zoom, written once (GitLab #775)
// ============================================================
//
// Three graph views each carried their own pan, zoom, dragOffset and
// magnify, their own two gestures and their own clamp — byte-for-byte
// the same code in three files, so a fix to any of it survived in the
// other two.

import Testing
import Foundation
@testable import SOLARO

@Suite("Graph viewport")
struct GraphViewportTests {

    @Test func startsUnpannedAndUnzoomed() {
        let viewport = GraphViewport()
        #expect(viewport.pan == .zero)
        #expect(viewport.zoom == 1)
    }

    @Test func panningAccumulates() {
        var viewport = GraphViewport()
        viewport.pan(by: CGSize(width: 10, height: -5))
        viewport.pan(by: CGSize(width: 4, height: 1))
        // A drag adds to where the view already was, rather than
        // replacing it — otherwise every drag would start from origin.
        #expect(viewport.pan == CGSize(width: 14, height: -4))
    }

    @Test func magnificationMultiplies() {
        var viewport = GraphViewport()
        viewport.magnify(by: 2)
        #expect(viewport.zoom == 2)
        viewport.magnify(by: 0.5)
        #expect(viewport.zoom == 1)
    }

    @Test func zoomIsClampedAtBothEnds() {
        // Far enough out to see a large application, far enough in to
        // read a statement. The same range all three views had.
        var viewport = GraphViewport()
        viewport.magnify(by: 100)
        #expect(viewport.zoom == GraphViewport.zoomLimits.upperBound)
        viewport.magnify(by: 0.0001)
        #expect(viewport.zoom == GraphViewport.zoomLimits.lowerBound)
    }

    @Test func steppingTheZoomRespectsTheSameClamp() {
        // The toolbar's plus and minus went through their own
        // arithmetic in each view; now there is one.
        var viewport = GraphViewport()
        for _ in 0..<50 { viewport.zoom(by: 1.1) }
        #expect(viewport.zoom <= GraphViewport.zoomLimits.upperBound)
        for _ in 0..<100 { viewport.zoom(by: 0.9) }
        #expect(viewport.zoom >= GraphViewport.zoomLimits.lowerBound)
    }

    @Test func resettingRestoresBoth() {
        var viewport = GraphViewport()
        viewport.pan(by: CGSize(width: 200, height: 90))
        viewport.magnify(by: 2.5)
        viewport.reset()
        #expect(viewport == GraphViewport())
    }

    @Test func theZoomRangeIncludesTheDefault() {
        // A viewport that starts outside its own limits would snap on
        // the first gesture.
        #expect(GraphViewport.zoomLimits.contains(GraphViewport().zoom))
    }
}
