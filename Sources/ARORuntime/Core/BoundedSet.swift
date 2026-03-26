// ============================================================
// BoundedSet.swift
// ARO Runtime - Bounded FIFO-evicting set
// ============================================================

import Foundation

// MARK: - BoundedSet

/// A `Set`-like container that evicts the oldest inserted element when
/// the capacity limit is exceeded (FIFO eviction).
///
/// Designed for visited-URL tracking in crawl-style workloads where an
/// unbounded set would exhaust memory over long runs.
///
/// Insertion of an element already present is a no-op (the element is
/// NOT moved to "newest" position — use a proper LRU cache if recency
/// matters).
///
/// - Complexity: `contains` is O(1); `insert` is amortised O(1) plus
///   O(n) for the eviction step (array `removeFirst`). For `maxSize`
///   values up to ~100 000 the eviction cost is < 1 ms and acceptable.
///   If profiling shows this hot, replace the `[Element]` order array
///   with a doubly-linked-list or a `Deque` from swift-collections.
struct BoundedSet<Element: Hashable> {
    private var storage: Set<Element> = []
    private var order: [Element] = []   // insertion order for FIFO eviction

    /// Maximum number of elements retained before eviction begins.
    let maxSize: Int

    init(maxSize: Int) {
        precondition(maxSize > 0, "BoundedSet maxSize must be positive")
        self.maxSize = maxSize
    }

    /// Number of elements currently stored.
    var count: Int { storage.count }

    /// Returns `true` when no elements are stored.
    var isEmpty: Bool { storage.isEmpty }

    /// Returns `true` if `element` is present.
    func contains(_ element: Element) -> Bool {
        storage.contains(element)
    }

    /// Insert `element`. If it is already present this is a no-op.
    /// If the set is at capacity the oldest element is evicted first.
    mutating func insert(_ element: Element) {
        guard !storage.contains(element) else { return }
        if storage.count >= maxSize, let oldest = order.first {
            storage.remove(oldest)
            order.removeFirst()
        }
        storage.insert(element)
        order.append(element)
    }

    /// Remove `element`. If it is not present this is a no-op.
    mutating func remove(_ element: Element) {
        guard storage.remove(element) != nil else { return }
        order.removeAll { $0 == element }
    }

    /// Remove all elements.
    mutating func removeAll() {
        storage.removeAll()
        order.removeAll()
    }
}

// MARK: - VisitedURLStore

/// Thread-safe wrapper around `BoundedSet<String>` for visited-URL dedup.
///
/// Implemented as a class so it can be captured by reference in event-handler
/// closures without requiring actor isolation (which would risk deadlock in the
/// `ExecutionEngine` event-dispatch path).
final class VisitedURLStore: @unchecked Sendable {
    private var set: BoundedSet<String>
    private let lock = NSLock()

    init(maxSize: Int = 100_000) {
        set = BoundedSet(maxSize: maxSize)
    }

    /// Returns `true` and records the URL if it has not been seen before.
    /// Returns `false` (without inserting) if the URL is already known.
    func tryInsert(_ url: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if set.contains(url) { return false }
        set.insert(url)
        return true
    }

    /// Returns `true` if `url` is in the store.
    func contains(_ url: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return set.contains(url)
    }

    /// Number of URLs currently tracked.
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return set.count
    }

    /// Remove all tracked URLs (e.g. between crawl sessions).
    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        set.removeAll()
    }
}
