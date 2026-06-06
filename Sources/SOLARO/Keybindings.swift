// ============================================================
// Keybindings.swift
// SOLARO — registry of every UI command + its default shortcut
// ============================================================
//
// First slice of #270 — central catalogue every shortcut in the
// app reads, plus a read-only Settings tab so the user can see
// what's bound to what. User-override capture + conflict
// detection follow in a later MR; this file lands the data model
// and surface so the registry has somewhere to live.
//
// Each command's default key + modifiers are duplicated in the
// HiddenShortcutButton call sites in WorkspaceView for now; a
// future MR rewires those to read straight from the registry so
// the table here becomes the single source of truth.

import SwiftUI

/// One remappable command exposed in the Settings → Keybindings
/// tab. The default `key` + `modifiers` represent today's hard
/// coded shortcut; the optional override (stored in UserDefaults
/// once the capture UI lands) takes precedence at lookup time.
struct KeybindingCommand: Identifiable {
    let id: String
    let displayName: String
    let category: Category
    let defaultKey: KeyEquivalent
    let defaultModifiers: EventModifiers

    enum Category: String, CaseIterable, Identifiable {
        case navigation = "Navigation"
        case editing = "Editing"
        case search = "Search"
        case run = "Run"
        case panels = "Panels"
        var id: String { rawValue }
    }

    var defaultDescription: String {
        Self.describe(key: defaultKey, modifiers: defaultModifiers)
    }

    static func describe(key: KeyEquivalent,
                         modifiers: EventModifiers) -> String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option)  { s += "⌥" }
        if modifiers.contains(.shift)   { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        // KeyEquivalent's character isn't directly readable
        // pre-macOS 14, but our subset is small enough to special
        // case the common ones.
        switch key {
        case .space: s += "Space"
        case .return: s += "↩"
        case .escape: s += "⎋"
        case .delete: s += "⌫"
        case .leftArrow: s += "←"
        case .rightArrow: s += "→"
        case .upArrow: s += "↑"
        case .downArrow: s += "↓"
        default:
            s += String(key.character).uppercased()
        }
        return s
    }
}

/// Single source of truth for every keyboard shortcut in SOLARO.
/// Lookup at use-site goes through `KeybindingRegistry.shared` —
/// for now the call sites still hardcode; this enum exists so
/// the Settings table renders without surprises.
enum KeybindingRegistry {
    static let shared: [KeybindingCommand] = [
        // Navigation
        KeybindingCommand(id: "navigation.commandPalette",
                          displayName: "Command Palette",
                          category: .navigation,
                          defaultKey: "p",
                          defaultModifiers: [.command, .shift]),
        KeybindingCommand(id: "navigation.quickOpen",
                          displayName: "Quick Open File",
                          category: .navigation,
                          defaultKey: "p",
                          defaultModifiers: [.command]),
        KeybindingCommand(id: "navigation.findInProject",
                          displayName: "Find in Project",
                          category: .search,
                          defaultKey: "f",
                          defaultModifiers: [.command, .shift]),
        KeybindingCommand(id: "navigation.closeTab",
                          displayName: "Close Tab",
                          category: .navigation,
                          defaultKey: "w",
                          defaultModifiers: [.command]),
        KeybindingCommand(id: "navigation.nextTab",
                          displayName: "Next Tab",
                          category: .navigation,
                          defaultKey: "]",
                          defaultModifiers: [.command, .shift]),
        KeybindingCommand(id: "navigation.previousTab",
                          displayName: "Previous Tab",
                          category: .navigation,
                          defaultKey: "[",
                          defaultModifiers: [.command, .shift]),
        KeybindingCommand(id: "navigation.symbolPalette",
                          displayName: "Symbol Palette",
                          category: .navigation,
                          defaultKey: "o",
                          defaultModifiers: [.command, .shift]),
        KeybindingCommand(id: "navigation.goToDefinition",
                          displayName: "Go to Definition",
                          category: .navigation,
                          defaultKey: "d",
                          defaultModifiers: [.control, .command]),
        // Editing
        KeybindingCommand(id: "editing.formatDocument",
                          displayName: "Format Document",
                          category: .editing,
                          defaultKey: "f",
                          defaultModifiers: [.option, .shift]),
        KeybindingCommand(id: "editing.acceptCompletion",
                          displayName: "Accept Inline Completion",
                          category: .editing,
                          defaultKey: " ",
                          defaultModifiers: [.control]),
        KeybindingCommand(id: "editing.rename",
                          displayName: "Rename Symbol",
                          category: .editing,
                          defaultKey: "r",
                          defaultModifiers: [.control, .command]),
        // Panels
        KeybindingCommand(id: "panels.toggleTerminal",
                          displayName: "Toggle Terminal",
                          category: .panels,
                          defaultKey: "`",
                          defaultModifiers: [.control]),
        KeybindingCommand(id: "panels.toggleConsole",
                          displayName: "Show Console",
                          category: .panels,
                          defaultKey: "c",
                          defaultModifiers: [.command, .shift]),
        KeybindingCommand(id: "panels.toggleTerminalPane",
                          displayName: "Show Terminal Pane",
                          category: .panels,
                          defaultKey: "t",
                          defaultModifiers: [.command, .shift]),
        KeybindingCommand(id: "panels.toggleTests",
                          displayName: "Show Tests Pane",
                          category: .panels,
                          defaultKey: "u",
                          defaultModifiers: [.command, .shift]),
        // Run
        KeybindingCommand(id: "run.tests",
                          displayName: "Run Tests",
                          category: .run,
                          defaultKey: "u",
                          defaultModifiers: [.control, .command]),
    ]
}

/// Settings → Keybindings tab. Lists every command grouped by
/// category with its shortcut on the trailing edge. Read-only
/// for the moment — the capture UI + UserDefaults persistence
/// land in a later step of #270.
struct KeybindingsSettingsTab: View {
    private var grouped: [(KeybindingCommand.Category, [KeybindingCommand])] {
        KeybindingCommand.Category.allCases.map { cat in
            (cat, KeybindingRegistry.shared.filter { $0.category == cat })
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SolaroSpace.l) {
                Text("Default keyboard shortcuts. User overrides + capture UI land in a later update — this tab is currently a reference of what's bound today so you can spot conflicts with other apps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(grouped, id: \.0) { cat, commands in
                    if !commands.isEmpty {
                        section(title: cat.rawValue, commands: commands)
                    }
                }
            }
            .padding(.vertical, SolaroSpace.m)
        }
    }

    private func section(title: String, commands: [KeybindingCommand])
    -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption)
                .tracking(1)
                .foregroundStyle(.secondary)
            ForEach(commands) { c in
                HStack {
                    Text(c.displayName)
                    Spacer()
                    Text(c.defaultDescription)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Divider()
            }
        }
    }
}
