// ============================================================
// CodeEditor.swift
// SOLARO — NSTextView-backed code editor with line numbers (Phase 7)
// ============================================================
//
// SwiftUI's TextEditor is good enough for casual prose entry but
// doesn't support syntax highlighting, a line-number gutter, or
// per-character attributes. We drop down to NSViewRepresentable
// wrapping NSTextView for these.
//
// Behavior:
//   * Monospaced font (the system mono).
//   * Dark backdrop matching the workspace.
//   * Left gutter with line numbers via NSLineNumberRulerView.
//   * Re-tokenize + re-color on every edit.
//   * Cmd-S persists to disk and re-parses the project.

import SwiftUI
import AppKit
import AROParser

struct AROCodeEditor: NSViewRepresentable {
    @Binding var text: String
    let onSave: (String) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let textView = (scroll.documentView as! NSTextView)
        textView.delegate = context.coordinator
        configureTextView(textView)
        addLineNumberRuler(to: scroll, textView: textView)
        textView.string = text
        applyHighlight(textView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        if textView.string != text {
            let cursor = textView.selectedRange()
            textView.string = text
            // Clamp selection to new length.
            let clamped = NSRange(
                location: min(cursor.location, text.utf16.count),
                length: 0
            )
            textView.setSelectedRange(clamped)
            applyHighlight(textView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    // MARK: - Setup helpers

    private func configureTextView(_ textView: NSTextView) {
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true

        let mono = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.font = mono
        textView.textColor = NSColor(SolaroColor.textPrimary)
        textView.backgroundColor = NSColor(SolaroColor.backdrop)
        textView.drawsBackground = true
        textView.insertionPointColor = NSColor(SolaroColor.accent)
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor(SolaroColor.selection)
        ]

        textView.textContainerInset = NSSize(width: 0, height: 8)
        textView.textContainer?.lineFragmentPadding = 8
    }

    private func addLineNumberRuler(to scroll: NSScrollView, textView: NSTextView) {
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        let ruler = LineNumberRulerView(textView: textView)
        scroll.verticalRulerView = ruler
        scroll.backgroundColor = NSColor(SolaroColor.backdrop)
        scroll.drawsBackground = true
    }

    fileprivate func applyHighlight(_ textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let source = textView.string
        storage.beginEditing()
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let full = NSRange(location: 0, length: storage.length)
        storage.addAttribute(.font, value: font, range: full)
        AROSyntaxHighlighter.apply(to: storage, source: source)
        storage.endEditing()
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AROCodeEditor

        init(parent: AROCodeEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            parent.applyHighlight(textView)
        }

        // No custom command interception for now; cmd-S handling
        // hooks the standard responder chain in a follow-up.
    }
}

// MARK: - Line-number ruler

/// Custom NSRulerView drawing line numbers in a left gutter. The
/// font + color match the rest of the editor; the gutter background
/// is one shade darker than the code background so the eye can
/// disambiguate it from the source.
final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        self.clientView = textView
        self.ruleThickness = 44
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("LineNumberRulerView does not support NSCoder")
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard
            let textView = textView,
            let layoutManager = textView.layoutManager,
            let textContainer = textView.textContainer
        else { return }

        // Paint the gutter background.
        NSColor(SolaroColor.surface).setFill()
        rect.fill()

        // Hairline separator between gutter and editor.
        NSColor(SolaroColor.divider).setFill()
        NSRect(x: rect.maxX - 1, y: rect.minY, width: 1, height: rect.height).fill()

        // Compute the visible rect in text coordinates.
        let visibleRect = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(
            forBoundingRect: visibleRect, in: textContainer
        )

        let textString = textView.string as NSString
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(SolaroColor.textTertiary),
        ]

        // Walk glyph ranges line by line. NSLayoutManager has no
        // direct "lines in visible rect" API, so we step through.
        var lineCharIndex = 0
        var lineNumber = 1

        // Fast-skip through lines above the visible glyph range.
        let charRange = layoutManager.characterRange(
            forGlyphRange: glyphRange, actualGlyphRange: nil
        )
        while lineCharIndex < charRange.location {
            let lineRange = textString.lineRange(
                for: NSRange(location: lineCharIndex, length: 0)
            )
            if lineRange.length == 0 { break }
            lineCharIndex = NSMaxRange(lineRange)
            lineNumber += 1
        }

        // Draw line numbers for the visible character range.
        let endCharIndex = NSMaxRange(charRange)
        while lineCharIndex < endCharIndex {
            let lineRange = textString.lineRange(
                for: NSRange(location: lineCharIndex, length: 0)
            )
            let glyphIndex = layoutManager.glyphIndexForCharacter(
                at: lineRange.location
            )
            let lineRect = layoutManager.lineFragmentRect(
                forGlyphAt: glyphIndex, effectiveRange: nil, withoutAdditionalLayout: true
            )
            let y = lineRect.minY + textView.textContainerInset.height
            let label = "\(lineNumber)"
            let attrStr = NSAttributedString(string: label, attributes: attrs)
            let labelWidth = attrStr.size().width
            let drawPoint = NSPoint(
                x: ruleThickness - labelWidth - 6,
                y: y
            )
            attrStr.draw(at: drawPoint)

            if lineRange.length == 0 { break }
            lineCharIndex = NSMaxRange(lineRange)
            lineNumber += 1
        }
    }
}
