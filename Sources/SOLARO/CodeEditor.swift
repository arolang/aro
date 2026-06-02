// ============================================================
// CodeEditor.swift
// SOLARO — STTextView-backed code editor (Phase 13)
// ============================================================
//
// SwiftUI wrapper around STTextView (TextKit 2). We get:
//   * Monospaced font with proper kerning.
//   * Built-in line-number gutter via showsLineNumbers + STGutterView.
//   * Per-line marker support (used by the breakpoint gutter in
//     Phase 15).
//   * `textViewDidChangeText` delegate callback for change → reparse.
//
// Syntax highlighting reuses AROSyntaxHighlighter via STTextView's
// `setAttributes(_:range:)` / `addAttributes(_:range:)` API.

import SwiftUI
import AppKit
import STTextView
import AROParser

struct AROCodeEditor: NSViewRepresentable {
    @Binding var text: String
    let onSave: (String) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = STTextView.scrollableTextView()
        guard let textView = scroll.documentView as? STTextView else {
            return scroll
        }

        configureTextView(textView)
        textView.textDelegate = context.coordinator
        // STTextView's `text` setter resets typing attributes and
        // selection; do it once on initial frame.
        textView.text = text
        applyHighlight(textView)
        // Stash a weak reference for updateNSView to find the
        // text view inside the scroll view on subsequent passes.
        context.coordinator.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? STTextView else { return }
        // Only push text back into the view when the external
        // binding diverged — avoids fighting the user's edits.
        if textView.text != text {
            textView.text = text
            applyHighlight(textView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    // MARK: - Setup

    private func configureTextView(_ textView: STTextView) {
        let mono = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let paragraph = NSParagraphStyle.default.mutableCopy() as! NSMutableParagraphStyle
        paragraph.lineHeightMultiple = 1.25
        textView.defaultParagraphStyle = paragraph
        textView.font = mono
        textView.textColor = NSColor(SolaroColor.textPrimary)
        textView.backgroundColor = NSColor(SolaroColor.backdrop)
        textView.insertionPointColor = NSColor(SolaroColor.accent)
        textView.highlightSelectedLine = true
        textView.selectedLineHighlightColor =
            NSColor(SolaroColor.surfaceRaised).withAlphaComponent(0.35)
        textView.showsLineNumbers = true
        // STGutterView's colors are package-internal; it derives
        // background/foreground from the host text view's colors.
        textView.gutterView?.drawSeparator = true
        textView.gutterView?.areMarkersEnabled = true
        textView.isHorizontallyResizable = false        // soft-wrap
        textView.isIncrementalSearchingEnabled = true
    }

    fileprivate func applyHighlight(_ textView: STTextView) {
        let source = textView.text ?? ""
        let nsString = source as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)

        // Reset to the base foreground / font, then overlay token
        // colors. The whole pass is wrapped in a single edit cycle
        // by STTextView under the hood via setAttributes.
        textView.setAttributes(
            [
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                .foregroundColor: NSColor(SolaroColor.textPrimary),
            ],
            range: fullRange
        )

        // Reuse the existing Lexer-driven highlighter by funnelling
        // its output into STTextView's addAttributes(_:range:).
        let mutable = NSMutableAttributedString(string: source)
        AROSyntaxHighlighter.apply(to: mutable, source: source)
        mutable.enumerateAttribute(
            .foregroundColor, in: fullRange, options: []
        ) { value, range, _ in
            if let color = value as? NSColor {
                textView.addAttributes([.foregroundColor: color], range: range)
            }
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, STTextViewDelegate {
        var parent: AROCodeEditor
        weak var textView: STTextView?

        init(parent: AROCodeEditor) {
            self.parent = parent
        }

        nonisolated func textViewDidChangeText(_ notification: Notification) {
            // The delegate callback fires on the main thread already
            // (AppKit guarantee); extract the text on this thread,
            // then bounce the Sendable text+view back into the main
            // actor for the SwiftUI binding + re-highlight.
            let textView = notification.object as? STTextView
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let textView else { return }
                    let newText = textView.text ?? ""
                    self.parent.text = newText
                    self.parent.applyHighlight(textView)
                }
            }
        }
    }
}
