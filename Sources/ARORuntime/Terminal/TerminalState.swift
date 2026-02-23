//
//  TerminalState.swift
//  ARORuntime
//
//  Terminal styling state tracking for ANSI optimization
//  Part of ARO-0053: Terminal Shadow Buffer Optimization
//

import Foundation

/// Tracks the current terminal styling state to minimize ANSI escape code emissions
/// Only emits new codes when the desired state differs from current state
public struct TerminalState: Sendable {
    /// Current foreground color
    public var currentFgColor: TerminalColor?

    /// Current background color
    public var currentBgColor: TerminalColor?

    /// Current bold state
    public var currentBold: Bool

    /// Current italic state
    public var currentItalic: Bool

    /// Current underline state
    public var currentUnderline: Bool

    /// Current strikethrough state
    public var currentStrikethrough: Bool

    /// Creates a new terminal state with default (reset) styling
    public init() {
        self.currentFgColor = nil
        self.currentBgColor = nil
        self.currentBold = false
        self.currentItalic = false
        self.currentUnderline = false
        self.currentStrikethrough = false
    }

    /// Updates terminal state if needed, only emitting ANSI codes for changes
    /// This is the key optimization - we track what's currently set and only change what differs
    public mutating func updateIfNeeded(
        fgColor: TerminalColor?,
        bgColor: TerminalColor?,
        bold: Bool,
        italic: Bool,
        underline: Bool,
        strikethrough: Bool
    ) {
        // Check if any state differs
        let needsUpdate =
            fgColor != currentFgColor ||
            bgColor != currentBgColor ||
            bold != currentBold ||
            italic != currentItalic ||
            underline != currentUnderline ||
            strikethrough != currentStrikethrough

        guard needsUpdate else { return }

        // Build ANSI code for new state
        var codes: [String] = []

        // Reset if we're turning off any styles
        let turningOffBold = currentBold && !bold
        let turningOffItalic = currentItalic && !italic
        let turningOffUnderline = currentUnderline && !underline
        let turningOffStrikethrough = currentStrikethrough && !strikethrough

        if turningOffBold || turningOffItalic || turningOffUnderline || turningOffStrikethrough {
            codes.append("0")  // Reset all
            // Need to re-apply any styles we want to keep
            if bold { codes.append("1") }
            if italic { codes.append("3") }
            if underline { codes.append("4") }
            if strikethrough { codes.append("9") }
        } else {
            // Only add codes for styles being turned on
            if bold && !currentBold { codes.append("1") }
            if italic && !currentItalic { codes.append("3") }
            if underline && !currentUnderline { codes.append("4") }
            if strikethrough && !currentStrikethrough { codes.append("9") }
        }

        // Foreground color
        if fgColor != currentFgColor {
            if let fg = fgColor {
                codes.append(ANSIRenderer.colorCode(fg, foreground: true))
            }
        }

        // Background color
        if bgColor != currentBgColor {
            if let bg = bgColor {
                codes.append(ANSIRenderer.colorCode(bg, foreground: false))
            }
        }

        // Emit ANSI codes if we have any
        if !codes.isEmpty {
            print("\u{1B}[\(codes.joined(separator: ";"))m", terminator: "")
        }

        // Update state
        currentFgColor = fgColor
        currentBgColor = bgColor
        currentBold = bold
        currentItalic = italic
        currentUnderline = underline
        currentStrikethrough = strikethrough
    }

    /// Resets the terminal state to default
    public mutating func reset() {
        currentFgColor = nil
        currentBgColor = nil
        currentBold = false
        currentItalic = false
        currentUnderline = false
        currentStrikethrough = false
    }
}
