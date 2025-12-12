// ============================================================
// RepositoryStorage.swift
// ARO Runtime - In-Memory Repository Storage Service
// ============================================================

import Foundation

/// Protocol for repository storage services
///
/// Repositories provide persistent in-memory storage that survives across
/// HTTP requests and event handlers. They are scoped to business activities
/// by default but can be exported to application scope.
public protocol RepositoryStorageService: Sendable {
    /// Store a value in a repository
    /// - Parameters:
    ///   - value: The value to store
    ///   - repository: Repository name (must end with -repository)
    ///   - businessActivity: The business activity scope
    func store(value: any Sendable, in repository: String, businessActivity: String) async

    /// Retrieve all values from a repository
    /// - Parameters:
    ///   - repository: Repository name
    ///   - businessActivity: The business activity scope
    /// - Returns: All stored values as a list
    func retrieve(from repository: String, businessActivity: String) async -> [any Sendable]

    /// Retrieve values matching a predicate
    /// - Parameters:
    ///   - repository: Repository name
    ///   - businessActivity: The business activity scope
    ///   - field: Field name to match
    ///   - value: Value to match against
    /// - Returns: Matching values
    func retrieve(
        from repository: String,
        businessActivity: String,
        where field: String,
        equals value: any Sendable
    ) async -> [any Sendable]

    /// Export a repository to application scope
    /// - Parameters:
    ///   - repository: Repository name to export
    ///   - businessActivity: Source business activity
    ///   - name: Name in application scope
    func export(repository: String, from businessActivity: String, as name: String) async

    /// Check if a repository exists
    /// - Parameters:
    ///   - repository: Repository name
    ///   - businessActivity: The business activity scope
    /// - Returns: true if the repository exists and has data
    func exists(repository: String, businessActivity: String) async -> Bool

    /// Clear all data from a repository
    /// - Parameters:
    ///   - repository: Repository name
    ///   - businessActivity: The business activity scope
    func clear(repository: String, businessActivity: String) async
}

/// Storage key combining business activity and repository name
private struct StorageKey: Hashable, Sendable {
    let businessActivity: String
    let repository: String
}

/// Actor-based storage backend for thread-safe access
private actor RepositoryStorageActor {
    /// Repository data storage: [StorageKey: [any Sendable]]
    private var storage: [StorageKey: [any Sendable]] = [:]

    /// Application-scope exported repositories
    private var applicationScope: [String: StorageKey] = [:]

    func store(value: any Sendable, key: StorageKey) {
        if storage[key] == nil {
            storage[key] = []
        }

        // Check if value has an "id" field - if so, update existing entry with same id
        if let dict = value as? [String: any Sendable],
           let id = dict["id"] {
            // Look for existing entry with same id
            if let index = storage[key]?.firstIndex(where: { existing in
                if let existingDict = existing as? [String: any Sendable],
                   let existingId = existingDict["id"] {
                    return isEqual(existingId, id)
                }
                return false
            }) {
                // Update existing entry
                storage[key]?[index] = value
                #if DEBUG
                print("[RepositoryStorage] Updated value with id '\(id)' in '\(key.repository)' (activity: '\(key.businessActivity)')")
                #endif
                return
            }
        }

        // No id or no matching entry - append new value
        storage[key]?.append(value)

        #if DEBUG
        print("[RepositoryStorage] Stored value in '\(key.repository)' (activity: '\(key.businessActivity)'). Count: \(storage[key]?.count ?? 0)")
        #endif
    }

    func retrieve(key: StorageKey) -> [any Sendable] {
        let values = storage[key] ?? []

        #if DEBUG
        print("[RepositoryStorage] Retrieved \(values.count) values from '\(key.repository)' (activity: '\(key.businessActivity)')")
        #endif

        return values
    }

    func retrieveFiltered(key: StorageKey, field: String, matchValue: any Sendable) -> [any Sendable] {
        guard let values = storage[key] else {
            return []
        }

        // Filter values that have matching field
        return values.filter { value in
            // Try to extract the field from the value
            if let dict = value as? [String: any Sendable],
               let fieldValue = dict[field] {
                return isEqual(fieldValue, matchValue)
            }
            return false
        }
    }

    func export(key: StorageKey, as name: String) {
        applicationScope[name] = key

        #if DEBUG
        print("[RepositoryStorage] Exported '\(key.repository)' from '\(key.businessActivity)' as '\(name)'")
        #endif
    }

    func exists(key: StorageKey) -> Bool {
        return storage[key] != nil && !(storage[key]?.isEmpty ?? true)
    }

    func clear(key: StorageKey) {
        storage[key] = nil

        #if DEBUG
        print("[RepositoryStorage] Cleared '\(key.repository)' (activity: '\(key.businessActivity)')")
        #endif
    }

    func resolveKey(repository: String, businessActivity: String) -> StorageKey {
        // Check if this repository is exported to application scope
        if let exportedKey = applicationScope[repository] {
            return exportedKey
        }
        return StorageKey(businessActivity: businessActivity, repository: repository)
    }

    func allRepositories() -> [(businessActivity: String, repository: String, count: Int)] {
        return storage.map { (key, values) in
            (businessActivity: key.businessActivity, repository: key.repository, count: values.count)
        }
    }

    func clearAll() {
        storage.removeAll()
        applicationScope.removeAll()
    }

    /// Compare two Sendable values for equality
    private func isEqual(_ lhs: any Sendable, _ rhs: any Sendable) -> Bool {
        // Compare strings
        if let l = lhs as? String, let r = rhs as? String {
            return l == r
        }
        // Compare integers
        if let l = lhs as? Int, let r = rhs as? Int {
            return l == r
        }
        // Compare doubles
        if let l = lhs as? Double, let r = rhs as? Double {
            return l == r
        }
        // Compare booleans
        if let l = lhs as? Bool, let r = rhs as? Bool {
            return l == r
        }
        // String comparison fallback
        return String(describing: lhs) == String(describing: rhs)
    }
}

