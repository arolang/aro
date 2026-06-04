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

    // -------------------------------------------------------------
    // Ghost-text suggestion plumbing (#272).
    // -------------------------------------------------------------
    /// Async LSP-completion fetcher. Now returns the full list of
    /// items instead of just the first — the popover shows them as
    /// a navigable dropdown.
    var requestGhost: ((Int, Int, @escaping ([AROLSPClient.CompletionItem]) -> Void) -> Void)?
    /// Optional AI fallback fired after the popover has been open
    /// for ~1s. Returns one short prediction string or nil. Wired
    /// to `AICompletionFallback.predictNext` by CenterPane.
    var requestAI: ((Int, Int, @escaping (String?) -> Void) -> Void)?
    /// Inserts the accepted suggestion at the caret. Owns the
    /// reparse + caret-after-insertion handling.
    var acceptGhost: ((String) -> Void)?
    /// Toggled by the SwiftUI wrapper from `@AppStorage`.
    var ghostTextEnabled: Bool = false

    private lazy var ghostPopover: NSPopover = {
        let p = NSPopover()
        // `.applicationDefined`: we own the lifecycle. `.transient`
        // dismisses on any parent interaction, which means the
        // moment the user starts typing the popover closes.
        p.behavior = .applicationDefined
        p.animates = false
        return p
    }()
    private var ghostHost: NSHostingController<GhostTextPopover>?
    /// Shared state between AROHoverTextView and the SwiftUI
    /// popover view — populated when LSP returns, mutated on
    /// keyboard navigation, drained by `hideGhost()`.
    let ghostState = GhostState()
    private var ghostDebounce: DispatchWorkItem?
    private var ghostAITimer: DispatchWorkItem?
    /// Set the moment the user picks a suggestion (keyboard or
    /// mouse). The next `scheduleGhost()` clears the flag and
    /// returns early so the popover doesn't snap back open before
    /// the user has typed a fresh character — they explicitly
    /// asked to wait for new input after accepting.
    private var suppressNextSchedule: Bool = false
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

    // MARK: - Ghost text (#272)

    /// Re-arm the debounce. Called from the coordinator's
    /// textViewDidChangeText so each keystroke pushes the trigger
    /// further out — only an actual typing pause fires LSP. The
    /// pause duration is user-configurable via Settings →
    /// "Suggestion delay" (default 0.75s, clamped 0.2–3.0s).
    func scheduleGhost() {
        hideGhost()
        ghostDebounce?.cancel()
        if suppressNextSchedule {
            suppressNextSchedule = false
            return
        }
        guard ghostTextEnabled, requestGhost != nil else { return }
        let raw = UserDefaults.standard.double(
            forKey: SolaroPrefs.editorGhostDelay.rawValue
        )
        let delay = max(0.2, min(raw > 0 ? raw : 0.75, 3.0))
        let work = DispatchWorkItem { [weak self] in self?.fetchGhost() }
        ghostDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func fetchGhost() {
        guard let (line, column) = caretLineColumn() else { return }
        // Don't open the popover on an empty line, on a line that's
        // pure whitespace, or before the user has typed anything
        // meaningful on the line — those positions never produce
        // sensible suggestions and just flash the popover open and
        // closed as the user begins typing.
        guard shouldOfferGhost(line: line, column: column) else { return }
        let typedPrefix = currentLineWordPrefix(line: line, column: column)
        requestGhost?(line, column) { [weak self] items in
            DispatchQueue.main.async {
                guard let self, !items.isEmpty else { return }
                self.showGhost(items, typedPrefix: typedPrefix)
            }
        }
    }

    /// True when the cursor sits somewhere that warrants a
    /// suggestion popover: not on an empty line, not at column 0,
    /// and not in leading whitespace. The user explicitly asked to
    /// never see the popover at the start of a line so they can
    /// indent freely without flicker.
    private func shouldOfferGhost(line: Int, column: Int) -> Bool {
        guard column > 0 else { return false }
        let raw = self.text ?? ""
        let lines = raw.components(separatedBy: "\n")
        guard line < lines.count else { return false }
        let lineText = lines[line]
        let trimmed = lineText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        // Cursor still inside the indent block? Bail — the user
        // hasn't started a real token yet.
        let prefix = String(lineText.prefix(min(column, lineText.count)))
        if prefix.trimmingCharacters(in: .whitespaces).isEmpty {
            return false
        }
        return true
    }

    /// The partial word the user has typed up to the caret on the
    /// current line — used to filter the LSP's response on the
    /// client side so the popover narrows as the user types.
    /// We walk back from the caret over identifier-ish characters
    /// (letters / digits / `-` / `_`) until we hit whitespace or a
    /// delimiter.
    private func currentLineWordPrefix(line: Int, column: Int) -> String {
        let raw = self.text ?? ""
        let lines = raw.components(separatedBy: "\n")
        guard line < lines.count else { return "" }
        let lineText = lines[line]
        let safeColumn = min(max(0, column), lineText.count)
        let upToCursor = String(lineText.prefix(safeColumn))
        // Walk back over identifier chars.
        var word: [Character] = []
        for ch in upToCursor.reversed() {
            if ch.isLetter || ch.isNumber || ch == "-" || ch == "_" {
                word.append(ch)
            } else {
                break
            }
        }
        return String(word.reversed())
    }

    /// (0-based line, 0-based column) of the caret in the current
    /// text buffer, or nil if we can't resolve it.
    private func caretLineColumn() -> (Int, Int)? {
        let location = textSelection.location
        let raw = (text ?? "") as NSString
        guard location <= raw.length else { return nil }
        var line = 0
        var lastNL = -1
        for i in 0..<location where raw.character(at: i) == 0x0A {
            line += 1
            lastNL = i
        }
        let column = location - lastNL - 1
        return (line, column)
    }

    private func showGhost(
        _ items: [AROLSPClient.CompletionItem],
        typedPrefix: String = ""
    ) {
        ghostState.reset()
        ghostState.items = items
        ghostState.typedPrefix = typedPrefix
        ghostState.selectedIndex = 0
        let view = GhostTextPopover(
            state: ghostState,
            onAccept: { [weak self] item in
                self?.acceptGhost?(item.insertText)
                self?.suppressNextSchedule = true
                self?.hideGhost()
            },
            onAcceptAI: { [weak self] suggestion in
                self?.acceptGhost?(suggestion)
                self?.suppressNextSchedule = true
                self?.hideGhost()
            }
        )
        if let host = ghostHost {
            host.rootView = view
        } else {
            let host = NSHostingController(rootView: view)
            host.sizingOptions = [.intrinsicContentSize]
            ghostHost = host
            ghostPopover.contentViewController = host
        }
        let anchor = ghostAnchorRect()
        if !ghostPopover.isShown {
            ghostPopover.show(relativeTo: anchor,
                              of: self, preferredEdge: .maxY)
        }
        scheduleGhostAI()
    }

    /// Arm a 1s timer that fires the AI fallback when the popover
    /// has been open uninterrupted. Cancelled by `hideGhost()` and
    /// rescheduled by `showGhost(_:)` so re-renders within the
    /// window don't double-trigger.
    private func scheduleGhostAI() {
        ghostAITimer?.cancel()
        let aiOn = UserDefaults.standard.bool(
            forKey: SolaroPrefs.editorAIFallback.rawValue
        )
        guard aiOn, requestAI != nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.fireGhostAI() }
        ghostAITimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func fireGhostAI() {
        guard !ghostState.items.isEmpty else { return }
        guard let (line, column) = caretLineColumn() else { return }
        ghostState.aiLoading = true
        requestAI?(line, column) { [weak self] suggestion in
            DispatchQueue.main.async {
                guard let self else { return }
                // Only land the answer if the popover is still open.
                guard !self.ghostState.items.isEmpty else { return }
                self.ghostState.aiLoading = false
                self.ghostState.aiSuggestion = suggestion?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    /// Resolve the rect we anchor the ghost popover to, in self's
    /// bounds coordinate space.
    ///
    /// STTextView is a TextKit-2 reimplementation and the inherited
    /// NSTextInputClient `firstRect(forCharacterRange:actualRange:)`
    /// returns `CGRect.zero` on it — so we compute the caret
    /// position ourselves using the document text + the monospaced
    /// font's metrics. Since the editor is configured with a
    /// monospaced font, a column×char-width computation is exact.
    private func ghostAnchorRect() -> CGRect {
        let nsText = (self.text ?? "") as NSString
        let location = textSelection.location
        guard nsText.length > 0 else { return fallbackAnchor() }
        let clamped = min(location, nsText.length)

        // Walk newlines up to the caret to derive line + column.
        var line = 0
        var lineStart = 0
        for i in 0..<clamped {
            if nsText.character(at: i) == 0x0A {
                line += 1
                lineStart = i + 1
            }
        }
        let column = clamped - lineStart

        // Font metrics. We configured a monospaced font, so the
        // "M" advance is the canonical character width.
        let font = self.font
            ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let charWidth = ("M" as NSString)
            .size(withAttributes: [.font: font]).width
        let baseLineHeight = NSLayoutManager().defaultLineHeight(for: font)
        let lineHeightMultiple = UserDefaults.standard
            .double(forKey: SolaroPrefs.editorLineHeight.rawValue)
        let resolvedMultiple = lineHeightMultiple > 0 ? lineHeightMultiple : 1.25
        let lineHeight = baseLineHeight * CGFloat(resolvedMultiple)

        // STTextView positions text after the gutter and a small
        // top inset. The exact insets aren't publicly surfaced on
        // the base class, so we use 4pt — matches STTextView's
        // built-in default and gets the popover within a couple
        // of pixels of the actual caret in practice.
        let gutterWidth = gutterView?.frame.width ?? 0
        let topInset: CGFloat = 4
        let leftInset: CGFloat = 4

        let x = gutterWidth + leftInset
            + (CGFloat(column) * charWidth)
        let y = topInset + (CGFloat(line) * lineHeight)

        // Anchor a thin rect matching the current line so the
        // popover hangs immediately below it.
        return CGRect(x: x, y: y, width: 1, height: lineHeight)
    }

    /// Fallback used only when the text storage is empty — anchor
    /// at the top-left of the visible area so the popover at least
    /// renders somewhere reasonable.
    private func fallbackAnchor() -> CGRect {
        let visible = self.visibleRect.isEmpty ? self.bounds : self.visibleRect
        return CGRect(x: visible.minX + 8,
                      y: visible.minY + 8,
                      width: 1, height: 16)
    }

    private func hideGhost() {
        ghostState.reset()
        ghostAITimer?.cancel()
        if ghostPopover.isShown {
            ghostPopover.performClose(nil)
        }
    }

    /// Intercept Tab / Esc / arrow keys when the ghost popover is
    /// open. Before the user presses Tab the popover is informational
    /// — keystrokes pass through to the editor and trigger a fresh
    /// LSP fetch. Once they press Tab the popover takes over and
    /// Up/Down/Enter navigate + accept; any other key dismisses and
    /// falls through to normal editing.
    override func keyDown(with event: NSEvent) {
        guard !ghostState.items.isEmpty else {
            super.keyDown(with: event)
            return
        }
        switch (event.keyCode, ghostState.inNavMode) {
        case (48, false):           // Tab → enter navigation
            ghostState.inNavMode = true
            return
        case (53, _):               // Esc → dismiss
            hideGhost()
            return
        case (125, true):           // Down arrow
            let visible = ghostState.visibleItems
            if ghostState.selectedIndex == GhostState.aiRowIndex {
                ghostState.selectedIndex = 0
            } else if ghostState.selectedIndex < visible.count - 1 {
                ghostState.selectedIndex += 1
            }
            return
        case (126, true):           // Up arrow
            if ghostState.selectedIndex > 0 {
                ghostState.selectedIndex -= 1
            } else if ghostState.selectedIndex == 0, ghostState.canSelectAI {
                ghostState.selectedIndex = GhostState.aiRowIndex
            }
            return
        case (36, true), (76, true): // Return / numpad Enter → accept
            let idx = ghostState.selectedIndex
            let visible = ghostState.visibleItems
            if idx == GhostState.aiRowIndex,
               let suggestion = ghostState.aiSuggestion,
               !suggestion.isEmpty
            {
                acceptGhost?(suggestion)
            } else if idx >= 0, idx < visible.count {
                acceptGhost?(visible[idx].insertText)
            }
            suppressNextSchedule = true
            hideGhost()
            return
        default:
            // Any other key: if we were in nav mode the user is
            // bailing out — dismiss and let the keystroke through.
            if ghostState.inNavMode {
                hideGhost()
            }
            super.keyDown(with: event)
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

/// Multi-line read-only label backed by NSTextField so the text
/// is reliably mouse-selectable inside NSPopover contexts where
/// SwiftUI's `.textSelection(.enabled)` doesn't activate.
struct SelectableMonoText: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.isSelectable = true
        field.isEditable = false
        field.isBordered = false
        field.drawsBackground = false
        field.allowsEditingTextAttributes = false
        field.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        field.textColor = NSColor(SolaroColor.textPrimary)
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != text {
            field.stringValue = text
        }
    }
}

/// LSP-driven dropdown shown after a typing pause (#272).
/// Sits in an NSPopover anchored under the caret rect. Lists the
/// completion items returned by the LSP, with arrow-key navigation
/// once the user presses Tab. An optional AI section appears at
/// the top once the popover has been open ~1s and the
/// `solaro.editor.aiFallback` setting is on.
struct GhostTextPopover: View {
    @Bindable var state: GhostState
    let onAccept: (AROLSPClient.CompletionItem) -> Void
    let onAcceptAI: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if state.aiLoading || state.aiSuggestion != nil {
                aiSection
                Divider().background(SolaroColor.divider)
            }
            itemsList
            Divider().background(SolaroColor.divider)
            footer
        }
        // Fixed width so the SwiftUI host reports a non-zero
        // intrinsicContentSize — macOS 26's layout pass asserts on
        // 0×N popovers.
        .frame(width: 380, height: 280)
        .background(SolaroColor.surface)
    }

    // MARK: - AI section

    private var aiSection: some View {
        let selected = state.selectedIndex == GhostState.aiRowIndex
        let usable: String? = {
            guard let s = state.aiSuggestion, !s.isEmpty else { return nil }
            return s
        }()
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: SolaroSpace.xs) {
                Image(systemName: "sparkles")
                    .foregroundStyle(SolaroColor.accent)
                    .font(.system(size: 11))
                if state.aiLoading {
                    ProgressView().controlSize(.mini)
                    Text("aro ask is thinking…")
                        .font(SolaroFont.monoCaption)
                        .foregroundStyle(SolaroColor.textTertiary)
                } else {
                    Text("aro ask  ·  ⏎ accept")
                        .font(SolaroFont.monoCaption)
                        .foregroundStyle(SolaroColor.textTertiary)
                }
                Spacer(minLength: 0)
                if let suggestion = usable {
                    Button {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(suggestion, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11))
                            .foregroundStyle(SolaroColor.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy the AI suggestion")
                }
            }
            if let suggestion = usable {
                SelectableMonoText(text: suggestion)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if state.aiSuggestion != nil, !state.aiLoading {
                Text("(aro ask returned nothing)")
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(SolaroColor.textTertiary)
            }
        }
        .padding(.horizontal, SolaroSpace.s)
        .padding(.vertical, SolaroSpace.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Highlight when the user has navigated to the AI row.
        // Clicking anywhere on the section accepts it, mirroring
        // the LSP-row click-to-accept behaviour.
        .background(selected ? SolaroColor.selection : SolaroColor.backdrop)
        .contentShape(Rectangle())
        .onTapGesture {
            if let suggestion = usable {
                onAcceptAI(suggestion)
            }
        }
    }

    // MARK: - Items list

    private var itemsList: some View {
        let visible = state.visibleItems
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if visible.isEmpty {
                        Text(state.typedPrefix.isEmpty
                             ? "(no suggestions)"
                             : "(nothing matches \"\(state.typedPrefix)\")")
                            .font(SolaroFont.monoCaption)
                            .foregroundStyle(SolaroColor.textTertiary)
                            .padding(SolaroSpace.s)
                    } else {
                        ForEach(Array(visible.enumerated()), id: \.offset) { idx, item in
                            row(idx: idx, item: item)
                                .id(idx)
                        }
                    }
                }
            }
            .onChange(of: state.selectedIndex) { _, new in
                guard new >= 0 else { return }
                withAnimation(.easeOut(duration: 0.08)) {
                    proxy.scrollTo(new, anchor: .center)
                }
            }
        }
    }

    private func row(idx: Int, item: AROLSPClient.CompletionItem) -> some View {
        let selected = idx == state.selectedIndex
        return Button {
            onAccept(item)
        } label: {
            HStack(spacing: SolaroSpace.xs) {
                Image(systemName: kindIcon(item.kind))
                    .foregroundStyle(kindColor(item.kind))
                    .font(.system(size: 11))
                    .frame(width: 14)
                Text(item.label)
                    .font(SolaroFont.mono)
                    .foregroundStyle(SolaroColor.textPrimary)
                    .lineLimit(1)
                if let detail = item.detail, !detail.isEmpty {
                    Text(detail)
                        .font(SolaroFont.monoCaption)
                        .foregroundStyle(SolaroColor.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, SolaroSpace.s)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? SolaroColor.selection : Color.clear)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Footer

    private var footer: some View {
        let visible = state.visibleItems
        let filtered = !state.typedPrefix.isEmpty
            && visible.count != state.items.count
        return HStack(spacing: SolaroSpace.xs) {
            Image(systemName: "wand.and.stars")
                .foregroundStyle(SolaroColor.accent)
                .font(.system(size: 10))
            Text(state.inNavMode
                 ? "↑↓ navigate · ⏎ accept · ⎋ dismiss"
                 : "⇥ to enter · keep typing to refine · ⎋ to dismiss")
                .font(SolaroFont.monoCaption)
                .foregroundStyle(SolaroColor.textTertiary)
            Spacer()
            Text(filtered
                 ? "\(visible.count)/\(state.items.count)"
                 : "\(state.items.count)")
                .font(SolaroFont.monoCaption)
                .foregroundStyle(SolaroColor.textTertiary)
        }
        .padding(.horizontal, SolaroSpace.s)
        .padding(.vertical, 4)
        .background(SolaroColor.backdrop)
    }

    // MARK: - Styling

    private func kindIcon(_ kind: AROLSPClient.CompletionItem.Kind) -> String {
        switch kind {
        case .keyword:       return "key.fill"
        case .variable:      return "diamond.fill"
        case .function, .method: return "function"
        case .property, .field: return "circle.grid.cross.fill"
        case .snippet:       return "scissors"
        case .module:        return "shippingbox"
        case .constant, .value: return "number"
        default:             return "circle.fill"
        }
    }

    private func kindColor(_ kind: AROLSPClient.CompletionItem.Kind) -> Color {
        switch kind {
        case .keyword:       return SolaroColor.accent
        case .variable:      return SolaroColor.roleOwn
        case .function, .method: return SolaroColor.roleRequest
        case .property, .field: return SolaroColor.roleResponse
        case .snippet:       return SolaroColor.stateWarn
        default:             return SolaroColor.textSecondary
        }
    }
}

struct AROCodeEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var currentLine: Int?
    /// 0-indexed caret column (UTF-16 offset from the start of the
    /// current line). LSP wants character offsets, not display
    /// columns, so we keep this in sync with the text view's
    /// selection. nil when there's no caret yet.
    @Binding var currentColumn: Int?
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
    /// What syntax to highlight. ARO files get the Lexer-driven
    /// coloring; YAML/plain files skip ARO tokens (the Lexer would
    /// otherwise stain quotes + numbers with verb tints).
    var language: Language = .aro
    let onSave: (String) -> Void
    /// Fetch LSP completions at (0-based line, 0-based col). Called
    /// by AROHoverTextView after a debounced typing pause. The
    /// callback gets the full item list; the popover renders all of
    /// them.
    var requestGhost: ((Int, Int, @escaping ([AROLSPClient.CompletionItem]) -> Void) -> Void)? = nil
    /// Fetch an AI-predicted next snippet at the caret. Fired by
    /// the popover ~1s after it opens, when the AI-fallback setting
    /// is on. The result lands at the top of the popover above a
    /// divider.
    var requestAI: ((Int, Int, @escaping (String?) -> Void) -> Void)? = nil
    /// Insert the accepted suggestion at the current caret. Owns the
    /// reparse + cursor positioning (places the caret after the
    /// inserted text).
    var acceptGhost: ((String) -> Void)? = nil
    /// Generation counter bumped by callers that want the editor to
    /// reposition the caret to `(currentLine, currentColumn)` even
    /// when the line hasn't changed. Used by the ghost popover's
    /// accept path so the caret lands one past the inserted word
    /// instead of column 0.
    var caretMoveTick: Int = 0

    enum Language { case aro, yaml, plain }

    @AppStorage(SolaroPrefs.editorGhostText.rawValue)
    private var ghostTextEnabled: Bool = false

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
        // Match the text view's backdrop so the area below the last
        // line of source reads as more editor instead of cutting off
        // visually where the text ends.
        scroll.backgroundColor = NSColor(SolaroColor.backdrop)

        configureTextView(textView)
        textView.textDelegate = context.coordinator
        textView.resolveSymbol = { [weak coordinator = context.coordinator] name in
            coordinator?.parent.symbolValue(forIdentifier: name)
        }
        textView.onGutterClick = { [weak coordinator = context.coordinator] line in
            coordinator?.parent.toggleBreakpoint(line, in: textView)
        }
        // #272: ghost text plumbing.
        textView.ghostTextEnabled = ghostTextEnabled
        textView.requestGhost = requestGhost
        textView.requestAI = requestAI
        textView.acceptGhost = acceptGhost
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
        // Install the ghost gutter: extra greyed-out line numbers
        // below the last real line, so the editor reads as one
        // continuous surface down to the status bar instead of
        // ending mid-pane. The gutter view is created lazily by
        // STTextView when `showsLineNumbers` is set, so installation
        // runs on the next runloop hop.
        DispatchQueue.main.async {
            attachGhostGutter(textView: textView)
        }
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

        // #272: keep ghost-text flags in sync when the user
        // toggles the Settings preference at runtime.
        if let hover = textView as? AROHoverTextView {
            hover.ghostTextEnabled = ghostTextEnabled
            hover.requestGhost = requestGhost
            hover.requestAI = requestAI
            hover.acceptGhost = acceptGhost
        }

        // Push text back into the view only when the external
        // binding diverged — avoids fighting the user's edits.
        // The `lastUserText` check is what keeps STTextView's
        // text setter (which resets the caret to 0) from firing
        // on every keystroke now that updateNSView is woken up
        // by the currentColumn binding too.
        if textView.text != text,
           text != context.coordinator.lastUserText {
            textView.text = text
            applyHighlight(textView)
        }
        if let target = currentLine,
           target != lineForCurrentSelection(in: textView),
           target != context.coordinator.lastUserLine {
            moveCaret(to: target, in: textView)
        }
        // Explicit caret-move request (ghost-accept etc.): when the
        // tick changes, jump to (currentLine, currentColumn) verbatim
        // — even on the same line. This is the only path that honors
        // currentColumn; the line-only check above stays put when
        // the line already matches.
        if context.coordinator.lastCaretMoveTick != caretMoveTick {
            context.coordinator.lastCaretMoveTick = caretMoveTick
            let line = currentLine
            let col = currentColumn
            if let line {
                moveCaret(to: line, column: col ?? 0, in: textView)
                // Defer a second move past the run loop — STTextView's
                // text setter restores the previous insertion point
                // location as a side effect, and that restore can run
                // after our move if the text sync hasn't fully drained
                // yet. The async pass guarantees we get the final
                // word on the caret position.
                DispatchQueue.main.async { [weak textView] in
                    guard let textView else { return }
                    let nsText = (textView.text ?? "") as NSString
                    var off = 0
                    var current = 1
                    while current < line, off < nsText.length {
                        if nsText.character(at: off) == 0x0A { current += 1 }
                        off += 1
                    }
                    guard current == line else { return }
                    let target = NSRange(
                        location: min(off + (col ?? 0), nsText.length),
                        length: 0
                    )
                    textView.textSelection = target
                    textView.scrollRangeToVisible(target)
                }
            }
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
        let fontSize = UserDefaults.standard.double(forKey: SolaroPrefs.editorFontSize.rawValue)
        let resolvedFontSize: CGFloat = fontSize > 0 ? fontSize : 13
        let lineHeight = UserDefaults.standard.double(forKey: SolaroPrefs.editorLineHeight.rawValue)
        let resolvedLineHeight: CGFloat = lineHeight > 0 ? lineHeight : 1.25
        let mono = NSFont.monospacedSystemFont(ofSize: resolvedFontSize, weight: .regular)
        let paragraph = NSParagraphStyle.default.mutableCopy() as! NSMutableParagraphStyle
        paragraph.lineHeightMultiple = resolvedLineHeight
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
        positionForCurrentSelection(in: textView)?.line
    }

    /// 1-based line + 0-based column for the caret. The column is
    /// the UTF-16 offset from the start of the line — matches what
    /// LSP wants for positions.
    fileprivate func positionForCurrentSelection(in textView: STTextView) -> (line: Int, column: Int)? {
        let nsText = (textView.text ?? "") as NSString
        guard nsText.length > 0 else { return nil }
        let location = textView.textSelection.location
        let clamped = min(location, nsText.length)
        var line = 1
        var lastNewline = -1
        for i in 0..<clamped {
            if nsText.character(at: i) == 0x0A {
                line += 1
                lastNewline = i
            }
        }
        let column = clamped - lastNewline - 1
        return (line, max(0, column))
    }

    /// Move the caret to `line` (1-indexed) at `column` (0-indexed
    /// UTF-16 offset from the start of the line), scrolling it into
    /// view. No-op if the line is out of range.
    fileprivate func moveCaret(to line: Int, column: Int = 0, in textView: STTextView) {
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
        let target = NSRange(
            location: min(offset + max(0, column), length),
            length: 0
        )
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
    /// breakpoint line. Uses STGutterMarker's default view — the
    /// wide blue pentagonal indicator that matches the gutter's
    /// own selected-line highlight, so breakpoints and selection
    /// share one visual vocabulary.
    fileprivate func renderBreakpoints(on textView: STTextView) {
        guard let gutter = textView.gutterView else { return }
        let lines = Set((1...max(breakpoints.max() ?? 0, 1)).map { $0 })
        for line in lines {
            gutter.removeMarker(lineNumber: line)
        }
        for line in breakpoints {
            gutter.addMarker(STGutterMarker(lineNumber: line))
        }
    }

    fileprivate func applyHighlight(_ textView: STTextView) {
        let source = textView.text ?? ""
        let nsString = source as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)

        textView.setAttributes(
            [
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                .foregroundColor: NSColor(SolaroColor.textPrimary),
            ],
            range: fullRange
        )

        let mutable = NSMutableAttributedString(string: source)
        switch language {
        case .aro:
            AROSyntaxHighlighter.apply(to: mutable, source: source)
        case .yaml:
            YAMLSyntaxHighlighter.apply(to: mutable, source: source)
        case .plain:
            break
        }
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
        /// Snapshot of the text we most recently received from the
        /// user's typing. updateNSView uses this to distinguish a
        /// re-render triggered by user input (skip text sync — the
        /// textView already has the right value) from a re-render
        /// triggered by an external change (do sync — e.g. another
        /// view modified the buffer, or the file reloaded).
        var lastUserText: String?
        /// Same idea for the caret line — tracks what we last
        /// wrote back from the textView's selection, so we don't
        /// jump the caret back to col 0 on every keystroke.
        var lastUserLine: Int?
        /// Last seen value of `AROCodeEditor.caretMoveTick`. When the
        /// parent bumps the tick, updateNSView notices the change and
        /// performs an explicit (line, column) caret move — used by
        /// the ghost-popover accept path.
        var lastCaretMoveTick: Int = 0

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
                    self.lastUserText = newText
                    self.parent.text = newText
                    self.parent.applyHighlight(textView)
                    // #272: any text change dismisses the live ghost
                    // and re-arms the debounce; the next pause fires
                    // a fresh LSP completion.
                    if let hover = textView as? AROHoverTextView {
                        hover.scheduleGhost()
                    }
                }
            }
        }

        nonisolated func textViewDidChangeSelection(_ notification: Notification) {
            let textView = notification.object as? STTextView
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let textView else { return }
                    let position = self.parent.positionForCurrentSelection(in: textView)
                    self.lastUserLine = position?.line
                    if position?.line != self.parent.currentLine {
                        self.parent.currentLine = position?.line
                    }
                    if position?.column != self.parent.currentColumn {
                        self.parent.currentColumn = position?.column
                    }
                }
            }
        }
    }
}

// MARK: - Ghost gutter

/// Attaches `AROGhostGutterView` behind the real line-number cells
/// of the text view's gutter, then keeps it refreshed on text edits
/// and on scroll.
@MainActor
private func attachGhostGutter(textView: STTextView) {
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
private final class AROGhostGutterView: NSView {
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
private func layoutGhostGutter(
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
