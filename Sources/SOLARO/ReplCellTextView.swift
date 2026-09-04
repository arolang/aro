// ============================================================
// ReplCellTextView.swift
// SOLARO — auto-growing text editor for one notebook cell
// ============================================================
//
// A deliberately small NSTextView wrapper: one cell is a short
// buffer, so none of AROCodeEditor's machinery (gutter,
// breakpoints, minimap, LSP, ghost text) applies. What a cell
// does need: grow with its content instead of scrolling
// internally, highlight ARO syntax live, and turn the notebook
// key chords (⇧⏎ / ⌥⏎ / ⌘⏎ / Esc) into callbacks instead of
// newlines.
//
// Sizing uses `sizeThatFits` — the representable measures the
// laid-out text at the proposed width, so the SwiftUI cell card
// wraps the editor exactly and the outer ScrollView owns all
// scrolling.

import SwiftUI
import AppKit

struct ReplCellTextView: NSViewRepresentable {
    @Binding var text: String
    var language: Language = .aro
    var fontSize: CGFloat = 13
    /// The notebook wants this cell's editor to take the keyboard.
    var wantsFocus: Bool = false

    var onFocus: () -> Void = {}
    /// ⇧⏎ — run cell, select below.
    var onRunAndAdvance: () -> Void = {}
    /// ⌥⏎ — run cell, insert below.
    var onRunAndInsert: () -> Void = {}
    /// ⌘⏎ — run cell in place.
    var onRunInPlace: () -> Void = {}
    /// Esc — leave editing (render markdown / drop focus).
    var onEscape: () -> Void = {}

    enum Language {
        case aro
        case markdown
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> CellTextView {
        let view = CellTextView()
        view.delegate = context.coordinator
        view.coordinatorRef = context.coordinator

        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.smartInsertDeleteEnabled = false
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 4, height: 8)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude)

        context.coordinator.applyStyling(to: view, representable: self)
        view.string = text
        context.coordinator.highlight(view)
        return view
    }

    func updateNSView(_ view: CellTextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.applyStyling(to: view, representable: self)
        if view.string != text {
            // External change (undo elsewhere, disk reload). Replace
            // wholesale and re-highlight; the caret clamps itself.
            let selection = view.selectedRange()
            view.string = text
            let length = (view.string as NSString).length
            view.setSelectedRange(NSRange(
                location: min(selection.location, length), length: 0))
            context.coordinator.highlight(view)
        }
        if wantsFocus, view.window != nil, view.window?.firstResponder !== view {
            DispatchQueue.main.async {
                view.window?.makeFirstResponder(view)
            }
        }
    }

    @available(macOS 13.0, *)
    func sizeThatFits(_ proposal: ProposedViewSize,
                      nsView: CellTextView,
                      context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0,
              let container = nsView.textContainer,
              let layout = nsView.layoutManager else { return nil }
        let insets = nsView.textContainerInset
        container.containerSize = NSSize(
            width: width - insets.width * 2,
            height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        // One-line minimum so an empty cell still shows a caret row.
        let minHeight = (nsView.font?.boundingRectForFont.height ?? 16)
        return CGSize(width: width,
                      height: max(used.height, minHeight) + insets.height * 2)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ReplCellTextView

        init(_ parent: ReplCellTextView) {
            self.parent = parent
        }

        func applyStyling(to view: NSTextView, representable: ReplCellTextView) {
            let font = NSFont.monospacedSystemFont(
                ofSize: representable.fontSize, weight: .regular)
            if view.font != font { view.font = font }
            view.insertionPointColor = NSColor(SolaroColor.accent)
        }

        func highlight(_ view: NSTextView) {
            guard parent.language == .aro,
                  let storage = view.textStorage else { return }
            let full = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.addAttribute(
                .font,
                value: NSFont.monospacedSystemFont(
                    ofSize: parent.fontSize, weight: .regular),
                range: full)
            AROSyntaxHighlighter.apply(to: storage, source: view.string)
            storage.endEditing()
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
            highlight(view)
            view.invalidateIntrinsicContentSize()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            // Selection movement inside the editor implies focus.
        }
    }

    // MARK: - NSTextView subclass

    /// Turns notebook chords into coordinator callbacks; everything
    /// else falls through to normal editing.
    final class CellTextView: NSTextView {
        weak var coordinatorRef: Coordinator?

        override func becomeFirstResponder() -> Bool {
            let became = super.becomeFirstResponder()
            if became { coordinatorRef?.parent.onFocus() }
            return became
        }

        override func keyDown(with event: NSEvent) {
            let isReturn = event.keyCode == 36 || event.keyCode == 76
            let flags = event.modifierFlags.intersection(
                .deviceIndependentFlagsMask)
            if isReturn {
                if flags.contains(.shift) {
                    coordinatorRef?.parent.onRunAndAdvance()
                    return
                }
                if flags.contains(.option) {
                    coordinatorRef?.parent.onRunAndInsert()
                    return
                }
                if flags.contains(.command) {
                    coordinatorRef?.parent.onRunInPlace()
                    return
                }
            }
            if event.keyCode == 53 { // Esc
                coordinatorRef?.parent.onEscape()
                return
            }
            super.keyDown(with: event)
        }

        /// Cancel (⌘. or the field editor's cancel path) also exits.
        override func cancelOperation(_ sender: Any?) {
            coordinatorRef?.parent.onEscape()
        }
    }
}
