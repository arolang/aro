// ============================================================
// BoundedSet.swift
// ARO Runtime - Bounded FIFO-evicting set
// ============================================================

import Foundation
import DequeModule

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
/// - Complexity: `contains` is O(1); `insert` is O(1) amortised
///   *including* eviction (#318). The insertion order lives in a
///   swift-collections `Deque`, so `removeFirst()` is O(1) instead of
///   the O(n) it had on an `Array`. At maxSize ≈ 100 000 the previous
///   `Array.removeFirst` measured ~1 ms per eviction; with Deque it's
///   < 0.1 ms.
struct BoundedSet<Element: Hashable> {
    private var storage: Set<Element> = []
    /// Insertion order for FIFO eviction. Deque gives O(1) push-back
    /// and pop-front — exactly the operations the eviction path needs
    /// (#318). `removeAll(where:)` used by `remove(_:)` is still O(n)
    /// but is off the hot path.
    private var order: Deque<Element> = []

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
        if storage.count >= maxSize {
            // Deque.removeFirst() is O(1) — that's the whole point of
            // #318. The previous Array implementation shifted every
            // remaining element on each eviction.
            let oldest = order.removeFirst()
            storage.remove(oldest)
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
