// ============================================================
// EditorTypography.swift
// SOLARO — one resolution of the editor's type preferences
// ============================================================
//
// The code editor used to resolve `solaro.editor.fontSize` in
// exactly one place (`configureTextView`, at mount time) and then
// hardcode 13pt in `applyHighlight`, which re-stamps the whole
// document on every highlight pass. The first keystroke therefore
// threw the user's font-size preference away (GitLab #533).
//
// Everything that builds editor attributes now goes through this
// type, so there is a single answer to "how big is the editor
// font" and it is testable without a text view.

import AppKit

/// Resolved editor typography: the monospaced font size and the
/// line-height multiple, derived from the Settings preferences.
///
/// A preference that was never written reads back from
/// `UserDefaults` as `0`, which is the "fall back to the default"
/// signal — hence the `> 0` checks rather than a plain read.
struct EditorTypography: Equatable {
    /// Shipped defaults, matching `SettingsView`'s `@AppStorage`
    /// initial values.
    static let defaultFontSize: CGFloat = 13
    static let defaultLineHeight: CGFloat = 1.25

    /// Bounds of the Settings sliders. Values outside them can only
    /// come from a hand-edited defaults domain; clamping keeps a
    /// stray `solaro.editor.fontSize = 4000` from wedging layout.
    static let fontSizeRange: ClosedRange<CGFloat> = 6...96
    static let lineHeightRange: ClosedRange<CGFloat> = 1.0...3.0

    let fontSize: CGFloat
    let lineHeightMultiple: CGFloat

    /// Resolve from the raw `UserDefaults` doubles. Non-positive
    /// (i.e. unset) values take the default; anything else is
    /// clamped into the supported range.
    static func resolve(fontSize: Double, lineHeight: Double) -> EditorTypography {
        let size = fontSize > 0
            ? min(max(CGFloat(fontSize), fontSizeRange.lowerBound),
                  fontSizeRange.upperBound)
            : defaultFontSize
        let height = lineHeight > 0
            ? min(max(CGFloat(lineHeight), lineHeightRange.lowerBound),
                  lineHeightRange.upperBound)
            : defaultLineHeight
        return EditorTypography(fontSize: size, lineHeightMultiple: height)
    }

    /// Font sizes the zoom commands step through. A multiplicative
    /// ladder rather than +1: at 9pt a point is a lot, at 40pt it is
    /// invisible, and every editor that reads this pref — code,
    /// notebook cells, markdown — should move by the same *felt*
    /// amount.
    static let zoomLadder: [CGFloat] = [
        7, 8, 9, 10, 11, 12, 13, 14, 16, 18, 20, 24, 28, 32, 40, 48, 64, 96
    ]

    /// Next size up from `size`, or `size` when already at the top.
    static func zoomedIn(from size: CGFloat) -> CGFloat {
        zoomLadder.first { $0 > size + 0.01 } ?? size
    }

    /// Next size down from `size`, or `size` when already at the bottom.
    static func zoomedOut(from size: CGFloat) -> CGFloat {
        zoomLadder.last { $0 < size - 0.01 } ?? size
    }

    /// Move the editor font size one rung and persist it. Every
    /// editor resolves this pref per render pass, so the change is
    /// live in the open document — code, notebook and markdown alike.
    @discardableResult
    static func zoom(_ direction: ZoomDirection,
                     defaults: UserDefaults = .standard) -> CGFloat {
        let current = self.current(defaults).fontSize
        let next: CGFloat
        switch direction {
        case .in:    next = zoomedIn(from: current)
        case .out:   next = zoomedOut(from: current)
        case .reset: next = defaultFontSize
        }
        defaults.set(Double(next), forKey: SolaroPrefs.editorFontSize.rawValue)
        return next
    }

    enum ZoomDirection { case `in`, out, reset }

    /// The live preference values. Read fresh on every call — the
    /// editor re-resolves per pass so a Settings change applies to
    /// the open document without a relaunch.
    static func current(_ defaults: UserDefaults = .standard) -> EditorTypography {
        resolve(
            fontSize: defaults.double(forKey: SolaroPrefs.editorFontSize.rawValue),
            lineHeight: defaults.double(forKey: SolaroPrefs.editorLineHeight.rawValue)
        )
    }

    var font: NSFont {
        NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    var paragraphStyle: NSParagraphStyle {
        // `NSParagraphStyle.default.mutableCopy()` is documented to
        // return an `NSMutableParagraphStyle`; the cast can't fail.
        let paragraph = NSParagraphStyle.default.mutableCopy()
            as! NSMutableParagraphStyle
        paragraph.lineHeightMultiple = lineHeightMultiple
        return paragraph
    }

    /// Base attributes stamped over the whole document before the
    /// syntax highlighter re-colors individual ranges.
    func baseAttributes(foreground: NSColor) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: foreground]
    }

    /// Rendered height of one line — the ghost popover's caret math
    /// needs it, and it must agree with what the text view draws.
    var lineHeight: CGFloat {
        NSLayoutManager().defaultLineHeight(for: font) * lineHeightMultiple
    }
}
