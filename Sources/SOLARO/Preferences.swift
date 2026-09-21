// ============================================================
// Preferences.swift
// SOLARO — one place that knows what is persisted (#776)
// ============================================================
//
// `SolaroPrefs` is a string enum of the keys, which is half the job. The
// other half was missing: nothing enumerated what SOLARO actually
// stores, every read respecified its own default, and two keys escaped
// the enum entirely — the keybinding overrides under a literal
// `"solaro.keybindings.overrides"`, and the marketplace token, which
// has since moved to the Keychain (#745).
//
// That matters more here than it usually would, because the book tells
// users to inspect their settings with `defaults export
// com.arolang.SOLARO`. A key nobody can enumerate is a key nobody can
// explain.
//
// This is the typed face of those keys: one property per preference,
// one definition of each default, and a description of the whole set
// for the settings UI and for anyone answering "what does this app
// keep". `@AppStorage` call sites in views stay as they are — SwiftUI
// needs the property wrapper — but they and this file now agree on the
// defaults, and a test asserts it.

import Foundation

/// Typed access to everything SOLARO persists in `UserDefaults`.
///
/// Not actor-isolated: `UserDefaults` is thread-safe, and the read that
/// prompted this — resolving the `aro` binary — happens off the main
/// actor. Isolating this would have pushed that call back onto raw
/// strings, which is the thing being fixed.
enum Preferences {

    private static var defaults: UserDefaults { .standard }

    // MARK: - Editor

    static var editorFontSize: Double {
        number(.editorFontSize) ?? Defaults.editorFontSize
    }
    static var editorLineHeight: Double {
        number(.editorLineHeight) ?? Defaults.editorLineHeight
    }
    static var formatOnSave: Bool { flag(.formatOnSave) }
    static var editorGhostText: Bool { flag(.editorGhostText) }
    static var editorGhostDelay: Double {
        number(.editorGhostDelay) ?? Defaults.editorGhostDelay
    }
    static var editorAIFallback: Bool { flag(.editorAIFallback) }
    static var editorMinimap: Bool { flag(.editorMinimap) }
    static var editorFolded: Bool { flag(.editorFolded) }

    // MARK: - Notebooks

    static var notebookStripOutputs: Bool { flag(.notebookStripOutputs) }

    // MARK: - Runtime and tooling

    /// Path to an `aro` binary that overrides discovery. Empty means
    /// "find one", which is what `ConsoleProcess.resolveAroBinary` does.
    static var aroOverride: String { text(.aroOverride) ?? "" }
    static var askEndpoint: String { text(.askEndpoint) ?? "" }

    // MARK: - Build (#763)

    static var buildOptimize: Bool { flag(.buildOptimize) }

    // MARK: - Signing

    static var signingTeamID: String { text(.signingTeamID) ?? "" }
    static var signingIdentitySHA1: String { text(.signingIdentity) ?? "" }

    // MARK: - Keybindings (#776)

    /// Recorded shortcut overrides, as stored JSON.
    ///
    /// This lived under a literal string inside `Keybindings.swift` and
    /// was the clearest case of a key nobody could enumerate.
    static var keybindingOverrides: Data? {
        get { defaults.data(forKey: SolaroPrefs.keybindingOverrides.rawValue) }
        set {
            if let newValue {
                defaults.set(newValue,
                             forKey: SolaroPrefs.keybindingOverrides.rawValue)
            } else {
                defaults.removeObject(
                    forKey: SolaroPrefs.keybindingOverrides.rawValue)
            }
        }
    }

    // MARK: - Defaults

    /// Every non-false default, in one place.
    ///
    /// A `Bool` preference defaults to false because that is what
    /// `UserDefaults` answers for a key it has never seen, and
    /// pretending otherwise at one read site and not another is how the
    /// two disagree.
    enum Defaults {
        static let editorFontSize: Double = 13
        static let editorLineHeight: Double = 1.35
        static let editorGhostDelay: Double = 0.75
    }

    // MARK: - Describing what is kept

    /// One line per stored key, for the settings UI and for answering
    /// "what does this app keep about me".
    ///
    /// Secrets are not listed because they are not here: the GitHub
    /// token lives in the Keychain (#745).
    static func describeStoredKeys() -> [(key: String, value: String)] {
        SolaroPrefs.allCases.compactMap { pref in
            guard let value = defaults.object(forKey: pref.rawValue) else {
                return nil
            }
            return (pref.rawValue, String(describing: value))
        }
    }

    // MARK: - Reading

    private static func flag(_ key: SolaroPrefs) -> Bool {
        defaults.bool(forKey: key.rawValue)
    }

    private static func number(_ key: SolaroPrefs) -> Double? {
        // `double(forKey:)` answers 0 for a missing key, which is a
        // legitimate font size to nobody. Check presence first so the
        // documented default wins.
        guard defaults.object(forKey: key.rawValue) != nil else { return nil }
        let value = defaults.double(forKey: key.rawValue)
        return value == 0 ? nil : value
    }

    private static func text(_ key: SolaroPrefs) -> String? {
        defaults.string(forKey: key.rawValue)
    }
}
