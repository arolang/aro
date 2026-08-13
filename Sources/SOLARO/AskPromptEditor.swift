// ============================================================
// AskPromptEditor.swift
// SOLARO — growing prompt field for the ARO ASK panel (#489)
// ============================================================
//
// The ask panel's prompt starts one line tall and grows with the
// draft — typed newlines, soft wraps, pasted blocks — until it
// hits a cap derived from the panel height, then scrolls with the
// caret staying in view.
//
// This is an `NSTextView` rather than SwiftUI's
// `TextField(axis: .vertical)` because two of the acceptance
// criteria are out of reach from the SwiftUI side:
//
//   · **Shift+Return inserts a newline.** SwiftUI gives no caret
//     position, so the best a `.onKeyPress` handler could do is
//     append "\n" at the end of the draft — wrong the moment the
//     user goes back to edit a middle line.
//   · **At the cap the field scrolls with the caret in view.**
//     That needs a real scroll view around a real text view.
//
// Height is *derived*, not stored: `sizeThatFits` measures the
// laid-out text every time the draft changes, so growth, shrink,
// and the reset to one line after Send all fall out of the same
// path with no state to keep in sync.

import SwiftUI
import AppKit

/// Sizing rules for the prompt field. Pure arithmetic, so the cap
/// behaviour is testable without a view hierarchy.
enum AskPromptMetrics {

    /// Hard ceiling in lines. A prompt longer than this is being
    /// composed, not glanced at — scrolling is the right call.
    static let maxLines: Int = 15

    /// Fraction of the panel the field may occupy. Above this the
    /// transcript stops being usable, which defeats the point of
    /// seeing the whole draft.
    static let maxPanelFraction: CGFloat = 0.45

    /// Padding above + below the text inside the field.
    static let verticalInset: CGFloat = 5

    /// Height of a field showing exactly `lines` lines.
    static func height(lines: Int, lineHeight: CGFloat) -> CGFloat {
        CGFloat(max(1, lines)) * lineHeight + 2 * verticalInset
    }

    /// One-line height — the floor, and where the field sits after
    /// Send clears the draft.
    static func minHeight(lineHeight: CGFloat) -> CGFloat {
        height(lines: 1, lineHeight: lineHeight)
    }

    /// The cap: the smaller of `maxLines` and `maxPanelFraction` of
    /// the panel, never below one line. `panelHeight <= 0` means
    /// the panel hasn't been laid out yet — fall back to the line
    /// ceiling so the first frame isn't collapsed.
    static func maxHeight(panelHeight: CGFloat,
                          lineHeight: CGFloat) -> CGFloat {
        let byLines = height(lines: maxLines, lineHeight: lineHeight)
        guard panelHeight > 0 else { return byLines }
        let byPanel = panelHeight * maxPanelFraction
        return max(minHeight(lineHeight: lineHeight), min(byLines, byPanel))
    }
}

/// Result of a key the prompt field forwards to its host.
enum AskPromptKeyResult {
    /// The host consumed it; the text view should not.
    case handled
    /// The host passed — let the text view do its normal thing.
    case ignored
}

