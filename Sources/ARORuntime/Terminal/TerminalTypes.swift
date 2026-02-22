import Foundation

// MARK: - Terminal Capabilities

/// Terminal capability information detected at runtime
public struct Capabilities: Sendable {
    /// Terminal height in rows
    public let rows: Int

    /// Terminal width in columns
    public let columns: Int

    /// Supports basic 16-color ANSI codes
    public let supportsColor: Bool

    /// Supports 24-bit RGB true color
    public let supportsTrueColor: Bool

    /// Supports Unicode characters (box drawing, etc.)
    public let supportsUnicode: Bool

    /// Output is connected to a terminal (not piped/redirected)
    public let isTTY: Bool

    /// Terminal character encoding
    public let encoding: String

    public init(
        rows: Int,
        columns: Int,
        supportsColor: Bool,
        supportsTrueColor: Bool,
        supportsUnicode: Bool,
        isTTY: Bool,
        encoding: String
    ) {
        self.rows = rows
        self.columns = columns
        self.supportsColor = supportsColor
        self.supportsTrueColor = supportsTrueColor
        self.supportsUnicode = supportsUnicode
        self.isTTY = isTTY
        self.encoding = encoding
    }
}

// MARK: - Border Styles

/// Box border styles for layout widgets
public enum BorderStyle: String, Sendable, CaseIterable {
    case single = "single"
    case double = "double"
    case rounded = "rounded"
    case thick = "thick"
    case none = "none"
}

// MARK: - Terminal Colors

/// Named terminal colors
public enum TerminalColor: String, Sendable, CaseIterable {
    // Basic colors
    case black = "black"
    case red = "red"
    case green = "green"
    case yellow = "yellow"
    case blue = "blue"
    case magenta = "magenta"
    case cyan = "cyan"
    case white = "white"

    // Bright variants
    case brightBlack = "bright-black"
    case brightRed = "bright-red"
    case brightGreen = "bright-green"
    case brightYellow = "bright-yellow"
    case brightBlue = "bright-blue"
    case brightMagenta = "bright-magenta"
    case brightCyan = "bright-cyan"
    case brightWhite = "bright-white"

    // Semantic colors
    case success = "success"
    case error = "error"
    case warning = "warning"
    case info = "info"

    /// Map semantic colors to basic colors
    public var basicColor: TerminalColor {
        switch self {
        case .success: return .green
        case .error: return .red
        case .warning: return .yellow
        case .info: return .blue
        default: return self
        }
    }

    /// Get ANSI color code (30-37 for standard, 90-97 for bright)
    public var foregroundCode: Int {
        switch self {
        // Standard colors
        case .black: return 30
        case .red: return 31
        case .green: return 32
        case .yellow: return 33
        case .blue: return 34
        case .magenta: return 35
        case .cyan: return 36
        case .white: return 37

        // Bright colors
        case .brightBlack: return 90
        case .brightRed: return 91
        case .brightGreen: return 92
        case .brightYellow: return 93
        case .brightBlue: return 94
        case .brightMagenta: return 95
        case .brightCyan: return 96
        case .brightWhite: return 97

        // Semantic → basic mapping
        case .success: return TerminalColor.green.foregroundCode
        case .error: return TerminalColor.red.foregroundCode
        case .warning: return TerminalColor.yellow.foregroundCode
        case .info: return TerminalColor.blue.foregroundCode
        }
    }

    /// Get background color code (add 10 to foreground code)
    public var backgroundCode: Int {
        foregroundCode + 10
    }
}

// MARK: - Text Alignment

/// Text alignment for layout widgets
public enum Alignment: String, Sendable {
    case left = "left"
    case center = "center"
    case right = "right"
}

// MARK: - Action Result Types

/// Result from Prompt action
public struct PromptResult: Sendable {
    public let value: String
    public let hidden: Bool

    public init(value: String, hidden: Bool) {
        self.value = value
        self.hidden = hidden
    }
}

/// Result from Select action
public struct SelectResult: Sendable {
    public let selected: [String]
    public let multiSelect: Bool

    public init(selected: [String], multiSelect: Bool) {
        self.selected = selected
        self.multiSelect = multiSelect
    }
}

/// Result from Clear action
public struct ClearResult: Sendable {
    public let targetCleared: String

    public init(targetCleared: String) {
        self.targetCleared = targetCleared
    }
}

// MARK: - Layout Configuration

/// Configuration for Box widget
public struct BoxConfig: Sendable {
    public let width: Int
    public let height: Int?
    public let border: BorderStyle
    public let title: String?
    public let padding: Int
    public let align: Alignment
    public let color: TerminalColor?
    public let backgroundColor: TerminalColor?

    public init(
        width: Int = 40,
        height: Int? = nil,
        border: BorderStyle = .single,
        title: String? = nil,
        padding: Int = 1,
        align: Alignment = .left,
        color: TerminalColor? = nil,
        backgroundColor: TerminalColor? = nil
    ) {
        self.width = width
        self.height = height
        self.border = border
        self.title = title
        self.padding = padding
        self.align = align
        self.color = color
        self.backgroundColor = backgroundColor
    }
}

/// Configuration for Progress bar widget
public struct ProgressConfig: Sendable {
    public let value: Double // 0.0 to 1.0
    public let total: Double?
    public let width: Int
    public let label: String?
    public let showPercent: Bool
    public let style: ProgressStyle
    public let color: TerminalColor

    public init(
        value: Double,
        total: Double? = nil,
        width: Int = 40,
        label: String? = nil,
        showPercent: Bool = true,
        style: ProgressStyle = .bar,
        color: TerminalColor = .green
    ) {
        self.value = value
        self.total = total
        self.width = width
        self.label = label
        self.showPercent = showPercent
        self.style = style
        self.color = color
    }
}

/// Progress bar styles
public enum ProgressStyle: String, Sendable {
    case bar = "bar"
    case blocks = "blocks"
    case dots = "dots"
    case arrow = "arrow"
}

/// Configuration for Table widget
public struct TableConfig: Sendable {
    public let headers: [String]?
    public let widths: [Int]?
    public let border: BorderStyle
    public let align: [Alignment]?
    public let zebra: Bool

    public init(
        headers: [String]? = nil,
        widths: [Int]? = nil,
        border: BorderStyle = .single,
        align: [Alignment]? = nil,
        zebra: Bool = false
    ) {
        self.headers = headers
        self.widths = widths
        self.border = border
        self.align = align
        self.zebra = zebra
    }
}
