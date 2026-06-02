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

/// STTextView subclass that resolves identifier hovers into native
/// AppKit tooltips. We use the AppKit `toolTip` mechanism rather
/// than a SwiftUI popover so the tooltip respects window-edge
/// clipping and the system delay.
final class AROHoverTextView: STTextView {
    /// Resolver callback set by the SwiftUI wrapper: takes an
    /// identifier name (e.g. "greeting") and returns the captured
    /// symbol value when the debugger has one for it, else nil.
    var resolveSymbol: ((String) -> ConsoleProcess.SymbolValue?)?

    /// Callback invoked when the user clicks the gutter on a given
    /// 1-indexed source line. The SwiftUI wrapper toggles the line
    /// in the breakpoints binding.
    var onGutterClick: ((Int) -> Void)?

    private var trackingAreaCache: NSTrackingArea?
    /// Click monitor that fires for every left-mouse-down anywhere
    /// in the app. We use it because STGutterView has its own
    /// mouseDown handler that consumes clicks landing on existing
    /// markers — without the monitor those clicks never reach a
    /// vanilla NSClickGestureRecognizer, so "click an existing
    /// breakpoint to remove it" never fires.
    private var clickMonitor: Any?
    private lazy var hoverPopover: NSPopover = {
        let p = NSPopover()
        p.behavior = .transient
        p.animates = false
        return p
    }()
    private var hoverHost: NSHostingController<HoverValuePopover>?
    private var lastHoverIdentifier: String?
    /// Global mouse-moved monitor. Tracking areas on STTextView
    /// don't always deliver mouseMoved because the text view's own
    /// content view sits on top and consumes the event. The local
    /// monitor sees the event before it gets dispatched, so we can
    /// react regardless of the responder chain.
    private var mouseMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Belt: ask the window to deliver mouseMoved.
        window?.acceptsMouseMovedEvents = true
        // Suspenders: install a local monitor so we hear about
        // moves regardless of subview hit-testing.
        installMouseMonitorIfNeeded()
    }

    @MainActor
    override func removeFromSuperview() {
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
        super.removeFromSuperview()
    }

    private func installMouseMonitorIfNeeded() {
        if mouseMonitor != nil { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            self?.handleMouseMoved(event)
            return event
        }
        if clickMonitor == nil {
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
                self?.handleLeftMouseDown(event)
                return event
            }
        }
    }

    /// Forward gutter clicks to the SwiftUI layer so breakpoints can
    /// toggle. Adds new breakpoints when clicking empty gutter
    /// rows; removes existing ones when clicking the red dot.
    private func handleLeftMouseDown(_ event: NSEvent) {
        guard
            let window, event.window == window,
            let gutter = gutterView
        else { return }
        let pointInGutter = gutter.convert(event.locationInWindow, from: nil)
        guard gutter.bounds.contains(pointInGutter) else { return }

        // Find the source line under the click. The gutter shares
        // its vertical metrics with the text view, so we can use
        // the textLayoutManager to map y → fragment → line.
        let pointInTextView = gutter.convert(pointInGutter, to: self)
        let probe = CGPoint(x: 4, y: pointInTextView.y)
        guard let fragment = textLayoutManager.textLayoutFragment(for: probe)
        else { return }
        let elementStart = fragment.textElement?.elementRange?.location
            ?? fragment.rangeInElement.location
        let docStart = textContentManager.documentRange.location
        guard let prefixRange = NSTextRange(location: docStart, end: elementStart)
        else { return }
        let prefix = textContentManager
            .attributedString(in: prefixRange)?.string ?? ""
        let line = prefix.filter { $0.isNewline }.count + 1
        onGutterClick?(line)
    }

    /// Cursor moved somewhere in this process. Filter by whether
    /// the cursor is currently inside our text view, then resolve
    /// the identifier under it.
    private func handleMouseMoved(_ event: NSEvent) {
        guard let window, event.window == window else {
            hideHoverPopover()
            return
        }
        let windowPoint = event.locationInWindow
        let localPoint = convert(windowPoint, from: nil)
        guard bounds.contains(localPoint) else {
            hideHoverPopover()
            return
        }
        resolveHover(at: localPoint)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaCache {
            removeTrackingArea(trackingAreaCache)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved,
                      .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaCache = area
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hideHoverPopover()
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        resolveHover(at: point)
    }

    /// Shared hover-resolution path used by both the tracking-area
    /// `mouseMoved` and the global event-monitor fallback.
    private func resolveHover(at point: CGPoint) {
        guard let identifier = identifierUnderPoint(point) else {
            hideHoverPopover()
            return
        }
        if identifier == lastHoverIdentifier, hoverPopover.isShown {
            return
        }
        guard let symbol = resolveSymbol?(identifier) else {
            hideHoverPopover()
            return
        }
        lastHoverIdentifier = identifier
        showHoverPopover(for: symbol, near: point)
    }

    /// Mount the SwiftUI popover anchored just under the cursor's
    /// caret rect. NSPopover handles the arrow + edge clipping.
    private func showHoverPopover(for symbol: ConsoleProcess.SymbolValue,
                                  near point: CGPoint) {
        let view = HoverValuePopover(symbol: symbol)
        if let host = hoverHost {
            host.rootView = view
        } else {
            let host = NSHostingController(rootView: view)
            host.sizingOptions = [.intrinsicContentSize]
            hoverHost = host
            hoverPopover.contentViewController = host
        }
        // Anchor on a 1pt rect at the cursor; popover positions itself.
        let anchor = NSRect(x: point.x, y: point.y, width: 1, height: 1)
        if !hoverPopover.isShown {
            hoverPopover.show(relativeTo: anchor, of: self, preferredEdge: .maxY)
        }
    }

    private func hideHoverPopover() {
        lastHoverIdentifier = nil
        if hoverPopover.isShown {
            hoverPopover.performClose(nil)
        }
    }

    /// Find the `<…>` identifier (if any) at `point`. Treats angle
    /// brackets and a colon as terminators so `<name: type>` yields
    /// just `name`.
    private func identifierUnderPoint(_ point: CGPoint) -> String? {
        let source = text ?? ""
        let nsSource = source as NSString
        guard nsSource.length > 0 else { return nil }

        // Map point → line (1-indexed) via layout fragment, then
        // column via character-width approximation. Works cleanly
        // for the monospaced ARO source.
        guard let fragment = textLayoutManager.textLayoutFragment(for: point) else {
            return nil
        }
        let elementStart = fragment.textElement?.elementRange?.location
            ?? fragment.rangeInElement.location
        let docStart = textContentManager.documentRange.location
        guard
            let prefixRange = NSTextRange(location: docStart, end: elementStart)
        else { return nil }
        let prefixText = textContentManager
            .attributedString(in: prefixRange)?.string ?? ""
        // Offset of the line's first character in the source.
        let lineStart = (prefixText as NSString).length

        // Approximate column via mean glyph width — monospaced font,
        // so this is exact for ASCII.
        let glyphWidth = ("M" as NSString)
            .size(withAttributes: [.font: font]).width
        let safeWidth = max(glyphWidth, 1)
        let lineInset = textContainer.lineFragmentPadding
        let column = max(0, Int((point.x - lineInset) / safeWidth))
        let charIndex = min(lineStart + column, nsSource.length - 1)
        return Self.angleBracketIdentifier(at: charIndex, in: nsSource)
    }

    /// Walk backwards from `index` to the nearest `<` and forwards
    /// to the nearest `>` / `:` / whitespace, returning the
    /// identifier name in between. Returns nil if `index` is not
    /// inside an angle-bracket pair on the same line.
    static func angleBracketIdentifier(at index: Int, in nsSource: NSString) -> String? {
        guard index >= 0, index < nsSource.length else { return nil }
        // Find the opening '<'.
        var start = index
        while start > 0 {
            let c = nsSource.character(at: start - 1)
            if c == 0x3C /* '<' */ { break }
            if c == 0x3E /* '>' */ { return nil }
            if c == 0x0A /* '\n' */ { return nil }
            start -= 1
        }
        guard start > 0, nsSource.character(at: start - 1) == 0x3C else {
            return nil
        }
        // Find the terminator forward.
        var end = index
        while end < nsSource.length {
            let c = nsSource.character(at: end)
            if c == 0x3E /* '>' */ || c == 0x3A /* ':' */ || c == 0x0A {
                break
            }
            end += 1
        }
        guard end > start else { return nil }
        let raw = nsSource.substring(with: NSRange(location: start, length: end - start))
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// SwiftUI content of the hover-value popover. Styled to match the
/// inspector's Variables-row pattern: name in accent, type secondary,
/// value primary mono, with a small "captured at pause" caption.
struct HoverValuePopover: View {
    let symbol: ConsoleProcess.SymbolValue

    var body: some View {
        VStack(alignment: .leading, spacing: SolaroSpace.xs) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: "pause.circle.fill")
                    .foregroundStyle(SolaroColor.stateWarn)
                    .font(.system(size: 11))
                Text(symbol.name)
                    .font(SolaroFont.bodyBold)
                    .foregroundStyle(SolaroColor.accent)
                Text(":")
                    .font(SolaroFont.bodyBold)
                    .foregroundStyle(SolaroColor.textTertiary)
                Text(symbol.typeName)
                    .font(SolaroFont.mono)
                    .foregroundStyle(SolaroColor.textSecondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("= ")
                    .font(SolaroFont.mono)
                    .foregroundStyle(SolaroColor.textTertiary)
                Text(symbol.value)
                    .font(SolaroFont.mono)
                    .foregroundStyle(SolaroColor.textPrimary)
                    .textSelection(.enabled)
            }
            Text("captured at the current pause")
                .font(SolaroFont.caption)
                .foregroundStyle(SolaroColor.textTertiary)
        }
        .padding(.horizontal, SolaroSpace.m)
        .padding(.vertical, SolaroSpace.s)
        .frame(maxWidth: 380, alignment: .leading)
    }
}

