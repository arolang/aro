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
        #if canImport(Darwin)
        Darwin.fflush(Darwin.stdout)
        #elseif canImport(Glibc)
        Glibc.fflush(Glibc.stdout)
        #endif
    }

    // MARK: - Screen Control

    /// Clear the entire screen
    public func clear() {
        if useShadowBuffer, let buffer = shadowBuffer {
            buffer.clear()
            buffer.render()
        } else {
            render(text: ANSIRenderer.clearScreen())
        }
    }

    /// Clear the current line
    public func clearLine() {
        render(text: ANSIRenderer.clearLine())
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
