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

    /// Item evicted due to maxSize cap (nil when no eviction occurred)
    public let evictedItem: (any Sendable)?

    public init(
        storedValue: any Sendable,
        oldValue: (any Sendable)?,
        isUpdate: Bool,
        entityId: String?,
        evictedItem: (any Sendable)? = nil
    ) {
        self.storedValue = storedValue
        self.oldValue = oldValue
        self.isUpdate = isUpdate
        self.entityId = entityId
        self.evictedItem = evictedItem
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

    /// Get the count of items in a repository
    /// - Parameters:
    ///   - repository: Repository name
    ///   - businessActivity: The business activity scope
    /// - Returns: Number of items in the repository
    func count(repository: String, businessActivity: String) async -> Int

    /// Configure TTL and/or maxSize for a repository
    /// - Parameters:
    ///   - repository: Repository name
    ///   - ttl: Time-to-live in seconds (nil = no expiry)
    ///   - maxSize: Maximum item count; oldest item evicted when exceeded (nil = unlimited)
    func configure(repository: String, ttl: TimeInterval?, maxSize: Int?) async
}

/// Storage key for repository name only (repositories are application-scoped)
private struct StorageKey: Hashable, Sendable {
    let repository: String
}

/// Actor-based storage backend with O(1) indexed access
///
/// Storage model per repository key:
///   rows[key]:       rowId → value          (O(1) by rowId)
///   order[key]:      [rowId] in insert order (O(n) full scan, O(1) append)
///   nextRowId[key]:  monotonic row counter
///   idIndex[key]:    entity "id" → rowId    (O(1) by entity id)
///   fieldIndex[key]: field → canonValue → Set<rowId>  (O(1) filtered lookup)
/// Per-repository memory constraints
private struct RepositoryConfig: Sendable {
    /// Maximum number of items. When exceeded the oldest item is evicted (FIFO).
    var maxSize: Int?
    /// Time-to-live in seconds. Items older than this are invisible to Retrieve.
    var ttl: TimeInterval?
}

