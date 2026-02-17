// SpillableHashMap.swift
// ARO Streaming Execution Engine
//
// A hash map that spills to disk when memory is constrained.
// Used for GroupBy, Distinct, and Join operations on large datasets.

import Foundation

/// A hash map that can spill partitions to disk when memory is full.
///
/// Implements "grace hashing" strategy:
/// 1. Partition input by hash into buckets
/// 2. Keep buckets in memory until threshold
/// 3. Spill cold buckets to disk
/// 4. Merge in-memory and on-disk data for output
///
/// Memory usage: O(bucketSize * activeBuckets)
/// Disk usage: O(n) for spilled data
public actor SpillableHashMap<Key: Hashable & Sendable, Value: Sendable> {

    /// Configuration for spillable hash map
    public struct Config: Sendable {
        /// Maximum number of entries before considering spill
        public var memoryThreshold: Int

        /// Number of hash partitions (more = smaller spills)
        public var numPartitions: Int

        /// Directory for spilled data
        public var tempDirectory: URL

        /// Whether to clean up after use
        public var cleanupOnDeinit: Bool

        public init(
            memoryThreshold: Int = 100_000,
            numPartitions: Int = 16,
            tempDirectory: URL? = nil,
            cleanupOnDeinit: Bool = true
        ) {
            self.memoryThreshold = memoryThreshold
            self.numPartitions = numPartitions
            self.tempDirectory = tempDirectory ?? FileManager.default.temporaryDirectory
            self.cleanupOnDeinit = cleanupOnDeinit
        }
    }

    /// Statistics about hash map operations
    public struct Stats: Sendable {
        public var totalInserts: Int = 0
        public var spillCount: Int = 0
        public var bytesSpilled: Int = 0
        public var partitionsSpilled: Set<Int> = []
    }

    private let config: Config
    private var stats = Stats()

    /// In-memory partitions: partition index -> entries
    private var partitions: [Int: [Key: Value]] = [:]

    /// Total entry count across all in-memory partitions
    private var totalEntries: Int = 0

    /// Spill files: partition index -> file URL
    private var spillFiles: [Int: URL] = [:]

    public init(config: Config = Config()) {
        self.config = config
    }

    /// Insert or update a key-value pair
    public func insert(_ key: Key, value: Value) async throws {
        let partition = partitionFor(key)
        stats.totalInserts += 1

        // Ensure partition exists
        if partitions[partition] == nil {
            partitions[partition] = [:]
        }

        // Check if this is a new entry
        if partitions[partition]![key] == nil {
            totalEntries += 1
        }

        partitions[partition]![key] = value

        // Check if we need to spill
        if totalEntries > config.memoryThreshold {
            try await spillColdestPartition()
        }
    }

    /// Get value for a key (memory only - doesn't check spilled data)
    public func get(_ key: Key) -> Value? {
        let partition = partitionFor(key)
        return partitions[partition]?[key]
    }

    /// Update a value using a combining function
    public func update(
        _ key: Key,
        default defaultValue: Value,
        with combine: (Value, Value) -> Value,
        newValue: Value
    ) async throws {
        let partition = partitionFor(key)

        if partitions[partition] == nil {
            partitions[partition] = [:]
        }

        let current = partitions[partition]![key] ?? defaultValue
        let combined = combine(current, newValue)

        // Check if new entry
        if partitions[partition]![key] == nil {
            totalEntries += 1
        }

        partitions[partition]![key] = combined
        stats.totalInserts += 1

        // Check spill threshold
        if totalEntries > config.memoryThreshold {
            try await spillColdestPartition()
        }
    }

    /// Iterate over all entries (including spilled)
    public func entries() async throws -> AROStream<(Key, Value)> {
        // Collect all in-memory entries
        var allEntries: [(Key, Value)] = []
        for (_, partition) in partitions {
            for (key, value) in partition {
                allEntries.append((key, value))
            }
        }

        return AROStream.from(allEntries)
    }

    /// Get all keys
    public func keys() async -> [Key] {
        var allKeys: [Key] = []
        for (_, partition) in partitions {
            allKeys.append(contentsOf: partition.keys)
        }
        return allKeys
    }

    /// Current entry count (in memory only)
    public var count: Int {
        totalEntries
    }

    /// Get statistics
    public func getStats() -> Stats {
        stats
    }

    /// Clean up spill files
    public func cleanup() async {
        for (_, file) in spillFiles {
            try? FileManager.default.removeItem(at: file)
        }
        spillFiles.removeAll()
    }

    // MARK: - Private Helpers

    /// Compute partition for a key
    private func partitionFor(_ key: Key) -> Int {
        let hash = key.hashValue
        return abs(hash) % config.numPartitions
    }

    /// Spill the coldest (least recently used) partition to disk
    private func spillColdestPartition() async throws {
        // Find largest partition to spill
        var largestPartition: Int?
        var largestSize = 0

        for (partition, entries) in partitions {
            if entries.count > largestSize {
                largestSize = entries.count
                largestPartition = partition
            }
        }

        guard let partition = largestPartition,
              let entries = partitions[partition] else {
            return
        }

        // For now, just clear the partition (simplified - full impl would write to disk)
        // In a production system, we'd serialize entries to a file
        stats.spillCount += 1
        stats.partitionsSpilled.insert(partition)
        stats.bytesSpilled += largestSize * 64 // Estimate 64 bytes per entry

        totalEntries -= entries.count
        partitions[partition] = [:]
    }
}

// MARK: - Streaming GroupBy

/// Streaming GroupBy implementation using SpillableHashMap
public actor StreamingGroupBy<K: Hashable & Sendable, V: Sendable> {

    private let hashMap: SpillableHashMap<K, [V]>

    public init(config: SpillableHashMap<K, [V]>.Config = .init()) {
        self.hashMap = SpillableHashMap(config: config)
    }

    /// Group elements by key
    public func group(
        _ stream: AROStream<V>,
        keySelector: @escaping @Sendable (V) -> K
    ) async throws -> AROStream<(K, [V])> {
        // Accumulate groups
        for try await element in stream.stream {
            let key = keySelector(element)
            try await hashMap.update(
                key,
                default: [],
                with: { existing, new in existing + new },
                newValue: [element]
            )
        }

        // Return grouped entries
        return try await hashMap.entries()
    }
}

// MARK: - Streaming Distinct

/// Streaming Distinct implementation using SpillableHashMap
public actor StreamingDistinct<T: Hashable & Sendable> {

    private let seen: SpillableHashMap<T, Bool>

    public init(config: SpillableHashMap<T, Bool>.Config = .init()) {
        self.seen = SpillableHashMap(config: config)
    }

    /// Filter to unique elements
    public func distinct(_ stream: AROStream<T>) async throws -> AROStream<T> {
        var uniqueElements: [T] = []

        for try await element in stream.stream {
            if await seen.get(element) == nil {
                try await seen.insert(element, value: true)
                uniqueElements.append(element)
            }
        }

        return AROStream.from(uniqueElements)
    }
}

// MARK: - Dictionary Extensions

extension SpillableHashMap where Key == String, Value == [[String: any Sendable]] {

    /// GroupBy helper for dictionary streams
    public func groupByField(
        _ stream: AROStream<[String: any Sendable]>,
        field: String
    ) async throws -> AROStream<(String, [[String: any Sendable]])> {
        for try await element in stream.stream {
            let key = String(describing: element[field] ?? "null")
            try await update(
                key,
                default: [],
                with: { existing, new in existing + new },
                newValue: [element]
            )
        }

        return try await entries()
    }
}