/// Red-dot marker drawn in the gutter for each line that has a
/// breakpoint. Renders a perfectly round `circle.fill` SF Symbol
/// in a square rect centred vertically and pinned to the right
/// edge of the marker container — that lands the dot directly
/// beside the line number rather than floating in empty space.
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

        // Square draw rect ensures the SF Symbol renders as a true
        // circle (not an oval stretched into a tall marker slot).
        // Sized to ~70% of the smaller dimension so it doesn't crowd
        // the gutter separator.
        let diameter = max(min(bounds.width, bounds.height) * 0.7, 8)
        // Pin to the LEFT edge of the marker container so the dot
        // sits beside the line number (Xcode / VSCode convention)
        // rather than crowding the text margin on the right.
        let leftInset: CGFloat = 2
        let drawRect = NSRect(
            x: leftInset,
            y: bounds.midY - diameter / 2,
            width: diameter,
            height: diameter
        )
        let config = NSImage.SymbolConfiguration(
            pointSize: diameter,
            weight: .bold
        ).applying(.init(paletteColors: [NSColor(SolaroColor.stateError)]))
        guard let symbol = NSImage(
            systemSymbolName: "circle.fill",
            accessibilityDescription: "breakpoint"
        )?.withSymbolConfiguration(config) else { return }
        symbol.draw(in: drawRect)
    }
}