private actor RepositoryStorageActor {
    private var rows:       [StorageKey: [Int: any Sendable]]               = [:]
    private var order:      [StorageKey: [Int]]                             = [:]
    private var nextRowId:  [StorageKey: Int]                               = [:]
    private var idIndex:    [StorageKey: [String: Int]]                     = [:]
    private var fieldIndex: [StorageKey: [String: [String: Set<Int>]]]      = [:]

    /// Per-repository configuration (TTL, maxSize)
    private var configs:    [StorageKey: RepositoryConfig]                  = [:]
    /// Insertion timestamps for TTL evaluation
    private var timestamps: [StorageKey: [Int: Date]]                       = [:]

    /// Application-scope exported repositories
    private var applicationScope: [String: StorageKey] = [:]

    // MARK: - Initialise per-key structures

    private func ensureKey(_ key: StorageKey) {
        if rows[key] == nil {
            rows[key]       = [:]
            order[key]      = []
            nextRowId[key]  = 0
            idIndex[key]    = [:]
            fieldIndex[key] = [:]
            timestamps[key] = [:]
        }
    }

    // MARK: - Index helpers

    /// Type-tagged canonical key for field index lookups
    private func indexKey(for value: any Sendable) -> String {
        if let s = value as? String  { return "s:\(s)" }
        if let i = value as? Int     { return "i:\(i)" }
        if let d = value as? Double  { return "d:\(d)" }
        if let b = value as? Bool    { return "b:\(b)" }
        return "x:\(String(describing: value))"
    }

    /// Add all field entries for a row to the field index
    private func addToIndex(rowId: Int, value: any Sendable, key: StorageKey) {
        if let dict = value as? [String: any Sendable] {
            for (field, fieldValue) in dict {
                let ik = indexKey(for: fieldValue)
                if fieldIndex[key]![field] == nil            { fieldIndex[key]![field] = [:] }
                if fieldIndex[key]![field]![ik] == nil       { fieldIndex[key]![field]![ik] = [] }
                fieldIndex[key]![field]![ik]!.insert(rowId)
            }
        } else {
            let ik = indexKey(for: value)
            if fieldIndex[key]!["_value"] == nil             { fieldIndex[key]!["_value"] = [:] }
            if fieldIndex[key]!["_value"]![ik] == nil        { fieldIndex[key]!["_value"]![ik] = [] }
            fieldIndex[key]!["_value"]![ik]!.insert(rowId)
        }
    }

    /// Remove all field entries for a row from the field index
    private func removeFromIndex(rowId: Int, value: any Sendable, key: StorageKey) {
        if let dict = value as? [String: any Sendable] {
            for (field, fieldValue) in dict {
                let ik = indexKey(for: fieldValue)
                fieldIndex[key]?[field]?[ik]?.remove(rowId)
            }
        } else {
            let ik = indexKey(for: value)
            fieldIndex[key]?["_value"]?[ik]?.remove(rowId)
        }
    }

    // MARK: - Core operations
    //
    // Each public method resolves the StorageKey internally so that key
    // resolution and the subsequent mutation happen in a single actor turn.
    // This eliminates the TOCTOU window that would exist if the caller called
    // resolveKey() in one await and the operation in a second await — between
    // those two turns another task could call export() and remap applicationScope.
    //
    // ATOMIC: do not split resolveKey + operation across two actor awaits.

    func store(value: any Sendable, repository: String, businessActivity: String) -> RepositoryStoreResult {
        // ATOMIC: key resolution and mutation in one actor turn
        let key = resolveKey(repository: repository, businessActivity: businessActivity)
        ensureKey(key)

        var valueToStore = value
        var entityId: String? = nil

        if var dict = value as? [String: any Sendable] {

            // --- Upsert by identity field (name or key, without id) ---
            let identityField: String?
            if dict["name"] != nil      { identityField = "name" }
            else if dict["key"] != nil  { identityField = "key" }
            else                        { identityField = nil }

            if let identityField = identityField,
               let identityValue = dict[identityField],
               dict["id"] == nil {
                let ik = indexKey(for: identityValue)
                if let rowIds = fieldIndex[key]?[identityField]?[ik],
                   let rowId = rowIds.first,
                   let existingDict = rows[key]?[rowId] as? [String: any Sendable],
                   let existingId = existingDict["id"] {
                    let oldValue = rows[key]![rowId]!
                    dict["id"] = existingId
                    valueToStore = dict
                    entityId = existingId as? String

                    removeFromIndex(rowId: rowId, value: oldValue, key: key)
                    rows[key]![rowId] = valueToStore
                    addToIndex(rowId: rowId, value: valueToStore, key: key)
                    if let eid = entityId { idIndex[key]![eid] = rowId }

                    return RepositoryStoreResult(storedValue: valueToStore, oldValue: oldValue, isUpdate: true, entityId: entityId)
                }
            }

            // --- Ensure id exists ---
            if dict["id"] == nil {
                let generatedId = UUID().uuidString
                dict["id"] = generatedId
                valueToStore = dict
                entityId = generatedId
            } else {
                entityId = dict["id"] as? String
            }

            // --- Upsert by id ---
            if let eid = entityId, let existingRowId = idIndex[key]?[eid] {
                let oldValue = rows[key]![existingRowId]!

                if let newDict = valueToStore as? [String: any Sendable],
                   let oldDict = oldValue as? [String: any Sendable],
                   dictionariesEqual(newDict, oldDict) {
                    // No-op: identical value already stored
                    return RepositoryStoreResult(storedValue: valueToStore, oldValue: nil, isUpdate: true, entityId: entityId)
                }

                removeFromIndex(rowId: existingRowId, value: oldValue, key: key)
                rows[key]![existingRowId] = valueToStore
                addToIndex(rowId: existingRowId, value: valueToStore, key: key)
                // idIndex[key]![eid] already maps to existingRowId

                return RepositoryStoreResult(storedValue: valueToStore, oldValue: oldValue, isUpdate: true, entityId: entityId)
            }

            // --- New dict row ---
            let rowId = nextRowId[key]!
            nextRowId[key]! += 1
            rows[key]![rowId] = valueToStore
            order[key]!.append(rowId)
            timestamps[key]![rowId] = Date()
            addToIndex(rowId: rowId, value: valueToStore, key: key)
            if let eid = entityId { idIndex[key]![eid] = rowId }

            let evicted = evictOldestIfNeeded(key: key)
            return RepositoryStoreResult(storedValue: valueToStore, oldValue: nil, isUpdate: false, entityId: entityId, evictedItem: evicted)

        } else {
            // --- Plain value — deduplicate via field index ---
            let ik = indexKey(for: value)
            if let existing = fieldIndex[key]?["_value"]?[ik], !existing.isEmpty {
                return RepositoryStoreResult(storedValue: value, oldValue: value, isUpdate: true, entityId: nil)
            }

            let rowId = nextRowId[key]!
            nextRowId[key]! += 1
            rows[key]![rowId] = value
            order[key]!.append(rowId)
            timestamps[key]![rowId] = Date()
            addToIndex(rowId: rowId, value: value, key: key)

            let evicted = evictOldestIfNeeded(key: key)
            return RepositoryStoreResult(storedValue: value, oldValue: nil, isUpdate: false, entityId: nil, evictedItem: evicted)
        }
    }

    /// Evict the oldest row if maxSize is set and exceeded. Returns the evicted value.
    private func evictOldestIfNeeded(key: StorageKey) -> (any Sendable)? {
        guard let maxSize = configs[key]?.maxSize,
              let currentOrder = order[key],
              currentOrder.count > maxSize,
              let oldestRowId = currentOrder.first,
              let oldestValue = rows[key]?[oldestRowId] else { return nil }

        removeFromIndex(rowId: oldestRowId, value: oldestValue, key: key)
        rows[key]!.removeValue(forKey: oldestRowId)
        timestamps[key]?.removeValue(forKey: oldestRowId)
        if let dict = oldestValue as? [String: any Sendable], let eid = dict["id"] as? String {
            idIndex[key]?.removeValue(forKey: eid)
        }
        order[key] = Array(currentOrder.dropFirst())
        return oldestValue
    }

    func retrieve(repository: String, businessActivity: String) -> [any Sendable] {
        // ATOMIC: key resolution and read in one actor turn
        let key = resolveKey(repository: repository, businessActivity: businessActivity)
        guard let rowOrder = order[key], let rowMap = rows[key] else { return [] }
        let ttl = configs[key]?.ttl
        return rowOrder.compactMap { rowId -> (any Sendable)? in
            guard let value = rowMap[rowId] else { return nil }
            if let ttl, let ts = timestamps[key]?[rowId], Date().timeIntervalSince(ts) > ttl { return nil }
            return value
        }
    }

    func retrieveFiltered(repository: String, businessActivity: String, field: String, matchValue: any Sendable) -> [any Sendable] {
        // ATOMIC: key resolution and read in one actor turn
        let key = resolveKey(repository: repository, businessActivity: businessActivity)
        guard let rowOrder = order[key], let rowMap = rows[key] else { return [] }
        let ttl = configs[key]?.ttl

        let ik = indexKey(for: matchValue)
        guard let rowIds = fieldIndex[key]?[field]?[ik], !rowIds.isEmpty else { return [] }

        return rowOrder.filter { rowIds.contains($0) }.compactMap { rowId -> (any Sendable)? in
            guard let value = rowMap[rowId] else { return nil }
            if let ttl, let ts = timestamps[key]?[rowId], Date().timeIntervalSince(ts) > ttl { return nil }
            return value
        }
    }

    func export(key: StorageKey, as name: String) {
        applicationScope[name] = key
    }

    func exists(repository: String, businessActivity: String) -> Bool {
        // ATOMIC: key resolution and read in one actor turn
        let key = resolveKey(repository: repository, businessActivity: businessActivity)
        return !(order[key]?.isEmpty ?? true)
    }

    func count(repository: String, businessActivity: String) -> Int {
        // ATOMIC: key resolution and read in one actor turn
        let key = resolveKey(repository: repository, businessActivity: businessActivity)
        return order[key]?.count ?? 0
    }

    func configure(key: StorageKey, ttl: TimeInterval?, maxSize: Int?) {
        configs[key] = RepositoryConfig(maxSize: maxSize, ttl: ttl)
    }

    func clear(repository: String, businessActivity: String) {
        // ATOMIC: key resolution and mutation in one actor turn
        let key = resolveKey(repository: repository, businessActivity: businessActivity)
        rows[key]       = nil
        order[key]      = nil
        nextRowId[key]  = nil
        idIndex[key]    = nil
        fieldIndex[key] = nil
        timestamps[key] = nil
    }

    func delete(repository: String, businessActivity: String, field: String, matchValue: any Sendable) -> RepositoryDeleteResult {
        // ATOMIC: key resolution and mutation in one actor turn
        let key = resolveKey(repository: repository, businessActivity: businessActivity)
        let ik = indexKey(for: matchValue)
        // Capture set before any mutations
        guard let rowIdsToDelete = fieldIndex[key]?[field]?[ik], !rowIdsToDelete.isEmpty else {
            return RepositoryDeleteResult(deletedItems: [])
        }

        var deletedItems: [any Sendable] = []
        for rowId in rowIdsToDelete {
            guard let val = rows[key]?[rowId] else { continue }
            deletedItems.append(val)
            removeFromIndex(rowId: rowId, value: val, key: key)
            rows[key]!.removeValue(forKey: rowId)
            if let dict = val as? [String: any Sendable], let eid = dict["id"] as? String {
                idIndex[key]?.removeValue(forKey: eid)
            }
        }
        order[key] = order[key]?.filter { !rowIdsToDelete.contains($0) }

        return RepositoryDeleteResult(deletedItems: deletedItems)
    }

    func findById(repository: String, businessActivity: String, id: String) -> (any Sendable)? {
        // ATOMIC: key resolution and read in one actor turn
        let key = resolveKey(repository: repository, businessActivity: businessActivity)
        guard let rowId = idIndex[key]?[id] else { return nil }
        return rows[key]?[rowId]
    }

    private func resolveKey(repository: String, businessActivity: String) -> StorageKey {
        if let exportedKey = applicationScope[repository] {
            return exportedKey
        }
        return StorageKey(repository: repository)
    }

    func allRepositories() -> [(repository: String, count: Int)] {
        return order.map { (key, rowIds) in
            (repository: key.repository, count: rowIds.count)
        }
    }

    func clearAll() {
        rows.removeAll()
        order.removeAll()
        nextRowId.removeAll()
        idIndex.removeAll()
        fieldIndex.removeAll()
        timestamps.removeAll()
        configs.removeAll()
        applicationScope.removeAll()
    }

    // MARK: - Value comparison helpers

    private func isEqual(_ lhs: any Sendable, _ rhs: any Sendable) -> Bool {
        if let l = lhs as? String, let r = rhs as? String { return l == r }
        if let l = lhs as? Int,    let r = rhs as? Int    { return l == r }
        if let l = lhs as? Double, let r = rhs as? Double { return l == r }
        if let l = lhs as? Bool,   let r = rhs as? Bool   { return l == r }
        return String(describing: lhs) == String(describing: rhs)
    }

    private func dictionariesEqual(_ lhs: [String: any Sendable], _ rhs: [String: any Sendable]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (key, lhsValue) in lhs {
            guard let rhsValue = rhs[key] else { return false }
            if !isEqual(lhsValue, rhsValue) { return false }
        }
        return true
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
        let result = await actor.store(value: value, repository: repository, businessActivity: businessActivity)
        return result.storedValue
    }

    public func storeWithChangeInfo(value: any Sendable, in repository: String, businessActivity: String) async -> RepositoryStoreResult {
        let result = await actor.store(value: value, repository: repository, businessActivity: businessActivity)
        if let evicted = result.evictedItem {
            EventBus.shared.publish(RepositoryEvictedEvent(
                repositoryName: repository,
                evictedItem: evicted,
                reason: "maxSize"
            ))
        }
        return result
    }

    /// Configure TTL and/or maxSize for a repository.
    /// - Parameters:
    ///   - repository: Repository name
    ///   - ttl: Time-to-live in seconds (nil = no expiry)
    ///   - maxSize: Maximum item count; oldest item evicted when exceeded (nil = unlimited)
    public func configure(repository: String, ttl: TimeInterval?, maxSize: Int?) async {
        let key = StorageKey(repository: repository)
        await actor.configure(key: key, ttl: ttl, maxSize: maxSize)
    }

    public func retrieve(from repository: String, businessActivity: String) async -> [any Sendable] {
        return await actor.retrieve(repository: repository, businessActivity: businessActivity)
    }

    public func retrieve(
        from repository: String,
        businessActivity: String,
        where field: String,
        equals matchValue: any Sendable
    ) async -> [any Sendable] {
        return await actor.retrieveFiltered(repository: repository, businessActivity: businessActivity, field: field, matchValue: matchValue)
    }

    public func export(repository: String, from businessActivity: String, as name: String) async {
        let key = StorageKey(repository: repository)
        await actor.export(key: key, as: name)
    }

    public func exists(repository: String, businessActivity: String) async -> Bool {
        return await actor.exists(repository: repository, businessActivity: businessActivity)
    }

    public func clear(repository: String, businessActivity: String) async {
        await actor.clear(repository: repository, businessActivity: businessActivity)
    }

    public func delete(
        from repository: String,
        businessActivity: String,
        where field: String,
        equals value: any Sendable
    ) async -> RepositoryDeleteResult {
        return await actor.delete(repository: repository, businessActivity: businessActivity, field: field, matchValue: value)
    }

    public func findById(in repository: String, businessActivity: String, id: String) async -> (any Sendable)? {
        return await actor.findById(repository: repository, businessActivity: businessActivity, id: id)
    }

    public func count(repository: String, businessActivity: String) async -> Int {
        return await actor.count(repository: repository, businessActivity: businessActivity)
    }

    /// Get count synchronously (for compiled binary when guards)
    /// Uses a semaphore to block until the async operation completes
    public func countSync(repository: String, businessActivity: String) -> Int {
        final class Box: @unchecked Sendable { var value: Int = 0 }
        let result = Box()
        let semaphore = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .userInitiated).async {
            Task {
                result.value = await self.count(repository: repository, businessActivity: businessActivity)
                semaphore.signal()
            }
        }

        semaphore.wait()
        return result.value
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
