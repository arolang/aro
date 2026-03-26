// ============================================================
// BoundedSetTests.swift
// ARO Runtime - BoundedSet unit tests (issue #154)
// ============================================================

import XCTest
@testable import ARORuntime

final class BoundedSetTests: XCTestCase {

    // MARK: - Basic behaviour

    func testEmptySetContainsNothing() {
        let bs = BoundedSet<String>(maxSize: 10)
        XCTAssertFalse(bs.contains("x"))
        XCTAssertTrue(bs.isEmpty)
        XCTAssertEqual(bs.count, 0)
    }

    func testInsertAndContains() {
        var bs = BoundedSet<String>(maxSize: 10)
        bs.insert("hello")
        XCTAssertTrue(bs.contains("hello"))
        XCTAssertEqual(bs.count, 1)
    }

    func testDuplicateInsertIsNoop() {
        var bs = BoundedSet<String>(maxSize: 10)
        bs.insert("a")
        bs.insert("a")
        XCTAssertEqual(bs.count, 1)
    }

    func testRemoveKnownElement() {
        var bs = BoundedSet<String>(maxSize: 10)
        bs.insert("a")
        bs.remove("a")
        XCTAssertFalse(bs.contains("a"))
        XCTAssertEqual(bs.count, 0)
    }

    func testRemoveUnknownElementIsNoop() {
        var bs = BoundedSet<String>(maxSize: 10)
        bs.insert("a")
        bs.remove("z")  // must not crash
        XCTAssertEqual(bs.count, 1)
    }

    func testRemoveAll() {
        var bs = BoundedSet<String>(maxSize: 10)
        bs.insert("a")
        bs.insert("b")
        bs.removeAll()
        XCTAssertTrue(bs.isEmpty)
    }

    // MARK: - Eviction (FIFO)

    func testOldestElementEvictedWhenFull() {
        var bs = BoundedSet<Int>(maxSize: 3)
        bs.insert(1)
        bs.insert(2)
        bs.insert(3)
        bs.insert(4)  // 1 should be evicted

        XCTAssertFalse(bs.contains(1), "Oldest element must be evicted")
        XCTAssertTrue(bs.contains(2))
        XCTAssertTrue(bs.contains(3))
        XCTAssertTrue(bs.contains(4))
        XCTAssertEqual(bs.count, 3)
    }

    func testEvictedSlotCanBeReused() {
        var bs = BoundedSet<Int>(maxSize: 2)
        bs.insert(1)
        bs.insert(2)
        bs.insert(3)  // evicts 1
        bs.insert(1)  // re-insert previously evicted element

        XCTAssertTrue(bs.contains(1))
        XCTAssertFalse(bs.contains(2), "2 should now be evicted")
        XCTAssertTrue(bs.contains(3))
    }

    func testFIFOOrder() {
        var bs = BoundedSet<String>(maxSize: 3)
        bs.insert("a")
        bs.insert("b")
        bs.insert("c")
        bs.insert("d")  // evicts "a"
        bs.insert("e")  // evicts "b"

        XCTAssertFalse(bs.contains("a"))
        XCTAssertFalse(bs.contains("b"))
        XCTAssertTrue(bs.contains("c"))
        XCTAssertTrue(bs.contains("d"))
        XCTAssertTrue(bs.contains("e"))
    }

    func testCapacityExactlyMet() {
        var bs = BoundedSet<Int>(maxSize: 5)
        for i in 1...5 { bs.insert(i) }
        XCTAssertEqual(bs.count, 5)
        for i in 1...5 { XCTAssertTrue(bs.contains(i)) }
    }

    func testSizeOneSet() {
        var bs = BoundedSet<String>(maxSize: 1)
        bs.insert("first")
        XCTAssertTrue(bs.contains("first"))
        bs.insert("second")
        XCTAssertFalse(bs.contains("first"))
        XCTAssertTrue(bs.contains("second"))
        XCTAssertEqual(bs.count, 1)
    }

    // MARK: - VisitedURLStore

    func testVisitedURLStoreTryInsertReturnsTrueForNew() {
        let store = VisitedURLStore(maxSize: 10)
        XCTAssertTrue(store.tryInsert("https://example.com"))
    }

    func testVisitedURLStoreTryInsertReturnsFalseForSeen() {
        let store = VisitedURLStore(maxSize: 10)
        XCTAssertTrue(store.tryInsert("https://example.com"))
        XCTAssertFalse(store.tryInsert("https://example.com"))
    }

    func testVisitedURLStoreContains() {
        let store = VisitedURLStore(maxSize: 10)
        store.tryInsert("https://example.com")
        XCTAssertTrue(store.contains("https://example.com"))
        XCTAssertFalse(store.contains("https://other.com"))
    }

    func testVisitedURLStoreCount() {
        let store = VisitedURLStore(maxSize: 10)
        store.tryInsert("https://a.com")
        store.tryInsert("https://b.com")
        XCTAssertEqual(store.count, 2)
    }

    func testVisitedURLStoreRemoveAll() {
        let store = VisitedURLStore(maxSize: 10)
        store.tryInsert("https://a.com")
        store.removeAll()
        XCTAssertEqual(store.count, 0)
        XCTAssertFalse(store.contains("https://a.com"))
    }

    func testVisitedURLStoreEvictsWhenFull() {
        let store = VisitedURLStore(maxSize: 2)
        store.tryInsert("https://a.com")
        store.tryInsert("https://b.com")
        store.tryInsert("https://c.com")  // evicts a

        XCTAssertFalse(store.contains("https://a.com"), "Oldest URL must be evicted")
        XCTAssertTrue(store.contains("https://b.com"))
        XCTAssertTrue(store.contains("https://c.com"))
    }

    func testVisitedURLStoreConcurrentInserts() async {
        // Smoke test: concurrent inserts must not crash or corrupt state.
        let store = VisitedURLStore(maxSize: 1_000)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<500 {
                group.addTask {
                    _ = store.tryInsert("https://example.com/page/\(i)")
                }
            }
        }
        XCTAssertLessThanOrEqual(store.count, 1_000)
    }
}