struct AskPromptEditor: NSViewRepresentable {
    @Binding var text: String
    var isEnabled: Bool = true
    var fontSize: CGFloat = 13
    /// Height ceiling; past it the field scrolls internally.
    var maxHeight: CGFloat
    /// Return with no modifiers.
    var onSubmit: () -> Void = {}
    /// ⌘Return. Kept separate from `onSubmit` because Return picks
    /// the highlighted slash command when the picker is open,
    /// whereas ⌘Return has always meant Send outright.
    var onSend: () -> Void = {}
    /// ↑ / ↓ — the slash-command picker claims them while it is
    /// open, otherwise the caret moves normally.
    var onArrow: (Int) -> AskPromptKeyResult = { _ in .ignored }
    /// Measured height, reported after each layout so the panel can
    /// keep the transcript pinned to the bottom while the field
    /// resizes.
    var onHeightChange: (CGFloat) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> AskPromptScrollView {
        let textView = AskPromptTextView(frame: .zero)
        textView.coordinator = context.coordinator
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.drawsBackground = false
        textView.insertionPointColor = NSColor(SolaroColor.accent)
        textView.textContainerInset = NSSize(
            width: 4, height: AskPromptMetrics.verticalInset)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        // A document view left at `.zero` has no area to hit-test,
        // so clicks fall through to the clip view and the field
        // never becomes first responder — it looks like a text
        // field that refuses to take focus. Give it a real starting
        // frame; `updateNSView` keeps the width in step from there.
        let initial = NSSize(width: 240,
                             height: AskPromptMetrics.minHeight(
                                lineHeight: textView.lineHeight))
        textView.frame = NSRect(origin: .zero, size: initial)
        textView.textContainer?.containerSize = NSSize(
            width: initial.width, height: .greatestFiniteMagnitude)
        apply(text: text, to: textView)

        let scrollView = AskPromptScrollView()
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        // No bounce: at the cap the field is already at its limit,
        // and rubber-banding a 15-line box reads as a glitch.
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: AskPromptScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? AskPromptTextView
        else { return }
        textView.isEditable = isEnabled
        textView.isSelectable = isEnabled
        // Only push when the change came from outside (Send clearing
        // the draft, a slash command filling it in) — echoing the
        // user's own keystroke back would reset the caret.
        if textView.string != text {
            apply(text: text, to: textView)
            textView.scrollRangeToVisible(textView.selectedRange())
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: AskPromptScrollView,
        context: Context
    ) -> CGSize? {
        let width = proposal.width ?? nsView.bounds.width
        guard width > 0,
              let textView = nsView.documentView as? AskPromptTextView
        else { return nil }
        let content = textView.contentHeight(fittingWidth: width)
        let height = min(maxHeight,
                         max(AskPromptMetrics.minHeight(
                                lineHeight: textView.lineHeight),
                             content))
        context.coordinator.report(height: height)
        return CGSize(width: width, height: height)
    }

    private func apply(text: String, to textView: AskPromptTextView) {
        let font = NSFont.systemFont(ofSize: fontSize)
        textView.font = font
        textView.textColor = NSColor(SolaroColor.textPrimary)
        textView.typingAttributes = [
            .font: font,
            .foregroundColor: NSColor(SolaroColor.textPrimary),
        ]
        if textView.string != text { textView.string = text }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AskPromptEditor
        weak var textView: AskPromptTextView?
        private var lastReportedHeight: CGFloat = 0

        init(_ parent: AskPromptEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
            view.scrollRangeToVisible(view.selectedRange())
        }

        /// Height reporting runs inside a layout pass, so bounce it
        /// to the next runloop turn — mutating SwiftUI state during
        /// layout is what "Modifying state during view update"
        /// warnings are made of.
        func report(height: CGFloat) {
            guard abs(height - lastReportedHeight) > 0.5 else { return }
            lastReportedHeight = height
            let notify = parent.onHeightChange
            DispatchQueue.main.async { notify(height) }
        }

        func submit() { parent.onSubmit() }
        func send() { parent.onSend() }
        func arrow(_ delta: Int) -> AskPromptKeyResult { parent.onArrow(delta) }
    }
}

/// Scroll view that keeps its text view sized to the visible area.
///
/// `NSScrollView` does not resize its document view for you. Left
/// alone, the text view keeps whatever frame it was created with,
/// which has two visible consequences: clicks outside that frame
/// land on the clip view and the field silently refuses focus, and
/// the text wraps at the wrong column when the right rail is
/// resized. Doing it in `layout()` — rather than in
/// `updateNSView` — means it runs when the real geometry exists;
/// SwiftUI's first update pass happens before the scroll view has
/// been given a size.
final class AskPromptScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let textView = documentView as? AskPromptTextView else { return }
        let visible = contentSize
        guard visible.width > 0 else { return }
        // Height floor of the clip view, so a one-line draft still
        // has a full-height hit target — clicking the empty space
        // under the text focuses the field like any text box.
        textView.minSize = NSSize(width: 0, height: visible.height)
        let target = NSSize(
            width: visible.width,
            height: max(visible.height,
                        textView.contentHeight(fittingWidth: visible.width)))
        if abs(textView.frame.width - target.width) > 0.5
            || abs(textView.frame.height - target.height) > 0.5 {
            textView.frame = NSRect(origin: .zero, size: target)
        }
        textView.textContainer?.containerSize = NSSize(
            width: max(1, visible.width - 2 * textView.textContainerInset.width),
            height: .greatestFiniteMagnitude)
    }
}

/// Text view that routes Return / ⌘Return / ↑ / ↓ to the host and
/// leaves everything else — including Shift+Return — to AppKit's
/// normal editing behaviour.
final class AskPromptTextView: NSTextView {

    weak var coordinator: AskPromptEditor.Coordinator?

    /// Height of one line in the current font, used for the
    /// one-line floor.
    var lineHeight: CGFloat {
        let font = self.font ?? NSFont.systemFont(ofSize: 13)
        return ceil(layoutManager?.defaultLineHeight(for: font)
                    ?? font.boundingRectForFont.height)
    }

    /// Laid-out height of the whole draft at `width`, insets
    /// included.
    func contentHeight(fittingWidth width: CGFloat) -> CGFloat {
        guard let manager = layoutManager, let container = textContainer
        else { return AskPromptMetrics.minHeight(lineHeight: lineHeight) }
        let inner = max(1, width - 2 * textContainerInset.width)
        container.containerSize = NSSize(width: inner,
                                         height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        let used = ceil(manager.usedRect(for: container).height)
        return used + 2 * textContainerInset.height
    }

    override func keyDown(with event: NSEvent) {
        // 36 = Return, 76 = numpad Enter.
        if event.keyCode == 36 || event.keyCode == 76 {
            let flags = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
            if flags.contains(.shift) {
                // The whole point of #489: a newline the user can
                // actually type, inserted at the caret rather than
                // appended to the end of the draft.
                insertNewlineIgnoringFieldEditor(nil)
                return
            }
            if flags.contains(.command) {
                // Normally SwiftUI's Send button claims ⌘Return via
                // `keyboardShortcut` before the key reaches us. This
                // is the fallback for when focus is in here and it
                // doesn't — the two paths are mutually exclusive, so
                // there's no double-send.
                coordinator?.send()
                return
            }
            if flags.isEmpty {
                coordinator?.submit()
                return
            }
        }
        super.keyDown(with: event)
    }

    override func moveUp(_ sender: Any?) {
        if coordinator?.arrow(-1) == .handled { return }
        super.moveUp(sender)
    }

    override func moveDown(_ sender: Any?) {
        if coordinator?.arrow(1) == .handled { return }
        super.moveDown(sender)
    }
}
