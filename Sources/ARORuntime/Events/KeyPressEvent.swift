// ============================================================
// KeyPressEvent.swift
// ARO Runtime - Keyboard key press event
// ============================================================

import Foundation

/// Emitted when the user presses a key while keyboard listening is active.
/// The `key` field contains a normalized name:
///   "up", "down", "left", "right", "enter", "escape", "backspace",
///   a single printable character (e.g. "q", "1"), or "unknown".
public struct KeyPressEvent: RuntimeEvent {
    public static var eventType: String { "keyboard.keypress" }
    public let timestamp: Date
    public let key: String

    public init(key: String) {
        self.timestamp = Date()
        self.key = key
    }
}
