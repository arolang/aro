// ============================================================
// MarkdownBlockSourceEditor.swift
// SOLARO — the one raw-source block in the markdown editor (#488)
// ============================================================
//
// Exactly one of these exists at a time: the block the caret is
// in. Everything else on the page is a rendered SwiftUI view. That
// is the whole reason this is a plain `NSTextView` and not another
// STTextView — it is a small, content-sized, single-block field,
// not a document editor, and it has to be cheap to create and tear
// down on every caret move between blocks.
//
// Its job beyond plain text editing is to notice when the caret is
// about to leave, and say so instead of swallowing the keystroke:
//
//   ↑ / ← at the top edge   → `exitUp`
//   ↓ / → at the bottom edge → `exitDown`
//   ⌫ at offset 0            → `mergeBackward`
//   ⌦ at the end             → `mergeForward`
//   ⇥ / ⎋ / focus loss       → `deactivate`
//
// "Top edge" means the first *display* line, not the first source
// line: a soft-wrapped paragraph must let ↓ walk its wrapped rows
// before it hands the caret to the next block.

import SwiftUI
import AppKit

/// Callbacks the block editor raises. Grouped into one struct so
/// the representable's signature stays legible.
struct MarkdownBlockEditorActions {
    /// The block's raw source changed. Fires per keystroke.
    var onEdit: (String) -> Void = { _ in }
    /// Caret left through the top edge, carrying the column it was
    /// in so the previous block can re-enter at the same place.
    var onExitUp: (MarkdownCaretEntry) -> Void = { _ in }
    /// Caret left through the bottom edge.
    var onExitDown: (MarkdownCaretEntry) -> Void = { _ in }
    /// ⌫ pressed with the caret at offset 0.
    var onMergeBackward: () -> Void = {}
    /// ⌦ pressed with the caret at the end.
    var onMergeForward: () -> Void = {}
    /// ⎋, or the pane lost focus — re-render this block.
    var onDeactivate: () -> Void = {}
    /// The undo manager the Edit menu should drive. Document-wide,
    /// so ⌘Z crosses block boundaries.
    var undoManager: UndoManager? = nil
}

struct MarkdownBlockSourceEditor: NSViewRepresentable {
    /// Raw markdown for this block, straight out of the buffer.
    let source: String
    /// Fence language, when the block is a fenced code block.
    var language: String? = nil
    var fontSize: CGFloat = 13
    /// Where to put the caret when the view first appears.
    var entry: MarkdownCaretEntry = .end
    var actions: MarkdownBlockEditorActions = .init()

    func makeCoordinator() -> Coordinator { Coordinator(actions: actions) }

    func makeNSView(context: Context) -> MarkdownBlockTextView {
        let view = MarkdownBlockTextView(frame: .zero)
        view.actions = actions
        view.delegate = context.coordinator
        view.isRichText = false
        view.allowsUndo = false           // document-level undo owns ⌘Z
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isGrammarCheckingEnabled = false
        view.drawsBackground = true
        view.backgroundColor = NSColor(SolaroColor.surfaceRaised)
            .withAlphaComponent(0.35)
        view.insertionPointColor = NSColor(SolaroColor.accent)
        view.textContainerInset = NSSize(width: 6, height: 6)
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.lineFragmentPadding = 0
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                              height: CGFloat.greatestFiniteMagnitude)
        view.autoresizingMask = [.width]
        applyText(source, to: view)
        context.coordinator.lastPushedSource = source

        // Focus + caret placement have to wait for the view to be
        // in a window; SwiftUI hasn't installed it yet inside
        // makeNSView.
        let target = entry.resolve(in: source)
        DispatchQueue.main.async { [weak view] in
            guard let view else { return }
            view.window?.makeFirstResponder(view)
            let utf16 = source.utf16Offset(forCharacterOffset: target)
            view.setSelectedRange(NSRange(location: utf16, length: 0))
            view.scrollRangeToVisible(view.selectedRange())
        }
        return view
    }

    func updateNSView(_ view: MarkdownBlockTextView, context: Context) {
        view.actions = actions
        context.coordinator.actions = actions
        // Only push text back into the view when it did not come
        // from the view itself — otherwise every keystroke would
        // reset the string and stomp the caret.
        if context.coordinator.lastPushedSource != source,
           view.string != source {
            let caret = view.selectedRange()
            applyText(source, to: view)
            let clamped = min(caret.location, (source as NSString).length)
            view.setSelectedRange(NSRange(location: clamped, length: 0))
        }
        context.coordinator.lastPushedSource = source
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: MarkdownBlockTextView,
        context: Context
    ) -> CGSize? {
        let width = proposal.width ?? nsView.bounds.width
        guard width > 0 else { return nil }
        return CGSize(width: width, height: nsView.height(fittingWidth: width))
    }

    /// Set the block's text and paint it. ARO fences get the same
    /// lexer-driven colouring the code pane uses; everything else
    /// stays plain so the raw markers (`#`, `-`, `**`) read clearly
    /// against the rendered blocks around them.
    private func applyText(_ text: String, to view: MarkdownBlockTextView) {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize,
                                               weight: .regular)
        let attributed = NSMutableAttributedString(string: text)
        let full = NSRange(location: 0, length: attributed.length)
        attributed.addAttribute(.font, value: font, range: full)
        attributed.addAttribute(.foregroundColor,
                                value: NSColor(SolaroColor.textPrimary),
                                range: full)
        if let language, language.lowercased() == "aro" {
            AROSyntaxHighlighter.apply(to: attributed, source: text)
            attributed.addAttribute(.font, value: font, range: full)
        }
        view.textStorage?.setAttributedString(attributed)
        view.font = font
        view.typingAttributes = [
            .font: font,
            .foregroundColor: NSColor(SolaroColor.textPrimary),
        ]
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var actions: MarkdownBlockEditorActions
        /// Last value SwiftUI pushed down, so `updateNSView` can
        /// tell an external change from an echo of our own edit.
        var lastPushedSource: String = ""

        init(actions: MarkdownBlockEditorActions) {
            self.actions = actions
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            lastPushedSource = view.string
            actions.onEdit(view.string)
        }
    }
}

