// ============================================================
// RepositoryStorage.swift
// ARO Runtime - In-Memory Repository Storage Service
// ============================================================

import Foundation

// MARK: - Repository Store Result

/// Result of a repository store operation, including change tracking information
public struct RepositoryStoreResult: Sendable {
    /// The value that was stored (with auto-generated id if applicable)
    public let storedValue: any Sendable

    /// The old value if this was an update (nil for creates)
    public let oldValue: (any Sendable)?

    /// Whether this was an update (true) or create (false)
    public let isUpdate: Bool

    /// The entity ID if available
    public let entityId: String?

    public init(storedValue: any Sendable, oldValue: (any Sendable)?, isUpdate: Bool, entityId: String?) {
        self.storedValue = storedValue
        self.oldValue = oldValue
        self.isUpdate = isUpdate
        self.entityId = entityId
    }
}

/// Result of a repository delete operation
public struct RepositoryDeleteResult: Sendable {
    /// Items that were deleted
    public let deletedItems: [any Sendable]

    /// Number of items deleted
    public var count: Int { deletedItems.count }

    public init(deletedItems: [any Sendable]) {
        self.deletedItems = deletedItems
    }
}

// MARK: - Repository Storage Protocol

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
    /// - Returns: The stored value (with auto-generated id if applicable)
    @discardableResult
    func store(value: any Sendable, in repository: String, businessActivity: String) async -> any Sendable

    /// Store a value with change tracking information
    /// - Parameters:
    ///   - value: The value to store
    ///   - repository: Repository name (must end with -repository)
    ///   - businessActivity: The business activity scope
    /// - Returns: RepositoryStoreResult containing stored value, old value (if update), and change type
    func storeWithChangeInfo(value: any Sendable, in repository: String, businessActivity: String) async -> RepositoryStoreResult

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

    /// Delete items from a repository matching a condition
    /// - Parameters:
    ///   - repository: Repository name
    ///   - businessActivity: The business activity scope
    ///   - field: Field name to match
    ///   - value: Value to match against
    /// - Returns: RepositoryDeleteResult containing the deleted items
    func delete(
        from repository: String,
        businessActivity: String,
        where field: String,
        equals value: any Sendable
    ) async -> RepositoryDeleteResult

    /// Find an item by ID
    /// - Parameters:
    ///   - repository: Repository name
    ///   - businessActivity: The business activity scope
    ///   - id: The ID to search for
    /// - Returns: The item if found, nil otherwise
    func findById(in repository: String, businessActivity: String, id: String) async -> (any Sendable)?
}

/// Storage key for repository name only (repositories are application-scoped)
private struct StorageKey: Hashable, Sendable {
    let repository: String
}

