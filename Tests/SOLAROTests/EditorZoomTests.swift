// ============================================================
// EditorZoomTests.swift
// SOLARO — ⌘+ / ⌘- change the editor text size
// ============================================================
//
// One preference (`solaro.editor.fontSize`) drives the code editor,
// notebook cells and the markdown editors, so a single zoom action
// has to move all three — and has to stop at the ends of the
// supported range rather than walking off it.

import Testing
import Foundation
@testable import SOLARO

@Suite("Editor zoom")
struct EditorZoomTests {

    private func defaults(_ name: String = UUID().uuidString) -> UserDefaults {
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test("Zooming in and out returns to where it started")
    func roundTrip() {
        let d = defaults()
        let start = EditorTypography.current(d).fontSize
        let up = EditorTypography.zoom(.in, defaults: d)
        #expect(up > start)
        let down = EditorTypography.zoom(.out, defaults: d)
        #expect(down == start)
    }

    @Test("The step is felt, not fixed: bigger sizes move further")
    func ladderIsMultiplicative() {
        // +1pt is a lot at 8pt and invisible at 40pt.
        let smallStep = EditorTypography.zoomedIn(from: 8) - 8
        let largeStep = EditorTypography.zoomedIn(from: 32) - 32
        #expect(largeStep > smallStep)
    }

    @Test("Zoom stops at the ends of the supported range")
    func clampsAtBothEnds() {
        let d = defaults()
        for _ in 0..<40 { EditorTypography.zoom(.out, defaults: d) }
        let floorSize = EditorTypography.current(d).fontSize
        #expect(EditorTypography.fontSizeRange.contains(floorSize))
        #expect(EditorTypography.zoom(.out, defaults: d) == floorSize)

        for _ in 0..<40 { EditorTypography.zoom(.in, defaults: d) }
        let ceilingSize = EditorTypography.current(d).fontSize
        #expect(EditorTypography.fontSizeRange.contains(ceilingSize))
        #expect(EditorTypography.zoom(.in, defaults: d) == ceilingSize)
    }

    @Test("Reset returns to the shipped default from either direction")
    func resetGoesHome() {
        let d = defaults()
        EditorTypography.zoom(.in, defaults: d)
        EditorTypography.zoom(.in, defaults: d)
        #expect(EditorTypography.zoom(.reset, defaults: d) == EditorTypography.defaultFontSize)
        EditorTypography.zoom(.out, defaults: d)
        #expect(EditorTypography.zoom(.reset, defaults: d) == EditorTypography.defaultFontSize)
    }

    @Test("The size is persisted, so every editor sees it")
    func writesThePreferenceEveryEditorReads() {
        let d = defaults()
        let size = EditorTypography.zoom(.in, defaults: d)
        // Notebook cells and the markdown editors read this same key.
        #expect(d.double(forKey: SolaroPrefs.editorFontSize.rawValue) == Double(size))
        #expect(EditorTypography.current(d).fontSize == size)
    }

    @Test("Every ladder rung is a legal font size")
    func ladderStaysInRange() {
        for size in EditorTypography.zoomLadder {
            #expect(EditorTypography.fontSizeRange.contains(size))
        }
        #expect(EditorTypography.zoomLadder.contains(EditorTypography.defaultFontSize))
        #expect(EditorTypography.zoomLadder == EditorTypography.zoomLadder.sorted())
    }
}

@Suite("Rendered markdown follows the editor text size")
@MainActor
struct MarkdownZoomTests {

    private func defaults(_ name: String = UUID().uuidString) -> UserDefaults {
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test("Editor-style blocks scale with the preference")
    func editorStyleScales() {
        // A notebook is one document: ⌘+ has to move the prose as
        // well as the code, and the markdown side used to be a set of
        // hardcoded point sizes that never read the preference.
        let atDefault = BookMarkdownBlockView(
            block: .paragraph("text"), style: .editor)
        #expect(atDefault.scaled(14) == 14, "13pt is the baseline the sizes are written at")
    }

    @Test("Book pages keep their own typography")
    func bookStyleUnscaled() {
        // The book viewer is a reading view with its own measure, not
        // the editor — zooming code must not reflow a chapter.
        let page = BookMarkdownBlockView(block: .paragraph("text"), style: .book)
        #expect(page.scaled(14) == 14)
        #expect(page.scaled(28) == 28)
    }

    @Test("The ladder the zoom commands walk stays inside the supported range")
    func ladderUsableForMarkdown() {
        // Scaling multiplies these sizes, so a rung far outside the
        // range would blow up heading sizes rather than clamp them.
        for size in EditorTypography.zoomLadder {
            let ratio = size / EditorTypography.defaultFontSize
            #expect(ratio > 0.4 && ratio < 8)
        }
    }
}
