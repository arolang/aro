// RingBuffer.swift
// ARO Streaming Execution Engine
//
// A bounded circular buffer for multi-consumer stream buffering.

import Foundation

/// A thread-safe, bounded circular buffer for buffering stream elements.
///
/// Used by `StreamTee` to allow multiple consumers to read from the same stream.
/// When the buffer is full and all consumers have read past an element, that
/// element is discarded to make room for new elements.
///
/// Memory: O(capacity) - fixed size regardless of stream length.
public actor RingBuffer<Element: Sendable> {

    /// The underlying storage
    private var storage: [Element?]

    /// Index of the first valid element (oldest)
    private var head: Int = 0

    /// Index where the next element will be written
    private var tail: Int = 0

    /// Number of elements currently in the buffer
    private var _count: Int = 0

    /// The logical index of the first element (for consumer tracking)
    private var baseIndex: Int = 0

    /// Maximum number of elements the buffer can hold
    public let capacity: Int

    /// Number of elements currently buffered
    public var count: Int { _count }

    /// Whether the buffer is empty
    public var isEmpty: Bool { _count == 0 }

    /// Whether the buffer is full
    public var isFull: Bool { _count == capacity }

    /// The logical index of the first available element
    public var firstIndex: Int { baseIndex }

    /// The logical index of the next element to be written
    public var nextIndex: Int { baseIndex + _count }

    /// Create a ring buffer with the specified capacity
    public init(capacity: Int = 1024) {
        precondition(capacity > 0, "RingBuffer capacity must be positive")
        self.capacity = capacity
        self.storage = Array(repeating: nil, count: capacity)
    }

    /// Append an element to the buffer
    ///
    /// If the buffer is full, this will block or fail depending on the mode.
    /// For StreamTee usage, we assume consumers keep up.
    public func append(_ element: Element) {
        storage[tail] = element
        tail = (tail + 1) % capacity
        if _count < capacity {
            _count += 1
        } else {
            // Buffer was full - we're overwriting the oldest element
            head = (head + 1) % capacity
            baseIndex += 1
        }
    }

    /// Get element at logical index (relative to baseIndex)
    ///
    /// Returns nil if the index is out of range or element has been evicted.
    public func element(at logicalIndex: Int) -> Element? {
        guard logicalIndex >= baseIndex else {
            // Element was evicted
            return nil
        }
        guard logicalIndex < baseIndex + _count else {
            // Element not yet available
            return nil
        }

        let offset = logicalIndex - baseIndex
        let physicalIndex = (head + offset) % capacity
        return storage[physicalIndex]
    }

    /// Check if an element at the given logical index is available
    public func isAvailable(at logicalIndex: Int) -> Bool {
        logicalIndex >= baseIndex && logicalIndex < baseIndex + _count
    }

    /// Check if an element at the given logical index was evicted
    public func wasEvicted(at logicalIndex: Int) -> Bool {
        logicalIndex < baseIndex
    }

    /// Trim elements that are no longer needed by any consumer
    ///
    /// Call this when the slowest consumer has advanced past certain elements.
    public func trimTo(minimumIndex: Int) {
        while baseIndex < minimumIndex && _count > 0 {
            storage[head] = nil
            head = (head + 1) % capacity
            _count -= 1
            baseIndex += 1
        }
    }

    /// Clear all elements
    public func clear() {
        storage = Array(repeating: nil, count: capacity)
        head = 0
        tail = 0
        _count = 0
        baseIndex = 0
    }

    /// Get all currently buffered elements (for debugging)
    public func allElements() -> [Element] {
        var result: [Element] = []
        for i in 0..<_count {
            let physicalIndex = (head + i) % capacity
            if let element = storage[physicalIndex] {
                result.append(element)
            }
        }
        return result
    }
}

// MARK: - Convenience Extensions

extension RingBuffer {
    /// Create a buffer with capacity based on expected element size
    ///
    /// - Parameter targetMemory: Target memory usage in bytes
    /// - Parameter elementSize: Estimated size of each element in bytes
    public static func withMemoryLimit(targetMemory: Int, elementSize: Int) -> RingBuffer<Element> {
        let capacity = max(16, targetMemory / max(1, elementSize))
        return RingBuffer(capacity: capacity)
    }

    /// Default buffer size for streaming operations (1MB assuming ~1KB per row)
    public static var defaultCapacity: Int { 1024 }

    /// Large buffer for high-throughput scenarios
    public static var largeCapacity: Int { 16384 }

    /// Small buffer for memory-constrained scenarios
    public static var smallCapacity: Int { 128 }
}