/// In-memory implementation of RepositoryStorageService
///
/// Provides thread-safe storage for repositories scoped by business activity.
/// Data persists for the lifetime of the application but is not persisted to disk.
public final class InMemoryRepositoryStorage: RepositoryStorageService, Sendable {
    /// Actor for thread-safe storage
    private let actor = RepositoryStorageActor()

    /// Shared singleton instance
    public static let shared = InMemoryRepositoryStorage()

    public init() {}

    // MARK: - RepositoryStorageService

    public func store(value: any Sendable, in repository: String, businessActivity: String) async {
        let key = await actor.resolveKey(repository: repository, businessActivity: businessActivity)
        await actor.store(value: value, key: key)
    }

    public func retrieve(from repository: String, businessActivity: String) async -> [any Sendable] {
        let key = await actor.resolveKey(repository: repository, businessActivity: businessActivity)
        return await actor.retrieve(key: key)
    }

    public func retrieve(
        from repository: String,
        businessActivity: String,
        where field: String,
        equals matchValue: any Sendable
    ) async -> [any Sendable] {
        let key = await actor.resolveKey(repository: repository, businessActivity: businessActivity)
        return await actor.retrieveFiltered(key: key, field: field, matchValue: matchValue)
    }

    public func export(repository: String, from businessActivity: String, as name: String) async {
        let key = StorageKey(businessActivity: businessActivity, repository: repository)
        await actor.export(key: key, as: name)
    }

    public func exists(repository: String, businessActivity: String) async -> Bool {
        let key = await actor.resolveKey(repository: repository, businessActivity: businessActivity)
        return await actor.exists(key: key)
    }

    public func clear(repository: String, businessActivity: String) async {
        let key = await actor.resolveKey(repository: repository, businessActivity: businessActivity)
        await actor.clear(key: key)
    }

    // MARK: - Debug/Testing

    /// Get all repository names (for debugging)
    public func allRepositories() async -> [(businessActivity: String, repository: String, count: Int)] {
        return await actor.allRepositories()
    }

    /// Clear all repositories (for testing)
    public func clearAll() async {
        await actor.clearAll()
    }
}

// MARK: - Convenience Extension

extension InMemoryRepositoryStorage {
    /// Check if a name is a repository name (ends with -repository)
    public static func isRepositoryName(_ name: String) -> Bool {
        return name.hasSuffix("-repository")
    }
}
