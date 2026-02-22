import Foundation

/// Generates ANSI escape sequences for terminal control
public struct ANSIRenderer: Sendable {
    // MARK: - Escape Code Constants

    private static let ESC = "\u{001B}"
    private static let CSI = ESC + "["

    // MARK: - Colors

    /// Generate foreground color code
    public static func color(_ name: String, capabilities: Capabilities) -> String {
        // If terminal doesn't support color, return empty
        guard capabilities.supportsColor else { return "" }

        // Check for RGB format: rgb(r, g, b)
        if name.hasPrefix("rgb(") && name.hasSuffix(")") {
            return parseRGBColor(name, foreground: true, capabilities: capabilities)
        }

        // Named color lookup
        if let termColor = TerminalColor(rawValue: name.lowercased()) {
            return "\(CSI)\(termColor.foregroundCode)m"
        }

        // Unknown color, return empty
        return ""
    }

    /// Generate background color code
    public static func backgroundColor(_ name: String, capabilities: Capabilities) -> String {
        // If terminal doesn't support color, return empty
        guard capabilities.supportsColor else { return "" }

        // Check for RGB format
        if name.hasPrefix("rgb(") && name.hasSuffix(")") {
            return parseRGBColor(name, foreground: false, capabilities: capabilities)
        }

        // Named color lookup
        if let termColor = TerminalColor(rawValue: name.lowercased()) {
            return "\(CSI)\(termColor.backgroundCode)m"
        }

        return ""
    }

    /// Generate true color RGB code (24-bit)
    public static func colorRGB(r: Int, g: Int, b: Int, capabilities: Capabilities) -> String {
        guard capabilities.supportsColor else { return "" }

        if capabilities.supportsTrueColor {
            // Use 24-bit RGB
            return "\(CSI)38;2;\(r);\(g);\(b)m"
        } else {
            // Fallback to closest 256-color or 16-color
            let colorIndex = closestColor256(r: r, g: g, b: b)
            return "\(CSI)38;5;\(colorIndex)m"
        }
    }

    /// Generate RGB background color code
    public static func backgroundRGB(r: Int, g: Int, b: Int, capabilities: Capabilities) -> String {
        guard capabilities.supportsColor else { return "" }

        if capabilities.supportsTrueColor {
            return "\(CSI)48;2;\(r);\(g);\(b)m"
        } else {
            let colorIndex = closestColor256(r: r, g: g, b: b)
            return "\(CSI)48;5;\(colorIndex)m"
        }
    }

    // MARK: - Text Styles

    /// Bold text
    public static func bold() -> String {
        return "\(CSI)1m"
    }

    /// Dim/faint text
    public static func dim() -> String {
        return "\(CSI)2m"
    }

    /// Italic text
    public static func italic() -> String {
        return "\(CSI)3m"
    }

    /// Underlined text
    public static func underline() -> String {
        return "\(CSI)4m"
    }

    /// Blinking text
    public static func blink() -> String {
        return "\(CSI)5m"
    }

    /// Reverse video (swap foreground/background)
    public static func reverse() -> String {
        return "\(CSI)7m"
    }

    /// Strikethrough text
    public static func strikethrough() -> String {
        return "\(CSI)9m"
    }

    /// Reset all styling
    public static func reset() -> String {
        return "\(CSI)0m"
    }

    // MARK: - Cursor Control

    /// Move cursor to specific position (1-indexed)
    public static func moveCursor(row: Int, column: Int) -> String {
        return "\(CSI)\(row);\(column)H"
    }

    /// Move cursor up N rows
    public static func cursorUp(_ n: Int = 1) -> String {
        return "\(CSI)\(n)A"
    }

    /// Move cursor down N rows
    public static func cursorDown(_ n: Int = 1) -> String {
        return "\(CSI)\(n)B"
    }

    /// Move cursor right N columns
    public static func cursorRight(_ n: Int = 1) -> String {
        return "\(CSI)\(n)C"
    }

    /// Move cursor left N columns
    public static func cursorLeft(_ n: Int = 1) -> String {
        return "\(CSI)\(n)D"
    }

    /// Save cursor position
    public static func saveCursor() -> String {
        return "\(ESC)7"
    }

    /// Restore saved cursor position
    public static func restoreCursor() -> String {
        return "\(ESC)8"
    }

    /// Hide cursor
    public static func hideCursor() -> String {
        return "\(CSI)?25l"
    }

    /// Show cursor
    public static func showCursor() -> String {
        return "\(CSI)?25h"
    }

    // MARK: - Screen Control

    /// Clear entire screen
    public static func clearScreen() -> String {
        return "\(CSI)2J\(CSI)H"  // Clear + move to home
    }

    /// Clear current line
    public static func clearLine() -> String {
        return "\(CSI)2K"
    }

    /// Clear from cursor to end of line
    public static func clearToEndOfLine() -> String {
        return "\(CSI)K"
    }

    /// Clear from cursor to start of line
    public static func clearToStartOfLine() -> String {
        return "\(CSI)1K"
    }

    /// Clear from cursor to end of screen
    public static func clearToEndOfScreen() -> String {
        return "\(CSI)J"
    }

    /// Clear from cursor to start of screen
    public static func clearToStartOfScreen() -> String {
        return "\(CSI)1J"
    }

    /// Switch to alternate screen buffer
    public static func alternateScreen() -> String {
        return "\(CSI)?1049h"
    }

    /// Switch back to main screen buffer
    public static func mainScreen() -> String {
        return "\(CSI)?1049l"
    }

    // MARK: - Helper Functions

    /// Parse RGB color string: "rgb(100, 200, 255)"
    private static func parseRGBColor(_ rgbString: String, foreground: Bool, capabilities: Capabilities) -> String {
        // Extract numbers from "rgb(r, g, b)"
        let components = rgbString
            .replacingOccurrences(of: "rgb(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .replacingOccurrences(of: " ", with: "")
            .split(separator: ",")
            .compactMap { Int($0) }

        guard components.count == 3 else { return "" }

        let r = max(0, min(255, components[0]))
        let g = max(0, min(255, components[1]))
        let b = max(0, min(255, components[2]))

        return foreground
            ? colorRGB(r: r, g: g, b: b, capabilities: capabilities)
            : backgroundRGB(r: r, g: g, b: b, capabilities: capabilities)
    }

    /// Convert RGB to closest 256-color palette index
    private static func closestColor256(r: Int, g: Int, b: Int) -> Int {
        // 256-color palette has:
        // - 16 system colors (0-15)
        // - 216 color cube (16-231): 6x6x6 RGB cube
        // - 24 grayscale (232-255)

        // Check if it's grayscale
        let isGray = abs(r - g) < 10 && abs(g - b) < 10 && abs(r - b) < 10
        if isGray {
            // Map to grayscale ramp (232-255)
            let gray = (r + g + b) / 3
            if gray < 8 {
                return 16  // Black
            } else if gray > 247 {
                return 231  // White
            } else {
                return 232 + ((gray - 8) * 24 / 240)
            }
        }

        // Map to 6x6x6 color cube
        let rIndex = (r * 5 / 255)
        let gIndex = (g * 5 / 255)
        let bIndex = (b * 5 / 255)

        return 16 + (36 * rIndex) + (6 * gIndex) + bIndex
    }
}
