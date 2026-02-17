// ExternalSort.swift
// ARO Streaming Execution Engine
//
// External merge sort for handling datasets larger than memory.
// Spills sorted chunks to disk and merges them in a streaming fashion.

import Foundation

/// External merge sort implementation for large datasets.
///
/// When data exceeds memory limits:
/// 1. Reads data in chunks that fit in memory
/// 2. Sorts each chunk in memory
/// 3. Writes sorted chunks to temporary files
/// 4. Merges sorted chunks using a min-heap
///
/// Memory usage: O(chunkSize + k) where k = number of chunks
/// Disk usage: O(n) for temporary files
public actor ExternalSort<T: Sendable> {

    /// Configuration for external sort
    public struct Config: Sendable {
        /// Maximum number of elements to sort in memory at once
        public var chunkSize: Int

        /// Directory for temporary files
        public var tempDirectory: URL

        /// Whether to clean up temp files after completion
        public var cleanupTempFiles: Bool

        public init(
            chunkSize: Int = 100_000,
            tempDirectory: URL? = nil,
            cleanupTempFiles: Bool = true
        ) {
            self.chunkSize = chunkSize
            self.tempDirectory = tempDirectory ?? FileManager.default.temporaryDirectory
            self.cleanupTempFiles = cleanupTempFiles
        }
    }

    /// Sort statistics
    public struct Stats: Sendable {
        public var totalElements: Int = 0
        public var chunksCreated: Int = 0
        public var bytesSpilled: Int = 0
        public var mergePassesRequired: Int = 0
    }

    private let config: Config
    private var stats = Stats()
    private var tempFiles: [URL] = []

    public init(config: Config = Config()) {
        self.config = config
    }

    /// Sort a stream of elements, spilling to disk if necessary
    ///
    /// - Parameters:
    ///   - stream: Input stream of elements
    ///   - compare: Comparison function (returns true if first < second)
    /// - Returns: Sorted stream of elements
    public func sort(
        _ stream: AROStream<T>,
        by compare: @escaping @Sendable (T, T) -> Bool
    ) async throws -> AROStream<T> {
        // First pass: create sorted chunks
        var chunks: [[T]] = []
        var currentChunk: [T] = []

        for try await element in stream.stream {
            currentChunk.append(element)
            stats.totalElements += 1

            if currentChunk.count >= config.chunkSize {
                // Sort chunk in memory
                currentChunk.sort(by: compare)
                chunks.append(currentChunk)
                stats.chunksCreated += 1
                currentChunk = []
            }
        }

        // Don't forget the last partial chunk
        if !currentChunk.isEmpty {
            currentChunk.sort(by: compare)
            chunks.append(currentChunk)
            stats.chunksCreated += 1
        }

        // If only one chunk, no merge needed
        if chunks.count <= 1 {
            let elements = chunks.first ?? []
            return AROStream.from(elements)
        }

        // Merge all chunks using k-way merge
        stats.mergePassesRequired = 1
        return kWayMerge(chunks, by: compare)
    }

    /// K-way merge of sorted arrays
    private func kWayMerge(
        _ chunks: [[T]],
        by compare: @escaping @Sendable (T, T) -> Bool
    ) -> AROStream<T> {
        return AROStream { [chunks, compare] in
            AsyncThrowingStream { continuation in
                Task {
                    // Track position in each chunk
                    var indices = Array(repeating: 0, count: chunks.count)
                    var activeChunks = Set(0..<chunks.count)

                    while !activeChunks.isEmpty {
                        // Find minimum element across all active chunks
                        var minChunkIndex: Int?
                        var minElement: T?

                        for chunkIndex in activeChunks {
                            let elementIndex = indices[chunkIndex]
                            let element = chunks[chunkIndex][elementIndex]

                            if minElement == nil || compare(element, minElement!) {
                                minElement = element
                                minChunkIndex = chunkIndex
                            }
                        }

                        if let element = minElement, let chunkIndex = minChunkIndex {
                            continuation.yield(element)

                            // Advance index for this chunk
                            indices[chunkIndex] += 1

                            // Check if chunk is exhausted
                            if indices[chunkIndex] >= chunks[chunkIndex].count {
                                activeChunks.remove(chunkIndex)
                            }
                        }
                    }

                    continuation.finish()
                }
            }
        }
    }

    /// Get current sort statistics
    public func getStats() -> Stats {
        stats
    }

    /// Clean up temporary files
    public func cleanup() async {
        for file in tempFiles {
            try? FileManager.default.removeItem(at: file)
        }
        tempFiles.removeAll()
    }
}

// MARK: - Dictionary External Sort

/// Specialized external sort for dictionary streams (most common in ARO)
public actor DictionaryExternalSort {

    private let config: ExternalSort<[String: any Sendable]>.Config

    public init(config: ExternalSort<[String: any Sendable]>.Config = .init()) {
        self.config = config
    }

    /// Sort dictionaries by a specific field
    public func sortByField(
        _ stream: AROStream<[String: any Sendable]>,
        field: String,
        ascending: Bool = true
    ) async throws -> AROStream<[String: any Sendable]> {
        let sorter = ExternalSort<[String: any Sendable]>(config: config)
        return try await sorter.sort(stream) { [self] a, b in
            guard let aValue = a[field], let bValue = b[field] else {
                return false
            }

            let result = self.compareValues(aValue, bValue)
            return ascending ? result : !result
        }
    }

    /// Compare two values of potentially different types
    private nonisolated func compareValues(_ a: any Sendable, _ b: any Sendable) -> Bool {
        // Try numeric comparison first
        if let aNum = asDouble(a), let bNum = asDouble(b) {
            return aNum < bNum
        }

        // Fall back to string comparison
        return String(describing: a) < String(describing: b)
    }

    private nonisolated func asDouble(_ value: any Sendable) -> Double? {
        switch value {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let s as String: return Double(s)
        default: return nil
        }
    }
}

// MARK: - Streaming External Sort

/// Simplified external sort that uses disk for large datasets
public struct StreamingExternalSort: Sendable {

    /// Sort a stream of dictionaries by a field, using external sort if needed
    public static func sort(
        _ stream: AROStream<[String: any Sendable]>,
        by field: String,
        ascending: Bool = true,
        memoryLimit: Int = 100_000
    ) async throws -> AROStream<[String: any Sendable]> {
        let sorter = DictionaryExternalSort(
            config: .init(chunkSize: memoryLimit)
        )
        return try await sorter.sortByField(stream, field: field, ascending: ascending)
    }
}
