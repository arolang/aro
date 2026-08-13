// ============================================================
// AskPromptMetricsTests.swift
// SOLARO — ask-panel prompt growth cap (#489)
// ============================================================
//
// The prompt field's height is derived from the laid-out text, so
// the part worth pinning down in a test is the *ceiling*: it has
// to track the panel rather than a hard-coded line count, stay
// above one line in a cramped panel, and behave before the panel
// has ever been measured.

import Testing
import Foundation
@testable import SOLARO

@Suite("AskPromptMetrics")
struct AskPromptMetricsTests {

    /// Roughly a 13pt system font line.
    private let line: CGFloat = 16

    @Test("One line is the floor")
    func floorIsOneLine() {
        let min = AskPromptMetrics.minHeight(lineHeight: line)
        #expect(min == line + 2 * AskPromptMetrics.verticalInset)
        #expect(AskPromptMetrics.height(lines: 1, lineHeight: line) == min)
        // A zero/negative line count still yields one line rather
        // than a collapsed field.
        #expect(AskPromptMetrics.height(lines: 0, lineHeight: line) == min)
    }

    @Test("A tall panel is capped by the line ceiling")
    func tallPanelHitsLineCeiling() {
        // 45% of 2000 is 900 — far more than 15 lines need.
        let cap = AskPromptMetrics.maxHeight(panelHeight: 2000,
                                             lineHeight: line)
        #expect(cap == AskPromptMetrics.height(
            lines: AskPromptMetrics.maxLines, lineHeight: line))
    }

    @Test("A short panel is capped by its own height")
    func shortPanelHitsPanelFraction() {
        let cap = AskPromptMetrics.maxHeight(panelHeight: 300,
                                             lineHeight: line)
        #expect(cap == 300 * AskPromptMetrics.maxPanelFraction)
        // …and that is genuinely tighter than the line ceiling,
        // otherwise this test would pass for the wrong reason.
        #expect(cap < AskPromptMetrics.height(
            lines: AskPromptMetrics.maxLines, lineHeight: line))
    }

    @Test("A cramped panel still leaves room for one line")
    func neverBelowOneLine() {
        let cap = AskPromptMetrics.maxHeight(panelHeight: 20,
                                             lineHeight: line)
        #expect(cap == AskPromptMetrics.minHeight(lineHeight: line))
    }

    @Test("An unmeasured panel falls back to the line ceiling",
          arguments: [CGFloat(0), -1])
    func unmeasuredPanelFallsBack(panelHeight: CGFloat) {
        // First frame: the panel's geometry hasn't been reported
        // yet. Collapsing to zero here would flash an invisible
        // field on every open.
        #expect(AskPromptMetrics.maxHeight(panelHeight: panelHeight,
                                           lineHeight: line)
                == AskPromptMetrics.height(
                    lines: AskPromptMetrics.maxLines, lineHeight: line))
    }

    @Test("The cap grows monotonically with the panel")
    func capGrowsWithPanel() {
        var previous: CGFloat = 0
        for panel in stride(from: CGFloat(100), through: 1200, by: 100) {
            let cap = AskPromptMetrics.maxHeight(panelHeight: panel,
                                                 lineHeight: line)
            #expect(cap >= previous)
            previous = cap
        }
    }
}
