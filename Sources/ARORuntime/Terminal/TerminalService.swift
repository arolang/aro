import Foundation

/// Thread-safe terminal service for capability detection and rendering
/// Use as singleton via ExecutionContext.service(TerminalService.self)
public actor TerminalService: Sendable {
    // MARK: - Properties

    /// Cached terminal capabilities (lazy detection)
    private var capabilities: Capabilities?

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
        render(text: ANSIRenderer.clearScreen())
    }

    /// Clear the current line
    public func clearLine() {
        render(text: ANSIRenderer.clearLine())
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
