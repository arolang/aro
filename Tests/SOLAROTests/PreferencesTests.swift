// ============================================================
// PreferencesTests.swift
// SOLARO — one place that knows what is persisted (GitLab #776)
// ============================================================
//
// SolaroPrefs listed the keys, which is half the job. Nothing
// enumerated what the app actually stores, every read respecified its
// own default, and the keybinding overrides lived under a literal
// string outside the enum — while the book tells users to inspect
// their settings with `defaults export`.

import Testing
import Foundation
@testable import SOLARO

@Suite("Preferences", .serialized)
struct PreferencesTests {

    private func withValue(_ value: Any?, for key: SolaroPrefs,
                           _ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: key.rawValue)
        if let value {
            defaults.set(value, forKey: key.rawValue)
        } else {
            defaults.removeObject(forKey: key.rawValue)
        }
        defer {
            if let previous { defaults.set(previous, forKey: key.rawValue) }
            else { defaults.removeObject(forKey: key.rawValue) }
        }
        try body()
    }

    @Test func everyKeyIsEnumerable() {
        // The point of the enum being CaseIterable: something can now
        // answer "what does this app keep".
        let keys = SolaroPrefs.allCases.map(\.rawValue)
        #expect(keys.count >= 20)
        #expect(Set(keys).count == keys.count, "duplicate preference key")
        for key in keys {
            #expect(key.hasPrefix("solaro."),
                    "\(key) is not namespaced to this app")
        }
    }

    @Test func theKeybindingKeyIsInTheEnum() {
        // It used to be a literal inside Keybindings.swift, which is
        // the clearest case of a key nobody could enumerate.
        #expect(SolaroPrefs.keybindingOverrides.rawValue
                == "solaro.keybindings.overrides")
        #expect(SolaroPrefs.allCases.contains(.keybindingOverrides))
    }

    @Test func amissingNumberFallsBackToTheDocumentedDefault() throws {
        // UserDefaults answers 0 for a key it has never seen, which is
        // a legitimate font size to nobody.
        try withValue(nil, for: .editorFontSize) {
            #expect(Preferences.editorFontSize
                    == Preferences.Defaults.editorFontSize)
        }
        try withValue(nil, for: .editorGhostDelay) {
            #expect(Preferences.editorGhostDelay
                    == Preferences.Defaults.editorGhostDelay)
        }
    }

    @Test func astoredNumberWins() throws {
        try withValue(17.0, for: .editorFontSize) {
            #expect(Preferences.editorFontSize == 17)
        }
    }

    @Test func aflagDefaultsToFalse() throws {
        try withValue(nil, for: .formatOnSave) {
            #expect(!Preferences.formatOnSave)
        }
        try withValue(true, for: .formatOnSave) {
            #expect(Preferences.formatOnSave)
        }
    }

    @Test func anUnsetStringReadsAsEmptyRatherThanNil() throws {
        // Every call site wanted "" and wrote its own `?? ""`.
        try withValue(nil, for: .aroOverride) {
            #expect(Preferences.aroOverride.isEmpty)
        }
        try withValue("/usr/local/bin/aro", for: .aroOverride) {
            #expect(Preferences.aroOverride == "/usr/local/bin/aro")
        }
    }

    @Test func describingStoredKeysListsOnlyWhatIsActuallySet() throws {
        try withValue(true, for: .formatOnSave) {
            let described = Preferences.describeStoredKeys()
            #expect(described.contains { $0.key == "solaro.formatOnSave" })
            // A key that was never written is not claimed as stored.
            let unset = SolaroPrefs.allCases.first {
                UserDefaults.standard.object(forKey: $0.rawValue) == nil
            }
            if let unset {
                #expect(!described.contains { $0.key == unset.rawValue })
            }
        }
    }

    @Test func noSecretIsAmongTheStoredKeys() {
        // The GitHub token moved to the Keychain (#745), and nothing
        // should quietly put one back into defaults.
        for key in SolaroPrefs.allCases.map(\.rawValue) {
            let lower = key.lowercased()
            #expect(!lower.contains("pat"))
            #expect(!lower.contains("token"))
            #expect(!lower.contains("secret"))
            #expect(!lower.contains("password"))
        }
    }
}
