// ============================================================
// KeybindingOverrideTests.swift
// SOLARO — Settings → Keybindings overrides (GitLab #534)
// ============================================================

import Testing
import SwiftUI
@testable import SOLARO

@Suite("Keybinding overrides", .serialized)
@MainActor
struct KeybindingOverrideTests {

    private func freshStore(_ name: String = UUID().uuidString) -> KeybindingStore {
        let suite = "solaro.tests.keybindings.\(name)"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        return KeybindingStore(defaults: UserDefaults(suiteName: suite)!)
    }

    @Test func resolvesTheRegistryDefaultWhenThereIsNoOverride() {
        let store = freshStore()
        let binding = store.resolved(for: "navigation.quickOpen")
        #expect(binding?.key.character == "p")
        #expect(binding?.modifiers == [.command])
    }

    /// The bug: a recorded override was persisted and badged
    /// "custom" while every call site kept its hardcoded key.
    /// Lookup is what the call sites use now, so it must win.
    @Test func anOverrideWinsOverTheDefault() {
        let store = freshStore()
        store.setOverride(KeybindingBinding(key: "k", modifiers: [.command]),
                          for: "navigation.quickOpen")
        let binding = store.resolved(for: "navigation.quickOpen")
        #expect(binding?.key.character == "k")
        #expect(binding?.modifiers == [.command])
    }

    @Test func resettingRestoresTheDefault() {
        let store = freshStore()
        store.setOverride(KeybindingBinding(key: "k", modifiers: [.command]),
                          for: "navigation.quickOpen")
        store.clearOverride(for: "navigation.quickOpen")
        #expect(store.resolved(for: "navigation.quickOpen")?.key.character == "p")
        #expect(store.overrides["navigation.quickOpen"] == nil)
    }

    @Test func anUnknownCommandResolvesToNothing() {
        let store = freshStore()
        // A nil resolution must bind no shortcut at all rather than a
        // bogus key equivalent.
        #expect(store.resolved(for: "nope.notACommand") == nil)
    }