/// Actor-based storage backend for thread-safe access
private actor RepositoryStorageActor {
    /// Repository data storage: [StorageKey: [any Sendable]]
    private var storage: [StorageKey: [any Sendable]] = [:]

    /// Application-scope exported repositories
    private var applicationScope: [String: StorageKey] = [:]

    func store(value: any Sendable, key: StorageKey) -> RepositoryStoreResult {
        if storage[key] == nil {
            storage[key] = []
        }

        // Handle dictionary values - ensure id exists and handle updates
        var valueToStore = value
        var entityId: String? = nil

        if var dict = value as? [String: any Sendable] {
            // First, check if we can find an existing entry by "name" to preserve its "id"
            if let name = dict["name"], dict["id"] == nil {
                if let existingIndex = storage[key]?.firstIndex(where: { existing in
                    if let existingDict = existing as? [String: any Sendable],
                       let existingName = existingDict["name"] {
                        return isEqual(existingName, name)
                    }
                    return false
                }), let existingDict = storage[key]?[existingIndex] as? [String: any Sendable],
                   let existingId = existingDict["id"] {
                    // Capture old value before update
                    let oldValue = storage[key]?[existingIndex]
                    // Use the existing entry's id
                    dict["id"] = existingId
                    valueToStore = dict
                    entityId = existingId as? String
                    // Update the existing entry
                    storage[key]?[existingIndex] = valueToStore
                    return RepositoryStoreResult(storedValue: valueToStore, oldValue: oldValue, isUpdate: true, entityId: entityId)
                }
            }

            // If no "id" field exists, generate one
            if dict["id"] == nil {
                let generatedId = UUID().uuidString
                dict["id"] = generatedId
                valueToStore = dict
                entityId = generatedId
            } else {
                entityId = dict["id"] as? String
            }
        } else {
            // Plain value (string, int, bool, etc.) - deduplicate
            // The Actor serializes all store calls, making this check atomic
            if let existing = storage[key], existing.contains(where: { isEqual($0, value) }) {
                return RepositoryStoreResult(storedValue: value, oldValue: value, isUpdate: true, entityId: nil)
            }
        }

        // Check if value has an "id" field - if so, try to update existing entry by id
        if let dict = valueToStore as? [String: any Sendable],
           let id = dict["id"] {
            entityId = id as? String
            if let index = storage[key]?.firstIndex(where: { existing in
                if let existingDict = existing as? [String: any Sendable],
                   let existingId = existingDict["id"] {
                    return isEqual(existingId, id)
                }
                return false
            }) {
                // Capture old value before update
                let oldValue = storage[key]?[index]
                // Update existing entry by id
                storage[key]?[index] = valueToStore
                return RepositoryStoreResult(storedValue: valueToStore, oldValue: oldValue, isUpdate: true, entityId: entityId)
            }
        }

        // For simple values (strings, numbers), check for duplicates before appending
        // This prevents the repository from growing with duplicate entries during parallel processing
        if let stringValue = valueToStore as? String {
            if storage[key]?.contains(where: { ($0 as? String) == stringValue }) == true {
                // Already exists - treat as no-op (idempotent)
                return RepositoryStoreResult(storedValue: valueToStore, oldValue: valueToStore, isUpdate: false, entityId: nil)
            }
        } else if let intValue = valueToStore as? Int {
            if storage[key]?.contains(where: { ($0 as? Int) == intValue }) == true {
                return RepositoryStoreResult(storedValue: valueToStore, oldValue: valueToStore, isUpdate: false, entityId: nil)
            }
        }

        // No matching entry found - append new value
        storage[key]?.append(valueToStore)

        return RepositoryStoreResult(storedValue: valueToStore, oldValue: nil, isUpdate: false, entityId: entityId)
    }

    func retrieve(key: StorageKey) -> [any Sendable] {
        let values = storage[key] ?? []
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
    }

    func exists(key: StorageKey) -> Bool {
        return storage[key] != nil && !(storage[key]?.isEmpty ?? true)
    }

    func clear(key: StorageKey) {
        storage[key] = nil
    }

    func resolveKey(repository: String, businessActivity: String) -> StorageKey {
        // Check if this repository is exported to application scope
        if let exportedKey = applicationScope[repository] {
            return exportedKey
        }
        // Repositories are now application-scoped (not business-activity-scoped)
        return StorageKey(repository: repository)
    }

    func allRepositories() -> [(repository: String, count: Int)] {
        return storage.map { (key, values) in
            (repository: key.repository, count: values.count)
        }
    }

    func clearAll() {
        storage.removeAll()
        applicationScope.removeAll()
    }

    func delete(key: StorageKey, field: String, matchValue: any Sendable) -> RepositoryDeleteResult {
        guard var values = storage[key] else {
            return RepositoryDeleteResult(deletedItems: [])
        }

        var deletedItems: [any Sendable] = []

        // Find and remove matching items
        values.removeAll { value in
            if let dict = value as? [String: any Sendable],
               let fieldValue = dict[field] {
                if isEqual(fieldValue, matchValue) {
                    deletedItems.append(value)
                    return true
                }
            }
            return false
        }

        storage[key] = values

        return RepositoryDeleteResult(deletedItems: deletedItems)
    }

    func findById(key: StorageKey, id: String) -> (any Sendable)? {
        guard let values = storage[key] else {
            return nil
        }

        return values.first { value in
            if let dict = value as? [String: any Sendable],
               let valueId = dict["id"] as? String {
                return valueId == id
            }
            return false
        }
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

    @discardableResult
    public func store(value: any Sendable, in repository: String, businessActivity: String) async -> any Sendable {
        let key = await actor.resolveKey(repository: repository, businessActivity: businessActivity)
        let result = await actor.store(value: value, key: key)
        return result.storedValue
    }

    public func storeWithChangeInfo(value: any Sendable, in repository: String, businessActivity: String) async -> RepositoryStoreResult {
        let key = await actor.resolveKey(repository: repository, businessActivity: businessActivity)
        return await actor.store(value: value, key: key)
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
        let key = StorageKey(repository: repository)
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

    public func delete(
        from repository: String,
        businessActivity: String,
        where field: String,
        equals value: any Sendable
    ) async -> RepositoryDeleteResult {
        let key = await actor.resolveKey(repository: repository, businessActivity: businessActivity)
        return await actor.delete(key: key, field: field, matchValue: value)
    }

    public func findById(in repository: String, businessActivity: String, id: String) async -> (any Sendable)? {
        let key = await actor.resolveKey(repository: repository, businessActivity: businessActivity)
        return await actor.findById(key: key, id: id)
    }

    // MARK: - Debug/Testing

    /// Get all repository names (for debugging)
    public func allRepositories() async -> [(repository: String, count: Int)] {
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
