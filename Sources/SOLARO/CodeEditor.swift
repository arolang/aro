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

/// Red-dot marker drawn in the gutter for each line that has a
/// breakpoint. Sized to fit the gutter's marker container; SOLARO
/// doesn't customize STGutterView's geometry, so we lean on the
/// default frame.
final class BreakpointMarkerView: NSView {
    override init(frame frameRect: NSRect = .zero) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BreakpointMarkerView does not support NSCoder")
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let inset = min(bounds.width, bounds.height) * 0.18
        let circle = bounds.insetBy(dx: inset, dy: inset)
        // SolaroColor.stateError tone — translates to AppKit via
        // the macOS 14+ SwiftUI bridge.
        NSColor(SolaroColor.stateError).setFill()
        NSBezierPath(ovalIn: circle).fill()
        // Subtle inner highlight so the dot reads as a 3-D bead at
        // the canvas dark backdrop.
        let highlight = circle.insetBy(dx: circle.width * 0.3,
                                       dy: circle.height * 0.3)
        NSColor.white.withAlphaComponent(0.4).setFill()
        NSBezierPath(ovalIn: highlight).fill()
    }
}

struct AROCodeEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var currentLine: Int?
    /// Breakpoint source lines (1-indexed). Toggled by clicking the
    /// gutter; persisted to the file's LayoutSidecar by the parent.
    @Binding var breakpoints: Set<Int>
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
        // Attach the gutter click handler + render initial markers.
        installBreakpointGesture(on: textView, coordinator: context.coordinator)
        renderBreakpoints(on: textView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? STTextView else { return }
        // Push text back into the view only when the external
        // binding diverged — avoids fighting the user's edits.
        if textView.text != text {
            textView.text = text
            applyHighlight(textView)
        }
        if let target = currentLine,
           target != lineForCurrentSelection(in: textView) {
            moveCaret(to: target, in: textView)
        }
        // Re-render breakpoint markers whenever the binding changes
        // (e.g. file switch loaded a new sidecar).
        if context.coordinator.lastRenderedBreakpoints != breakpoints {
            renderBreakpoints(on: textView)
            context.coordinator.lastRenderedBreakpoints = breakpoints
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

    /// Compute the 1-indexed line number of the caret. Returns nil
    /// when the text view has no content yet.
    fileprivate func lineForCurrentSelection(in textView: STTextView) -> Int? {
        let nsText = (textView.text ?? "") as NSString
        guard nsText.length > 0 else { return nil }
        let location = textView.textSelection.location
        let clamped = min(location, nsText.length)
        // Count newlines from the document start up to the caret.
        var line = 1
        for i in 0..<clamped {
            if nsText.character(at: i) == 0x0A { line += 1 }
        }
        return line
    }

    /// Move the caret to the start of `line` (1-indexed), scrolling
    /// it into view. No-op if the line is out of range.
    fileprivate func moveCaret(to line: Int, in textView: STTextView) {
        guard line >= 1 else { return }
        let nsText = (textView.text ?? "") as NSString
        guard nsText.length > 0 else { return }

        var offset = 0
        var current = 1
        let length = nsText.length
        while current < line, offset < length {
            if nsText.character(at: offset) == 0x0A { current += 1 }
            offset += 1
        }
        guard current == line else { return }
        let target = NSRange(location: offset, length: 0)
        textView.textSelection = target
        textView.scrollRangeToVisible(target)
    }

    // MARK: - Breakpoint gutter

    /// Attach a single-click recognizer to the existing gutter view.
    /// STGutterView's own marker drag-drop UX stays intact — clicks
    /// fall through to the recognizer's action first.
    fileprivate func installBreakpointGesture(
        on textView: STTextView,
        coordinator: Coordinator
    ) {
        guard let gutter = textView.gutterView else { return }
        let click = NSClickGestureRecognizer(
            target: coordinator,
            action: #selector(Coordinator.gutterClicked(_:))
        )
        click.numberOfClicksRequired = 1
        click.buttonMask = 0x1
        gutter.addGestureRecognizer(click)
    }

    /// Replace the gutter's marker set with one STGutterMarker per
    /// breakpoint line. The custom view is a small filled circle
    /// in the SOLARO error red.
    fileprivate func renderBreakpoints(on textView: STTextView) {
        guard let gutter = textView.gutterView else { return }
        // Clear all current breakpoint markers — we own them.
        let lines = Set((1...max(breakpoints.max() ?? 0, 1)).map { $0 })
        for line in lines {
            gutter.removeMarker(lineNumber: line)
        }
        // Re-add the current set.
        for line in breakpoints {
            let marker = STGutterMarker(
                lineNumber: line,
                view: BreakpointMarkerView(frame: .zero)
            )
            gutter.addMarker(marker)
        }
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
        /// Tracks the most recently rendered breakpoint set so
        /// updateNSView can detect external changes (file switch,
        /// sidecar reload) without re-rendering on every body
        /// re-evaluation.
        var lastRenderedBreakpoints: Set<Int> = []

        init(parent: AROCodeEditor) {
            self.parent = parent
        }

        // Click on the gutter → toggle a breakpoint at the line
        // under the click.
        @objc func gutterClicked(_ recognizer: NSClickGestureRecognizer) {
            guard
                let textView,
                let gutter = recognizer.view
            else { return }
            let pointInGutter = recognizer.location(in: gutter)
            // Convert to text view coordinates. Map the click's Y
            // into the text content area at a small x offset so
            // the layout manager can find a fragment.
            let pointInTextView = gutter.convert(pointInGutter, to: textView)
            let probe = CGPoint(x: 4, y: pointInTextView.y)
            guard let fragment = textView.textLayoutManager
                .textLayoutFragment(for: probe)
            else { return }
            let elementStart = fragment.textElement?.elementRange?.location
                ?? fragment.rangeInElement.location
            // Count newlines from doc-start to the fragment start.
            let docStart = textView.textContentManager.documentRange.location
            guard
                let prefixRange = NSTextRange(location: docStart, end: elementStart)
            else { return }
            let prefix = textView.textContentManager
                .attributedString(in: prefixRange)?.string ?? ""
            let line = prefix.filter { $0.isNewline }.count + 1

            var updated = parent.breakpoints
            if updated.contains(line) {
                updated.remove(line)
            } else {
                updated.insert(line)
            }
            parent.breakpoints = updated
            parent.renderBreakpoints(on: textView)
            lastRenderedBreakpoints = updated
        }

        nonisolated func textViewDidChangeText(_ notification: Notification) {
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

        nonisolated func textViewDidChangeSelection(_ notification: Notification) {
            let textView = notification.object as? STTextView
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let textView else { return }
                    let line = self.parent.lineForCurrentSelection(in: textView)
                    if line != self.parent.currentLine {
                        self.parent.currentLine = line
                    }
                }
            }
        }
    }
}
