// ============================================================
// CodeEditorOverlays.swift
// SOLARO — ghost-text gutter + test PASS/FAIL marker view
// ============================================================
//
// Extracted from CodeEditor.swift (#285 step 2). Two NSView
// subclasses that decorate the editor without belonging to the
// AROCodeEditor lifecycle itself:
//
// * AROGhostGutterView — fades the ghost completion text into
//   the gutter so accepted suggestions don't dance the cursor.
// * TestResultMarkerView — small green/red SF Symbol painted in
//   the gutter for every line that belongs to a test FS with a
//   known outcome.

import SwiftUI
import AppKit
import STTextView

// MARK: - Ghost gutter

/// Attaches `AROGhostGutterView` behind the real line-number cells
/// of the text view's gutter, then keeps it refreshed on text edits
/// and on scroll.
@MainActor
func attachGhostGutter(textView: STTextView) {
    guard let scroll = textView.enclosingScrollView else {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            attachGhostGutter(textView: textView)
        }
        return
    }
    guard let gutter = textView.gutterView else {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            attachGhostGutter(textView: textView)
        }
        return
    }
    // Skip if already attached.
    if scroll.subviews.contains(where: { $0 is AROGhostGutterView }) { return }
    let ghost = AROGhostGutterView(frame: .zero)
    ghost.wantsLayer = true
    ghost.gutterView = gutter
    ghost.textView = textView
    // Floating subview of the scroll view so it doesn't scroll
    // horizontally with content. We position it in the strip
    // BELOW the real gutter so we never paint over real line
    // numbers — only the empty area underneath them.
    scroll.addFloatingSubview(ghost, for: .horizontal)
    layoutGhostGutter(ghost: ghost, gutter: gutter, scroll: scroll)

    // Redraw + reposition on scroll: cells inside the gutter move
    // as the user scrolls, which changes our anchor.
    scroll.contentView.postsBoundsChangedNotifications = true
    NotificationCenter.default.addObserver(
        forName: NSView.boundsDidChangeNotification,
        object: scroll.contentView,
        queue: .main
    ) { [weak ghost, weak gutter, weak scroll] _ in
        MainActor.assumeIsolated {
            guard let ghost, let gutter, let scroll else { return }
            layoutGhostGutter(ghost: ghost, gutter: gutter, scroll: scroll)
            ghost.needsDisplay = true
        }
    }
    // Reposition on frame change too (window resize, etc).
    scroll.postsFrameChangedNotifications = true
    NotificationCenter.default.addObserver(
        forName: NSView.frameDidChangeNotification,
        object: scroll,
        queue: .main
    ) { [weak ghost, weak gutter, weak scroll] _ in
        MainActor.assumeIsolated {
            guard let ghost, let gutter, let scroll else { return }
            layoutGhostGutter(ghost: ghost, gutter: gutter, scroll: scroll)
            ghost.needsDisplay = true
        }
    }
    // Redraw on text changes — line count changes shift where the
    // ghost lines start.
    NotificationCenter.default.addObserver(
        forName: STTextView.textDidChangeNotification,
        object: textView,
        queue: .main
    ) { [weak ghost] _ in
        MainActor.assumeIsolated { ghost?.needsDisplay = true }
    }
}

/// Inert overlay that paints dimmed continuation line numbers below
/// the last real source line. Lines up with the real gutter cells by
/// copying their font, insets, and line height — so callers don't
/// have to keep this in sync with editor preferences.
final class AROGhostGutterView: NSView {
    weak var gutterView: STGutterView?
    weak var textView: STTextView?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var wantsDefaultClipping: Bool { true }