    @Test func overridesSurviveAReload() {
        let suite = "solaro.tests.keybindings.\(UUID().uuidString)"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        let defaults = UserDefaults(suiteName: suite)!
        let first = KeybindingStore(defaults: defaults)
        first.setOverride(KeybindingBinding(key: "j", modifiers: [.command, .shift]),
                          for: "navigation.symbolPalette")

        let reloaded = KeybindingStore(defaults: defaults)
        let binding = reloaded.resolved(for: "navigation.symbolPalette")
        #expect(binding?.key.character == "j")
        #expect(binding?.modifiers == [.command, .shift])
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    // MARK: - Conflict detection

    @Test func detectsACollisionWithAnExistingBinding() {
        let store = freshStore()
        // ⌘⇧P is the Command Palette's default.
        let conflict = store.conflict(
            with: KeybindingBinding(key: "p", modifiers: [.command, .shift]),
            excluding: "navigation.quickOpen")
        #expect(conflict == "Command Palette")
    }

    @Test func aFreeCombinationHasNoConflict() {
        let store = freshStore()
        let conflict = store.conflict(
            with: KeybindingBinding(key: "j", modifiers: [.command, .control, .shift]),
            excluding: "navigation.quickOpen")
        #expect(conflict == nil)
    }

    @Test func aCommandDoesNotConflictWithItself() {
        let store = freshStore()
        let conflict = store.conflict(
            with: KeybindingBinding(key: "p", modifiers: [.command]),
            excluding: "navigation.quickOpen")
        #expect(conflict == nil)
    }

    /// The shipped defaults must not collide with each other, or the
    /// settings tab lights up warnings out of the box.
    @Test func theShippedDefaultsAreConflictFree() {
        let store = freshStore()
        #expect(store.conflictingCommandIDs.isEmpty)
    }

    /// Run, Debug and Stop are in the registry (#762).
    ///
    /// They had working shortcuts before, hardcoded on the menu items,
    /// which meant they could not be remapped and never appeared in the
    /// Settings table — the one place a user looks to find out what the
    /// app's keys are.
    @Test func theRunCommandsAreBindable() {
        let store = freshStore()
        for id in ["run.play", "run.debug", "run.stop", "run.tests"] {
            #expect(KeybindingRegistry.shared.contains { $0.id == id },
                    "\(id) is missing from the registry")
            #expect(store.resolved(for: id) != nil,
                    "\(id) resolves to no binding")
        }
    }

    @Test func runKeepsItsFamiliarDefaults() {
        let store = freshStore()
        // ⌘R is Xcode's, and ⌘. is the standard macOS cancel. Changing
        // either out from under someone would be its own bug.
        #expect(store.resolved(for: "run.play")?.key.character == "r")
        #expect(store.resolved(for: "run.play")?.modifiers == [.command])
        #expect(store.resolved(for: "run.stop")?.key.character == ".")
        #expect(store.resolved(for: "run.stop")?.modifiers == [.command])
    }

    @Test func runCanBeRemapped() {
        let store = freshStore()
        store.setOverride(KeybindingBinding(key: "b", modifiers: [.command, .option]),
                          for: "run.play")
        #expect(store.resolved(for: "run.play")?.key.character == "b")
        #expect(store.resolved(for: "run.play")?.modifiers
                == [.command, .option])
        #expect(store.conflictingCommandIDs.isEmpty)
    }

    /// After a colliding remap, BOTH sides are flagged — the settings
    /// tab shows the clash instead of a `print()` nobody sees.
    @Test func aCollidingOverrideFlagsBothCommands() {
        let store = freshStore()
        store.setOverride(KeybindingBinding(key: "p", modifiers: [.command, .shift]),
                          for: "navigation.quickOpen")
        let clashing = store.conflictingCommandIDs
        #expect(clashing.contains("navigation.quickOpen"))
        #expect(clashing.contains("navigation.commandPalette"))
    }

    @Test func clearingTheOverrideClearsTheConflict() {
        let store = freshStore()
        store.setOverride(KeybindingBinding(key: "p", modifiers: [.command, .shift]),
                          for: "navigation.quickOpen")
        store.clearOverride(for: "navigation.quickOpen")
        #expect(store.conflictingCommandIDs.isEmpty)
    }

    // MARK: - Registry coverage

    /// Every command id the workspace / menu bar binds by must exist
    /// in the registry, or `resolved(for:)` returns nil and the
    /// shortcut silently disappears.
    @Test func everyBoundCommandIDIsRegistered() {
        let bound = [
            "navigation.commandPalette", "navigation.quickOpen",
            "navigation.findInProject", "search.findInFile",
            "navigation.closeTab", "editing.deleteFile",
            "navigation.nextTab", "navigation.previousTab",
            "navigation.symbolPalette", "panels.toggleTerminal",
            "navigation.goToDefinition", "navigation.hover",
            "editing.acceptCompletion", "editing.rename",
            "editing.formatDocument", "navigation.blame",
            "panels.toggleConsole", "panels.toggleTerminalPane",
            "panels.toggleTests", "run.tests",
        ]
        let known = Set(KeybindingRegistry.shared.map(\.id))
        for id in bound {
            #expect(known.contains(id), "unregistered command id: \(id)")
        }
    }

    @Test func registryIDsAreUnique() {
        let ids = KeybindingRegistry.shared.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    // MARK: - Serialisation

    @Test func bindingsRoundTripThroughTheirStoredForm() {
        let cases = [
            KeybindingBinding(key: "p", modifiers: [.command, .shift]),
            KeybindingBinding(key: .delete, modifiers: [.command]),
            KeybindingBinding(key: .space, modifiers: [.control]),
            KeybindingBinding(key: "]", modifiers: [.command, .shift, .option]),
        ]
        for binding in cases {
            let restored = KeybindingBinding(binding.serialised)
            #expect(restored?.key.character == binding.key.character)
            #expect(restored?.modifiers == binding.modifiers)
        }
    }

    @Test func aMalformedStoredBindingIsRejected() {
        #expect(KeybindingBinding("garbage") == nil)
        #expect(KeybindingBinding("cmd|") == nil)
    }
}
