//
//  ScreenCell.swift
//  ARORuntime
//
//  Terminal UI shadow buffer cell structure
//  Part of ARO-0053: Terminal Shadow Buffer Optimization
//

import Foundation

/// Represents a single cell in the terminal screen buffer with character and styling
public struct ScreenCell: Equatable, Sendable {
    /// The character displayed in this cell
    public let char: Character

    /// Foreground color (nil = default terminal color)
    public let fgColor: TerminalColor?

    /// Background color (nil = default terminal background)
    public let bgColor: TerminalColor?

    /// Bold/bright text
    public let bold: Bool

    /// Italic text
    public let italic: Bool

    /// Underlined text
    public let underline: Bool

    /// Strikethrough text
    public let strikethrough: Bool

    /// Creates an empty cell with default styling (space character)
    public init() {
        self.char = " "
        self.fgColor = nil
        self.bgColor = nil
        self.bold = false
        self.italic = false
        self.underline = false
        self.strikethrough = false
    }

    /// Creates a cell with specified character and styling
    public init(
        char: Character,
        fgColor: TerminalColor? = nil,
        bgColor: TerminalColor? = nil,
        bold: Bool = false,
        italic: Bool = false,
        underline: Bool = false,
        strikethrough: Bool = false
    ) {
        self.char = char
        self.fgColor = fgColor
        self.bgColor = bgColor
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.strikethrough = strikethrough
    }

    /// Equality check - cells are equal if all properties match
    public static func == (lhs: ScreenCell, rhs: ScreenCell) -> Bool {
        return lhs.char == rhs.char &&
               lhs.fgColor == rhs.fgColor &&
               lhs.bgColor == rhs.bgColor &&
               lhs.bold == rhs.bold &&
               lhs.italic == rhs.italic &&
               lhs.underline == rhs.underline &&
               lhs.strikethrough == rhs.strikethrough
    }
}