    // Inert: never intercept clicks. Real gutter cells (in the
    // sibling container view) keep their breakpoint-toggle hit
    // testing intact.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        // The first draw runs before STTextView has laid out its
        // gutter cells (we need a cell to read the row height).
        // Re-trigger drawing each layout pass.
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let gutter = gutterView, let textView else { return }
        // Match the text view's background so the rail reads as one
        // continuous strip rather than a slot of a different shade.
        if let bg = textView.backgroundColor {
            bg.setFill()
            bounds.fill()
        }
        guard let lineHeight = realCellHeight(in: gutter) else { return }
        let lineCount = sourceLineCount(textView.text ?? "")
        let attrs: [NSAttributedString.Key: Any] = [
            .font: gutter.font,
            .foregroundColor: gutter.textColor.withAlphaComponent(0.5),
        ]
        let trailingInset = gutter.insets.trailing
        let width = bounds.width
        let maxY = bounds.height
        var n = lineCount + 1
        var y: CGFloat = 0
        while y < maxY {
            let s = NSAttributedString(string: "\(n)", attributes: attrs)
            let size = s.size()
            let x = width - size.width - trailingInset
            s.draw(at: CGPoint(x: x, y: y + (lineHeight - size.height) / 2))
            n += 1
            y += lineHeight
        }
    }

    /// Pulled from any one real cell so the ghost spacing matches
    /// exactly. Returns nil while the gutter hasn't laid cells out
    /// yet (we redraw via observers once it has).
    private func realCellHeight(in gutter: STGutterView) -> CGFloat? {
        for sub in gutter.subviews {
            for cand in sub.subviews
                where String(describing: type(of: cand)).contains("LineNumberCell")
                && cand.frame.height > 0
            {
                return cand.frame.height
            }
        }
        return nil
    }

    private func sourceLineCount(_ s: String) -> Int {
        var n = 1
        for c in s where c == "\n" { n += 1 }
        // A trailing newline shouldn't count as starting a new line
        // (matches how STTextView numbers the gutter).
        if s.hasSuffix("\n") { n -= 1 }
        return max(1, n)
    }
}

/// Sizes/positions the ghost gutter so it sits in the strip
/// immediately below the real gutter's content area, matching the
/// gutter's x-extent and filling down to the bottom of the visible
/// scroll viewport.
@MainActor
func layoutGhostGutter(
    ghost: AROGhostGutterView,
    gutter: STGutterView,
    scroll: NSScrollView
) {
    let gutterMaxY = gutter.frame.maxY
    let viewportH = scroll.contentView.bounds.height
    let belowH = max(0, viewportH - gutterMaxY)
    ghost.frame = NSRect(
        x: gutter.frame.minX,
        y: gutterMaxY,
        width: gutter.frame.width,
        height: belowH
    )
}

/// Gutter marker view backing the PASS / FAIL chip the editor
/// stamps on every line that belongs to a test feature set.
/// Draws an SF Symbol tinted with the corresponding `SolaroColor`.
/// Replaces STGutterMarker's default blue pentagon — that's the
/// breakpoint indicator and would be visually confusing here.
final class TestResultMarkerView: NSView {
    private let result: TestNodeResult

    init(result: TestNodeResult) {
        self.result = result
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let symbolName: String
        let tint: NSColor
        let tooltip: String
        switch result {
        case .passed:
            symbolName = "checkmark.circle.fill"
            tint = NSColor(SolaroColor.stateOK)
            tooltip = "Last run: passed"
        case .failed(let message):
            symbolName = "xmark.circle.fill"
            tint = NSColor(SolaroColor.stateError)
            tooltip = "Last run: \(message)"
        }
        toolTip = tooltip
        // Palette colour so the symbol renders in our tint
        // straight out of NSImage. `image.draw(...)` doesn't pick
        // up `NSColor.set()` for non-template images, which left
        // the first version drawing in dark gray.
        let config = NSImage.SymbolConfiguration(
            pointSize: 12, weight: .semibold
        ).applying(.init(paletteColors: [tint]))
        guard let image = NSImage(systemSymbolName: symbolName,
                                   accessibilityDescription: tooltip)?
            .withSymbolConfiguration(config)
        else { return }
        let imageSize = image.size
        let origin = CGPoint(
            x: (bounds.width - imageSize.width) / 2,
            y: (bounds.height - imageSize.height) / 2
        )
        image.draw(in: NSRect(origin: origin, size: imageSize),
                   from: .zero,
                   operation: .sourceOver,
                   fraction: 1.0,
                   respectFlipped: true,
                   hints: [.interpolation: NSImageInterpolation.high])
    }
}
