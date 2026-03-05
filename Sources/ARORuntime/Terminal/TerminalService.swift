import Foundation

/// Thread-safe terminal service for capability detection and rendering
/// Use as singleton via ExecutionContext.service(TerminalService.self)
public actor TerminalService: Sendable {
    // MARK: - Properties

    /// Cached terminal capabilities (lazy detection)
    private var capabilities: Capabilities?

    /// Shadow buffer for optimized rendering (ARO-0053)
    private var shadowBuffer: ShadowBuffer?

    /// Whether shadow buffer is enabled (default: true for TTY)
    private var useShadowBuffer: Bool = true

    // MARK: - Section Compositor State

    /// A named region of the screen owned by one Render call
    private struct ScreenSection {
        let name: String       // variable name from `Render the <name>`
        var startRow: Int      // 0-indexed row where this section begins
        var lines: [String]    // last rendered lines (may include ANSI codes)
        var variablePositions: [String: TerminalVarPosition]  // positions for reactive Repaint
    }

    /// Ordered list of sections as rendered top-to-bottom
    private var sections: [ScreenSection] = []

    /// Next available row for a newly appended section
    private var nextRow: Int = 0

    // MARK: - Initialization

    public init() {}

    // MARK: - Capability Detection

    /// Detect and cache terminal capabilities
    /// - Returns: Terminal capabilities (rows, columns, color support, etc.)
    public func detectCapabilities() -> Capabilities {
        if let cached = capabilities {
            return cached
        }

        let detected = CapabilityDetector.detect()
        capabilities = detected
        return detected
    }

    /// Get current terminal dimensions
    /// - Returns: (rows, columns)
    public func getDimensions() -> (rows: Int, columns: Int) {
        let caps = detectCapabilities()
        return (caps.rows, caps.columns)
    }

    /// Check if terminal supports color
    public func supportsColor() -> Bool {
        return detectCapabilities().supportsColor
    }

    /// Check if terminal supports true color (24-bit RGB)
    public func supportsTrueColor() -> Bool {
        return detectCapabilities().supportsTrueColor
    }

    // MARK: - Rendering

    /// Render text to terminal (stdout)
    /// - Parameter text: Text to output (can include ANSI codes)
    public func render(text: String) {
        print(text, terminator: "")
        flushOutput()
    }

    /// Render text with newline
    /// - Parameter text: Text to output
    public func renderLine(_ text: String) {
        print(text)
        flushOutput()
    }

    /// Flush stdout to ensure immediate output
    private func flushOutput() {
        // fflush(nil) flushes all open output streams; avoids referencing the C global 'stdout'
        #if canImport(Darwin)
        Darwin.fflush(nil)
        #elseif canImport(Glibc)
        Glibc.fflush(nil)
        #endif
    }

    // MARK: - Screen Control

    /// Clear the entire screen and reset the section compositor
    public func clear() {
        render(text: ANSIRenderer.clearScreen())
        render(text: ANSIRenderer.moveCursor(row: 1, column: 1))
        sections = []
        nextRow = 0
        flushOutput()
    }

    /// Clear the current line
    public func clearLine() {
        render(text: ANSIRenderer.clearLine())
    }

    /// Section-based compositor render.
    ///
    /// - First call for a given name: appends the section below all previous sections.
    /// - Subsequent calls for the same name: diffs only its own rows (same height)
    ///   or reflows sections below (different height). Other sections are untouched.
    ///
    /// This lets static sections (splash, welcome) coexist with reactive sections (menu)
    /// on the same screen. When a section grows or shrinks, everything below shifts
    /// accordingly — no full-screen clears ever.
    ///
    /// - Parameter variablePositions: Template variable positions for reactive Repaint updates.
    public func renderSection(name: String, content: String, variablePositions: [String: TerminalVarPosition] = [:]) {
        let newLines = content.components(separatedBy: "\n")
        let caps = detectCapabilities()

        if !caps.isTTY {
            // Non-TTY fallback: plain print (tests, pipes)
            print(content)
            flushOutput()
            return
        }

        if let idx = sections.firstIndex(where: { $0.name == name }) {
            let oldLines = sections[idx].lines
            let sectionStartRow = sections[idx].startRow
            let heightDelta = newLines.count - oldLines.count

            if heightDelta == 0 {
                // Same height: efficient line-level diff within this section only
                var anyChanged = false
                for i in 0..<newLines.count {
                    if newLines[i] != oldLines[i] {
                        render(text: ANSIRenderer.moveCursor(row: sectionStartRow + i + 1, column: 1))
                        render(text: ANSIRenderer.clearToEndOfLine())
                        render(text: newLines[i])
                        anyChanged = true
                    }
                }
                if anyChanged {
                    sections[idx].lines = newLines
                    flushOutput()
                }
            } else {
                // Height changed: clear the affected rows, re-render this section,
                // then shift and re-render all sections below.
                sections[idx].lines = newLines

                // Clear from the section start to the end of the old content
                let clearEnd = sectionStartRow + max(oldLines.count, newLines.count)
                for row in sectionStartRow..<clearEnd {
                    render(text: ANSIRenderer.moveCursor(row: row + 1, column: 1))
                    render(text: ANSIRenderer.clearLine())
                }

                // Re-render this section at its (unchanged) start row
                for (i, line) in newLines.enumerated() {
                    render(text: ANSIRenderer.moveCursor(row: sectionStartRow + i + 1, column: 1))
                    render(text: line)
                }

                // Shift and re-render all sections that come after this one
                for i in (idx + 1)..<sections.count {
                    sections[i].startRow += heightDelta
                    for (j, line) in sections[i].lines.enumerated() {
                        render(text: ANSIRenderer.moveCursor(row: sections[i].startRow + j + 1, column: 1))
                        render(text: ANSIRenderer.clearLine())
                        render(text: line)
                    }
                }

                nextRow = sections.last.map { $0.startRow + $0.lines.count } ?? 0
                flushOutput()
            }
            // Update positions if provided (e.g. after a full re-render with new tracking info)
            if !variablePositions.isEmpty {
                sections[idx].variablePositions = variablePositions
            }
        } else {
            // New section: append at nextRow, below all previous sections
            render(text: ANSIRenderer.moveCursor(row: nextRow + 1, column: 1))
            render(text: content)
            sections.append(ScreenSection(
                name: name,
                startRow: nextRow,
                lines: newLines,
                variablePositions: variablePositions
            ))
            nextRow += newLines.count
            // Ensure cursor moves to the next line after the section
            if !content.hasSuffix("\n") {
                render(text: "\n")
            }
            flushOutput()
        }
    }

    /// Reactively update a single named variable within a section without re-rendering the template.
    ///
    /// Moves the cursor to the tracked position and writes the new value, padding with spaces
    /// to overwrite any longer previous value. Flushes immediately so the change appears at once.
    ///
    /// - Parameters:
    ///   - name: Variable key matching the one stored in variablePositions (e.g., "cpu", "cpu-bar")
    ///   - value: New string value to write (may contain ANSI color codes)
    ///   - sectionName: Name of the section that owns this variable
    public func updateVariable(name: String, value: String, inSection sectionName: String) {
        guard let idx = sections.firstIndex(where: { $0.name == sectionName }) else { return }
        guard sections[idx].variablePositions[name] != nil else { return }

        let caps = detectCapabilities()
        guard caps.isTTY else { return }

        let pos = sections[idx].variablePositions[name]!
        let absoluteRow = sections[idx].startRow + pos.row + 1  // 1-indexed for ANSI
        let absoluteCol = pos.col + 1                           // 1-indexed for ANSI

        // Strip ANSI codes to compute visible width of new value
        let visibleNew = stripANSIVisible(value)
        let clearCount = max(0, pos.visibleWidth - visibleNew)

        render(text: ANSIRenderer.moveCursor(row: absoluteRow, column: absoluteCol))
        render(text: value)
        if clearCount > 0 {
            render(text: String(repeating: " ", count: clearCount))
        }
        flushOutput()

        // Update stored width so future overwrites are correctly sized
        let newWidth = max(pos.visibleWidth, visibleNew)
        sections[idx].variablePositions[name] = TerminalVarPosition(
            row: pos.row, col: pos.col, visibleWidth: newWidth
        )
    }

    /// Count visible characters after stripping ANSI escape sequences
    private func stripANSIVisible(_ text: String) -> Int {
        var count = 0
        var i = text.startIndex
        while i < text.endIndex {
            if text[i] == "\u{001B}" {
                let next = text.index(after: i)
                if next < text.endIndex && text[next] == "[" {
                    var j = text.index(after: next)
                    while j < text.endIndex && !text[j].isLetter {
                        j = text.index(after: j)
                    }
                    i = j < text.endIndex ? text.index(after: j) : j
                } else {
                    i = next
                }
            } else {
                if text[i] != "\n" { count += 1 }
                i = text.index(after: i)
            }
        }
        return count
    }

    // MARK: - Shadow Buffer Operations (ARO-0053)

    /// Ensures shadow buffer is initialized
    private func ensureShadowBuffer() {
        guard shadowBuffer == nil else { return }
        guard useShadowBuffer else { return }

        let caps = detectCapabilities()
        guard caps.isTTY else {
            useShadowBuffer = false
            return
        }

        shadowBuffer = ShadowBuffer(rows: caps.rows, cols: caps.columns)
    }

    /// Renders text to shadow buffer at specific position
    /// - Parameters:
    ///   - row: Row position (0-indexed)
    ///   - col: Column position (0-indexed)
    ///   - text: Text to render
    ///   - fgColor: Foreground color (optional)
    ///   - bgColor: Background color (optional)
    ///   - bold: Bold style
    ///   - italic: Italic style
    ///   - underline: Underline style
    public func renderToBuffer(
        row: Int, col: Int,
        text: String,
        fgColor: TerminalColor? = nil,
        bgColor: TerminalColor? = nil,
        bold: Bool = false,
        italic: Bool = false,
        underline: Bool = false
    ) {
        ensureShadowBuffer()

        if let buffer = shadowBuffer {
            buffer.setText(
                row: row, col: col, text: text,
                fgColor: fgColor, bgColor: bgColor,
                bold: bold, italic: italic, underline: underline
            )
        } else {
            // Fallback to direct rendering
            moveCursor(row: row + 1, column: col + 1)
            render(text: text)
        }
    }

    /// Renders a single cell to shadow buffer
    /// - Parameters:
    ///   - row: Row position (0-indexed)
    ///   - col: Column position (0-indexed)
    ///   - char: Character to render
    ///   - fgColor: Foreground color (optional)
    ///   - bgColor: Background color (optional)
    ///   - bold: Bold style
    ///   - italic: Italic style
    ///   - underline: Underline style
    public func renderCell(
        row: Int, col: Int,
        char: Character,
        fgColor: TerminalColor? = nil,
        bgColor: TerminalColor? = nil,
        bold: Bool = false,
        italic: Bool = false,
        underline: Bool = false
    ) {
        ensureShadowBuffer()

        if let buffer = shadowBuffer {
            buffer.setCell(
                row: row, col: col, char: char,
                fgColor: fgColor, bgColor: bgColor,
                bold: bold, italic: italic, underline: underline
            )
        } else {
            // Fallback to direct rendering
            moveCursor(row: row + 1, column: col + 1)
            print(char, terminator: "")
            flushOutput()
        }
    }

    /// Flushes shadow buffer to terminal (renders only dirty regions)
    public func flush() {
        if let buffer = shadowBuffer {
            buffer.render()
        } else {
            flushOutput()
        }
    }

    /// Forces a complete screen refresh
    public func forceRefresh() {
        if let buffer = shadowBuffer {
            buffer.forceRefresh()
        } else {
            clear()
        }
    }

    /// Fills a rectangular region
    /// - Parameters:
    ///   - startRow: Starting row (0-indexed)
    ///   - startCol: Starting column (0-indexed)
    ///   - endRow: Ending row (0-indexed)
    ///   - endCol: Ending column (0-indexed)
    ///   - char: Character to fill with
    ///   - fgColor: Foreground color (optional)
    ///   - bgColor: Background color (optional)
    ///   - bold: Bold style
    public func fillRect(
        startRow: Int, startCol: Int,
        endRow: Int, endCol: Int,
        char: Character = " ",
        fgColor: TerminalColor? = nil,
        bgColor: TerminalColor? = nil,
        bold: Bool = false
    ) {
        ensureShadowBuffer()

        if let buffer = shadowBuffer {
            buffer.fillRect(
                startRow: startRow, startCol: startCol,
                endRow: endRow, endCol: endCol,
                char: char,
                fgColor: fgColor, bgColor: bgColor, bold: bold
            )
        }
    }

    /// Draws a horizontal line
    /// - Parameters:
    ///   - row: Row position (0-indexed)
    ///   - startCol: Starting column (0-indexed)
    ///   - endCol: Ending column (0-indexed)
    ///   - char: Character to use for line
    ///   - fgColor: Foreground color (optional)
    ///   - bgColor: Background color (optional)
    ///   - bold: Bold style
    public func drawHorizontalLine(
        row: Int, startCol: Int, endCol: Int,
        char: Character,
        fgColor: TerminalColor? = nil,
        bgColor: TerminalColor? = nil,
        bold: Bool = false
    ) {
        ensureShadowBuffer()

        if let buffer = shadowBuffer {
            buffer.drawHorizontalLine(
                row: row, startCol: startCol, endCol: endCol,
                char: char,
                fgColor: fgColor, bgColor: bgColor, bold: bold
            )
        }
    }

    /// Draws a vertical line
    /// - Parameters:
    ///   - col: Column position (0-indexed)
    ///   - startRow: Starting row (0-indexed)
    ///   - endRow: Ending row (0-indexed)
    ///   - char: Character to use for line
    ///   - fgColor: Foreground color (optional)
    ///   - bgColor: Background color (optional)
    ///   - bold: Bold style
    public func drawVerticalLine(
        col: Int, startRow: Int, endRow: Int,
        char: Character,
        fgColor: TerminalColor? = nil,
        bgColor: TerminalColor? = nil,
        bold: Bool = false
    ) {
        ensureShadowBuffer()

        if let buffer = shadowBuffer {
            buffer.drawVerticalLine(
                col: col, startRow: startRow, endRow: endRow,
                char: char,
                fgColor: fgColor, bgColor: bgColor, bold: bold
            )
        }
    }

    /// Handles terminal resize by creating new shadow buffer
    public func handleResize() {
        guard let oldBuffer = shadowBuffer else {
            ensureShadowBuffer()
            return
        }

        // Check if size actually changed
        guard oldBuffer.hasTerminalSizeChanged() else { return }

        // Create new buffer with updated size, preserving content
        shadowBuffer = oldBuffer.resizedBuffer()

        // Force full refresh with new size
        shadowBuffer?.forceRefresh()
    }

    // MARK: - Cursor Control

    /// Move cursor to specific position (1-indexed)
    /// - Parameters:
    ///   - row: Row number (1 = top)
    ///   - column: Column number (1 = left)
    public func moveCursor(row: Int, column: Int) {
        render(text: ANSIRenderer.moveCursor(row: row, column: column))
    }

    /// Hide the cursor
    public func hideCursor() {
        render(text: ANSIRenderer.hideCursor())
    }

    /// Show the cursor
    public func showCursor() {
        render(text: ANSIRenderer.showCursor())
    }

    // MARK: - Interactive Input

    /// Prompt user for text input
    /// - Parameters:
    ///   - message: Prompt message
    ///   - hidden: Hide input (for passwords)
    /// - Returns: User input string
    public func prompt(message: String, hidden: Bool) async -> String {
        let handler = InputHandler()
        return await handler.readLine(prompt: message, hidden: hidden)
    }

    /// Display interactive selection menu
    /// - Parameters:
    ///   - options: Available options to choose from
    ///   - message: Prompt message
    ///   - multiSelect: Allow multiple selections
    /// - Returns: Selected option(s)
    public func select(options: [String], message: String, multiSelect: Bool) async -> [String] {
        let handler = InputHandler()
        return await handler.selectMenu(options: options, message: message, multiSelect: multiSelect)
    }
}