struct AROCodeEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var currentLine: Int?
    /// Breakpoint source lines (1-indexed). Toggled by clicking the
    /// gutter; persisted to the file's LayoutSidecar by the parent.
    @Binding var breakpoints: Set<Int>
    /// 1-indexed source line where the debugger is currently paused.
    /// When non-nil, that line gets a tinted background so the
    /// caller sees "execution is stopped here".
    let pausedLine: Int?
    /// Live debugger symbols keyed by identifier name. The editor
    /// uses this to resolve hover tooltips over `<name>` references.
    let pauseSymbols: [String: ConsoleProcess.SymbolValue]
    let onSave: (String) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        // Build our hover-capable subclass by hand instead of using
        // `STTextView.scrollableTextView()`, which would instantiate
        // the base STTextView class and not pick up the override.
        let textView = AROHoverTextView()
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true

        configureTextView(textView)
        textView.textDelegate = context.coordinator
        textView.resolveSymbol = { [weak coordinator = context.coordinator] name in
            coordinator?.parent.symbolValue(forIdentifier: name)
        }
        textView.onGutterClick = { [weak coordinator = context.coordinator] line in
            coordinator?.parent.toggleBreakpoint(line, in: textView)
        }
        // STTextView's `text` setter resets typing attributes and
        // selection; do it once on initial frame.
        textView.text = text
        applyHighlight(textView)
        // Stash a weak reference for updateNSView to find the
        // text view inside the scroll view on subsequent passes.
        context.coordinator.textView = textView
        // Render initial markers — gutter clicks route through the
        // AROHoverTextView's global click monitor (set above via
        // `onGutterClick`).
        renderBreakpoints(on: textView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? STTextView else { return }
        // Refresh the Coordinator's snapshot of `self`. SwiftUI
        // re-creates AROCodeEditor on every body re-eval, but the
        // Coordinator's stored `parent` is captured once at
        // makeCoordinator(). Without this line, the resolveSymbol
        // closure sees the empty pauseSymbols dictionary captured
        // when the editor first mounted — which is exactly why
        // hover-on-source returned no popover even when the
        // canvas tooltip was rendering the same data.
        context.coordinator.parent = self

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
        // Re-render breakpoint markers whenever the binding changes.
        if context.coordinator.lastRenderedBreakpoints != breakpoints {
            renderBreakpoints(on: textView)
            context.coordinator.lastRenderedBreakpoints = breakpoints
        }
        // Re-apply the paused-line tint whenever it changes.
        if context.coordinator.lastPausedLine != pausedLine {
            applyHighlight(textView)
            paintPausedLine(on: textView)
            context.coordinator.lastPausedLine = pausedLine
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    // MARK: - Setup

    private func configureTextView(_ textView: AROHoverTextView) {
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

    /// Paint a warm tint across the paused line's character range
    /// so the user sees exactly where execution stopped. No-op
    /// when `pausedLine` is nil.
    /// Return the live debugger value for `name` so the editor's
    /// hover popover can render it. nil → no value captured yet,
    /// so the popover stays hidden (the "show only when there's
    /// actually a value" rule).
    fileprivate func symbolValue(
        forIdentifier name: String
    ) -> ConsoleProcess.SymbolValue? {
        pauseSymbols[name]
    }

    fileprivate func paintPausedLine(on textView: STTextView) {
        guard let line = pausedLine, line >= 1 else { return }
        let nsText = (textView.text ?? "") as NSString
        var start = 0
        var current = 1
        let length = nsText.length
        while current < line, start < length {
            if nsText.character(at: start) == 0x0A { current += 1 }
            start += 1
        }
        guard current == line else { return }
        var end = start
        while end < length, nsText.character(at: end) != 0x0A {
            end += 1
        }
        let range = NSRange(location: start, length: end - start)
        guard range.length > 0 else { return }
        textView.addAttributes([
            .backgroundColor: NSColor(SolaroColor.stateWarn).withAlphaComponent(0.18),
        ], range: range)
        // Pull the paused line into the visible area too — the
        // caret-jump already does this, but a pause from inside
        // the debugger may fire before the caret moves.
        textView.scrollRangeToVisible(range)
    }

    // MARK: - Breakpoint gutter

    /// Toggle the breakpoint on `line`: add when missing, remove
    /// when already set. Called from AROHoverTextView's click
    /// monitor so clicks on existing markers go through (a plain
    /// NSClickGestureRecognizer was being swallowed by STGutterView's
    /// own marker mouseDown handling).
    fileprivate func toggleBreakpoint(_ line: Int, in textView: STTextView) {
        var updated = breakpoints
        if updated.contains(line) {
            updated.remove(line)
        } else {
            updated.insert(line)
        }
        breakpoints = updated
        renderBreakpoints(on: textView)
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
        /// Tracks the most recently painted paused line so updateNSView
        /// only re-applies the tint when it actually changes.
        var lastPausedLine: Int?

        init(parent: AROCodeEditor) {
            self.parent = parent
        }

        // Gutter clicks are now handled by AROHoverTextView's
        // global mouseDown monitor — see `onGutterClick` plumbing
        // in makeNSView. We keep the Coordinator's role limited
        // to text + selection tracking.

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