/// NSTextView that reports caret escapes instead of eating them.
final class MarkdownBlockTextView: NSTextView {

    var actions = MarkdownBlockEditorActions()

    /// Hand the Edit menu the *document's* undo manager. The
    /// workspace's ⌘Z command walks the responder chain for an
    /// `NSText` and uses its manager (see `SolaroUndoCommand`);
    /// returning the per-view default would scope undo to a single
    /// block and lose every step the moment the caret moved.
    override var undoManager: UndoManager? {
        actions.undoManager ?? super.undoManager
    }

    // MARK: - Content height

    /// Laid-out height for a given width, including the text
    /// container inset. Drives the SwiftUI row height.
    func height(fittingWidth width: CGFloat) -> CGFloat {
        guard let manager = layoutManager, let container = textContainer
        else { return fontLineHeight + 2 * textContainerInset.height }
        let inner = max(1, width - 2 * textContainerInset.width)
        container.containerSize = NSSize(width: inner,
                                         height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container).height
        return max(fontLineHeight, ceil(used)) + 2 * textContainerInset.height
    }

    private var fontLineHeight: CGFloat {
        let font = self.font ?? NSFont.monospacedSystemFont(
            ofSize: 13, weight: .regular)
        return ceil(layoutManager?.defaultLineHeight(for: font)
                    ?? font.boundingRectForFont.height)
    }

    // MARK: - Caret geometry

    /// Display-line facts about the caret: is it on the first /
    /// last laid-out row, and how many characters into that row.
    /// Display rows, not source lines — a wrapped paragraph has to
    /// let ↓ walk its wrapped rows first.
    private func caretRow() -> (isFirst: Bool, isLast: Bool, column: Int) {
        guard let manager = layoutManager, let container = textContainer,
              manager.numberOfGlyphs > 0
        else { return (true, true, 0) }
        let location = selectedRange().location
        let glyph = min(manager.glyphIndexForCharacter(at: location),
                        manager.numberOfGlyphs - 1)
        var effective = NSRange()
        let fragment = manager.lineFragmentRect(
            forGlyphAt: glyph, effectiveRange: &effective,
            withoutAdditionalLayout: false)
        let used = manager.usedRect(for: container)
        let column = max(0, location - effective.location)
        return (fragment.minY <= used.minY + 0.5,
                fragment.maxY >= used.maxY - 0.5,
                column)
    }

    private var caretAtStart: Bool {
        let range = selectedRange()
        return range.location == 0 && range.length == 0
    }

    private var caretAtEnd: Bool {
        let range = selectedRange()
        return range.length == 0
            && range.location >= (string as NSString).length
    }

    // MARK: - Boundary-crossing overrides

    override func moveUp(_ sender: Any?) {
        let row = caretRow()
        if row.isFirst {
            actions.onExitUp(.lastLine(column: row.column))
            return
        }
        super.moveUp(sender)
    }

    override func moveDown(_ sender: Any?) {
        let row = caretRow()
        if row.isLast {
            actions.onExitDown(.firstLine(column: row.column))
            return
        }
        super.moveDown(sender)
    }

    override func moveLeft(_ sender: Any?) {
        if caretAtStart {
            actions.onExitUp(.end)
            return
        }
        super.moveLeft(sender)
    }

    override func moveRight(_ sender: Any?) {
        if caretAtEnd {
            actions.onExitDown(.offset(0))
            return
        }
        super.moveRight(sender)
    }

    override func deleteBackward(_ sender: Any?) {
        if caretAtStart {
            actions.onMergeBackward()
            return
        }
        super.deleteBackward(sender)
    }

    override func deleteForward(_ sender: Any?) {
        if caretAtEnd {
            actions.onMergeForward()
            return
        }
        super.deleteForward(sender)
    }

    override func insertTab(_ sender: Any?) {
        actions.onExitDown(.offset(0))
    }

    override func insertBacktab(_ sender: Any?) {
        actions.onExitUp(.end)
    }

    override func cancelOperation(_ sender: Any?) {
        actions.onDeactivate()
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            // Deferred: AppKit is mid-responder-swap, and the new
            // block's text view may not have claimed focus yet.
            // Re-rendering this block synchronously would tear the
            // incoming view out from under that swap.
            let deactivate = actions.onDeactivate
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window?.firstResponder !== self else { return }
                deactivate()
            }
        }
        return resigned
    }
}

extension String {
    /// UTF-16 offset matching a `Character` offset. The model
    /// counts characters (a `String` is a grapheme sequence);
    /// AppKit's selection ranges count UTF-16 units. Anything with
    /// an emoji or a combining mark drifts if you conflate them.
    func utf16Offset(forCharacterOffset offset: Int) -> Int {
        let clamped = max(0, min(offset, count))
        let target = index(startIndex, offsetBy: clamped)
        return utf16.distance(from: utf16.startIndex,
                              to: target.samePosition(in: utf16)
                                ?? utf16.startIndex)
    }

    /// Inverse of `utf16Offset(forCharacterOffset:)`.
    func characterOffset(forUTF16Offset offset: Int) -> Int {
        let clamped = max(0, min(offset, utf16.count))
        guard let target = utf16.index(
            utf16.startIndex, offsetBy: clamped, limitedBy: utf16.endIndex
        ).flatMap({ String.Index($0, within: self) }) else { return count }
        return distance(from: startIndex, to: target)
    }
}
