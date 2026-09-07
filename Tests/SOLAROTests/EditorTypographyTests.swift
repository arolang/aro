// ============================================================
// EditorTypographyTests.swift
// SOLARO — editor type-preference resolution (GitLab #533)
// ============================================================

import Testing
import AppKit
@testable import SOLARO

@Suite("Editor typography")
struct EditorTypographyTests {

    @Test func unsetPreferencesFallBackToShippedDefaults() {
        // UserDefaults returns 0 for a key that was never written.
        let type = EditorTypography.resolve(fontSize: 0, lineHeight: 0)
        #expect(type.fontSize == EditorTypography.defaultFontSize)
        #expect(type.lineHeightMultiple == EditorTypography.defaultLineHeight)
    }

    @Test func honorsAConfiguredFontSize() {
        let type = EditorTypography.resolve(fontSize: 18, lineHeight: 1.5)
        #expect(type.fontSize == 18)
        #expect(type.lineHeightMultiple == 1.5)
    }

    @Test func clampsOutOfRangeValues() {
        let huge = EditorTypography.resolve(fontSize: 4000, lineHeight: 40)
        #expect(huge.fontSize == EditorTypography.fontSizeRange.upperBound)
        #expect(huge.lineHeightMultiple == EditorTypography.lineHeightRange.upperBound)

        let tiny = EditorTypography.resolve(fontSize: 1, lineHeight: 0.1)
        #expect(tiny.fontSize == EditorTypography.fontSizeRange.lowerBound)
        #expect(tiny.lineHeightMultiple == EditorTypography.lineHeightRange.lowerBound)
    }

    /// The regression itself: the attributes the highlighter stamps
    /// over the whole document must carry the configured size, not a
    /// hardcoded 13pt.
    @Test func baseAttributesCarryTheConfiguredFontSize() {
        let type = EditorTypography.resolve(fontSize: 20, lineHeight: 1.25)
        let attributes = type.baseAttributes(foreground: .labelColor)
        let font = attributes[.font] as? NSFont
        #expect(font?.pointSize == 20)
        #expect(attributes[.foregroundColor] as? NSColor == .labelColor)
    }

    @Test func baseAttributesUseAMonospacedFace() {
        let font = EditorTypography.resolve(fontSize: 15, lineHeight: 1.25).font
        #expect(font.isFixedPitch)
    }

    @Test func paragraphStyleAppliesTheLineHeightMultiple() {
        let style = EditorTypography.resolve(fontSize: 13, lineHeight: 1.8)
            .paragraphStyle
        #expect(style.lineHeightMultiple == 1.8)
    }

    /// The ghost popover anchors against line height; it has to grow
    /// with the font or the suggestion list drifts off the caret.
    @Test func lineHeightGrowsWithTheFontSize() {
        let small = EditorTypography.resolve(fontSize: 10, lineHeight: 1.25)
        let large = EditorTypography.resolve(fontSize: 22, lineHeight: 1.25)
        #expect(large.lineHeight > small.lineHeight)
    }

    @Test func readsBothPreferenceKeys() {
        let defaults = UserDefaults(suiteName: "solaro.tests.typography")!
        defaults.removePersistentDomain(forName: "solaro.tests.typography")
        defaults.set(17.0, forKey: SolaroPrefs.editorFontSize.rawValue)
        defaults.set(1.6, forKey: SolaroPrefs.editorLineHeight.rawValue)
        let type = EditorTypography.current(defaults)
        #expect(type.fontSize == 17)
        #expect(type.lineHeightMultiple == 1.6)
        defaults.removePersistentDomain(forName: "solaro.tests.typography")
    }
}
