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
import AppKit

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

/// A resolved key + modifiers pair. Stored in UserDefaults as a
/// pipe-delimited `key|modifiers` string so the value is human-
/// readable when inspecting prefs.
struct KeybindingBinding: Equatable {
    let key: KeyEquivalent
    let modifiers: EventModifiers

    var serialised: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option)  { parts.append("alt") }
        if modifiers.contains(.shift)   { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        let keyToken: String
        switch key {
        case .space: keyToken = "space"
        case .return: keyToken = "return"
        case .escape: keyToken = "escape"
        case .delete: keyToken = "delete"
        case .leftArrow: keyToken = "left"
        case .rightArrow: keyToken = "right"
        case .upArrow: keyToken = "up"
        case .downArrow: keyToken = "down"
        default: keyToken = String(key.character)
        }
        return parts.joined(separator: "+") + "|" + keyToken
    }

    init(key: KeyEquivalent, modifiers: EventModifiers) {
        self.key = key
        self.modifiers = modifiers
    }

    init?(_ serialised: String) {
        let parts = serialised.split(separator: "|", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        var mods: EventModifiers = []
        if !parts[0].isEmpty {
            for token in parts[0].split(separator: "+") {
                switch token {
                case "ctrl":  mods.insert(.control)
                case "alt":   mods.insert(.option)
                case "shift": mods.insert(.shift)
                case "cmd":   mods.insert(.command)
                default: continue
                }
            }
        }
        switch parts[1] {
        case "space":  self.key = .space
        case "return": self.key = .return
        case "escape": self.key = .escape
        case "delete": self.key = .delete
        case "left":   self.key = .leftArrow
        case "right":  self.key = .rightArrow
        case "up":     self.key = .upArrow
        case "down":   self.key = .downArrow
        default:
            guard let ch = parts[1].first, parts[1].count == 1
            else { return nil }
            self.key = KeyEquivalent(ch)
        }
        self.modifiers = mods
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

/// Per-user overrides keyed by command id. Backed by
/// UserDefaults so changes stick across launches, and
/// `@Observable` so the Settings tab redraws as the user remaps
/// shortcuts. The shared instance is what `HiddenShortcutButton`
/// consults at construction time.
@MainActor
@Observable
final class KeybindingStore {
    static let shared = KeybindingStore()

    private static let defaultsKey = "solaro.keybindings.overrides"

    private(set) var overrides: [String: KeybindingBinding]

    private init() {
        let raw = UserDefaults.standard.dictionary(forKey: Self.defaultsKey)
            as? [String: String] ?? [:]
        var parsed: [String: KeybindingBinding] = [:]
        for (id, ser) in raw {
            if let b = KeybindingBinding(ser) {
                parsed[id] = b
            }
        }
        self.overrides = parsed
    }

    func resolved(for commandID: String) -> KeybindingBinding? {
        if let user = overrides[commandID] { return user }
        guard let cmd = KeybindingRegistry.shared
            .first(where: { $0.id == commandID }) else { return nil }
        return KeybindingBinding(key: cmd.defaultKey,
                                 modifiers: cmd.defaultModifiers)
    }

    func setOverride(_ binding: KeybindingBinding,
                     for commandID: String) {
        overrides[commandID] = binding
        persist()
    }

    func clearOverride(for commandID: String) {
        overrides.removeValue(forKey: commandID)
        persist()
    }

    /// Returns the command id that already binds `(key, modifiers)`
    /// if any — used by the capture popover to warn the user
    /// before they overwrite an existing assignment.
    func conflict(with binding: KeybindingBinding,
                  excluding commandID: String) -> String? {
        for cmd in KeybindingRegistry.shared where cmd.id != commandID {
            if let b = resolved(for: cmd.id),
               b.key.character == binding.key.character,
               b.modifiers == binding.modifiers {
                return cmd.displayName
            }
        }
        return nil
    }

    private func persist() {
        let raw = overrides.mapValues { $0.serialised }
        UserDefaults.standard.set(raw, forKey: Self.defaultsKey)
    }
}

/// Settings → Keybindings tab. Lists every command grouped by
/// category with its shortcut on the trailing edge. Click a row
/// to capture a new combination; "Reset" reverts to default.
struct KeybindingsSettingsTab: View {
    @Bindable private var store = KeybindingStore.shared
    @State private var capturingID: String?

    private var grouped: [(KeybindingCommand.Category, [KeybindingCommand])] {
        KeybindingCommand.Category.allCases.map { cat in
            (cat, KeybindingRegistry.shared.filter { $0.category == cat })
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SolaroSpace.l) {
                Text("Click a shortcut to record a replacement. Press Esc to cancel, or click Reset to revert to the default. Overrides are stored in `solaro.keybindings.overrides`.")
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
                row(for: c)
                Divider()
            }
        }
    }

    @ViewBuilder
    private func row(for command: KeybindingCommand) -> some View {
        let active = store.resolved(for: command.id)
        let isOverridden = store.overrides[command.id] != nil
        HStack(spacing: SolaroSpace.s) {
            Text(command.displayName)
            if isOverridden {
                Text("custom")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(SolaroColor.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            Spacer()
            Button {
                capturingID = command.id
            } label: {
                Text(active.map { KeybindingCommand.describe(key: $0.key,
                                                              modifiers: $0.modifiers) }
                     ?? command.defaultDescription)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(capturingID == command.id
                                     ? SolaroColor.accent
                                     : SolaroColor.textPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(capturingID == command.id
                                    ? SolaroColor.accent
                                    : SolaroColor.divider,
                                    lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .help(capturingID == command.id
                  ? "Press the new shortcut (Esc to cancel)"
                  : "Click to remap")
            if isOverridden {
                Button("Reset") {
                    store.clearOverride(for: command.id)
                }
                .controlSize(.small)
            }
        }
        .background(
            KeyCaptureBridge(
                isCapturing: Binding(
                    get: { capturingID == command.id },
                    set: { if !$0 { capturingID = nil } }
                ),
                onCapture: { binding in
                    let conflict = store.conflict(with: binding,
                                                  excluding: command.id)
                    if let conflict {
                        // Soft warning: still apply the override
                        // but note the collision in the description.
                        // A future iteration could surface a confirm
                        // dialog and refuse.
                        print("[keybindings] \(command.displayName) shortcut conflicts with \(conflict).")
                    }
                    store.setOverride(binding, for: command.id)
                    capturingID = nil
                }
            )
        )
    }
}

/// Bridges an NSEvent monitor into SwiftUI: while `isCapturing`
/// is true and the parent view is in the responder chain,
/// every keyDown is intercepted, parsed into a
/// `KeybindingBinding`, and reported. Escape cancels. Used by
/// `KeybindingsSettingsTab` to capture a new shortcut.
private struct KeyCaptureBridge: NSViewRepresentable {
    @Binding var isCapturing: Bool
    let onCapture: (KeybindingBinding) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        context.coordinator.parent = self
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.parent = self
        if isCapturing {
            context.coordinator.startMonitoring()
        } else {
            context.coordinator.stopMonitoring()
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stopMonitoring()
    }

    final class Coordinator: NSObject {
        var parent: KeyCaptureBridge?
        private var monitor: Any?

        func startMonitoring() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                if event.keyCode == 53 {   // Escape
                    self.parent?.isCapturing = false
                    return nil
                }
                if let binding = Self.binding(from: event) {
                    self.parent?.onCapture(binding)
                    return nil
                }
                return event
            }
        }

        func stopMonitoring() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private static func binding(from event: NSEvent) -> KeybindingBinding? {
            var mods: EventModifiers = []
            let nsmods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if nsmods.contains(.control)  { mods.insert(.control) }
            if nsmods.contains(.option)   { mods.insert(.option) }
            if nsmods.contains(.shift)    { mods.insert(.shift) }
            if nsmods.contains(.command)  { mods.insert(.command) }
            // Require at least one modifier so a stray "f" while
            // the popover is up doesn't clobber a binding.
            guard !mods.isEmpty else { return nil }
            // Special keys take priority over chars so Tab / Return
            // can become first-class bindings.
            switch event.keyCode {
            case 49: return KeybindingBinding(key: .space, modifiers: mods)
            case 36: return KeybindingBinding(key: .return, modifiers: mods)
            case 51: return KeybindingBinding(key: .delete, modifiers: mods)
            case 123: return KeybindingBinding(key: .leftArrow, modifiers: mods)
            case 124: return KeybindingBinding(key: .rightArrow, modifiers: mods)
            case 126: return KeybindingBinding(key: .upArrow, modifiers: mods)
            case 125: return KeybindingBinding(key: .downArrow, modifiers: mods)
            default: break
            }
            guard let chars = event.charactersIgnoringModifiers,
                  let ch = chars.first else { return nil }
            return KeybindingBinding(key: KeyEquivalent(ch),
                                     modifiers: mods)
        }
    }
}
