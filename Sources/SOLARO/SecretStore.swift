// ============================================================
// SecretStore.swift
// SOLARO — credentials in the Keychain, not in defaults (#745)
// ============================================================
//
// The GitHub PAT lived in `UserDefaults` under `solaro.github.pat`. That is
// readable by any process running as the user, it lands in Time Machine
// backups, and the book itself tells users to inspect their settings with
// `defaults export com.arolang.SOLARO` — so the token was one documented
// command away from a terminal transcript.
//
// This is a small generic-password wrapper: one service, one account per
// secret, `kSecAttrAccessibleWhenUnlocked` so a locked Mac does not hand it
// over. Deliberately not a dependency — three SecItem calls are less code
// than wiring one in.

import Foundation
import Security

/// Credentials SOLARO holds on the user's behalf.
enum SecretStore {

    /// Keychain service name. One entry per `Key`.
    private static let service = "com.arolang.SOLARO"

    /// The secrets SOLARO stores. Adding a case is the whole registration.
    enum Key: String, CaseIterable {
        /// GitHub personal access token for the plugin marketplace, which
        /// raises the search rate limit from 60 to 5000 requests an hour.
        case githubPAT = "github.pat"
    }

    // MARK: - Reading and writing

    /// The stored secret, or `nil` when there is none.
    static func value(for key: Key) -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { return nil }
        return value
    }

    /// Store `value`, or remove the entry when it is empty.
    ///
    /// Empty means "the user cleared the field", which should delete the
    /// secret rather than store a blank one.
    @discardableResult
    static func set(_ value: String, for key: Key) -> Bool {
        guard !value.isEmpty else { return remove(key) }
        guard let data = value.data(using: .utf8) else { return false }

        let query = baseQuery(for: key)
        let attributes: [String: Any] = [kSecValueData as String: data]

        // Update first: the common path is replacing a token, and
        // SecItemAdd on an existing item fails with errSecDuplicateItem.
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }

        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func remove(_ key: Key) -> Bool {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func baseQuery(for key: Key) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
    }

    // MARK: - Migration

    /// Move a secret out of `UserDefaults` the first time it is read.
    ///
    /// Existing installs have the PAT in defaults; leaving it there while
    /// writing new ones to the Keychain would mean the old copy survives
    /// indefinitely in a file the user was told to export.
    static func migrateFromDefaults(_ key: Key, defaultsKey: String) {
        let defaults = UserDefaults.standard
        guard let legacy = defaults.string(forKey: defaultsKey),
              !legacy.isEmpty
        else { return }

        // Only adopt the legacy value when the Keychain has nothing, so a
        // token set after an upgrade is never overwritten by a stale one.
        if value(for: key) == nil {
            set(legacy, for: key)
        }
        defaults.removeObject(forKey: defaultsKey)
    }
}

/// A `UserDefaults`-shaped binding backed by the Keychain, so a SwiftUI
/// `SecureField` can bind to a secret without `@AppStorage`.
@MainActor
@Observable
final class SecretField {
    private let key: SecretStore.Key

    var value: String {
        didSet {
            guard value != oldValue else { return }
            SecretStore.set(value, for: key)
        }
    }

    init(_ key: SecretStore.Key, migratingFrom defaultsKey: String? = nil) {
        self.key = key
        if let defaultsKey {
            SecretStore.migrateFromDefaults(key, defaultsKey: defaultsKey)
        }
        self.value = SecretStore.value(for: key) ?? ""
    }
}
