// ============================================================
// RepositoryIsEqualTests.swift
// ARO Runtime - isEqual() explicit type handling (Issue #164)
// ============================================================

import Foundation
import Testing
@testable import ARORuntime

// MARK: - isEqual() behaviour tests
//
// isEqual() is private to RepositoryStorageActor; we exercise it indirectly
// through InMemoryRepositoryStorage by relying on the no-op deduplication
// that storeWithChangeInfo performs when a dict with an existing id is stored
// with an identical value (isUpdate = true, oldValue = nil).
// Conversely, a changed value produces isUpdate = true, oldValue = non-nil.

@Suite("RepositoryStorage isEqual Tests")
struct RepositoryIsEqualTests {

    private let repo = "eq-test-repository"
    private let activity = "IsEqualTests"

    // ------------------------------------------------------------------ //
    // Helpers

    /// Store a dict and return its auto-assigned id.
    private func storeNew(_ storage: InMemoryRepositoryStorage, _ value: [String: any Sendable]) async -> String {
        let stored = await storage.store(value: value, in: repo, businessActivity: activity)
        return (stored as! [String: any Sendable])["id"] as! String
    }

    /// Re-store a value with the given id and return the RepositoryStoreResult.
    private func reStore(_ storage: InMemoryRepositoryStorage, id: String, extra: [String: any Sendable] = [:]) async -> RepositoryStoreResult {
        var value: [String: any Sendable] = ["id": id]
        for (k, v) in extra { value[k] = v }
        return await storage.storeWithChangeInfo(value: value, in: repo, businessActivity: activity)
    }

    // ------------------------------------------------------------------ //
    // String

    @Test("String equality: identical strings are deduped")
    func testStringEqual() async {
        let storage = InMemoryRepositoryStorage()
        let id = await storeNew(storage, ["id": "s1", "name": "Alice"])
        let result = await reStore(storage, id: id, extra: ["name": "Alice"])
        // Same value → no-op update: oldValue is nil
        #expect(result.isUpdate == true)
        #expect(result.oldValue == nil)
    }

    @Test("String inequality: different strings trigger update")
    func testStringNotEqual() async {
        let storage = InMemoryRepositoryStorage()
        let id = await storeNew(storage, ["id": "s2", "name": "Alice"])
        let result = await reStore(storage, id: id, extra: ["name": "Bob"])
        #expect(result.isUpdate == true)
        #expect(result.oldValue != nil)
    }

    // ------------------------------------------------------------------ //
    // Int

    @Test("Int equality: same int is deduped")
    func testIntEqual() async {
        let storage = InMemoryRepositoryStorage()
        let id = await storeNew(storage, ["id": "i1", "count": 42 as Int])
        let result = await reStore(storage, id: id, extra: ["count": 42 as Int])
        #expect(result.isUpdate == true)
        #expect(result.oldValue == nil)
    }

    @Test("Int inequality: different int triggers update")
    func testIntNotEqual() async {
        let storage = InMemoryRepositoryStorage()
        let id = await storeNew(storage, ["id": "i2", "count": 1 as Int])
        let result = await reStore(storage, id: id, extra: ["count": 2 as Int])
        #expect(result.isUpdate == true)
        #expect(result.oldValue != nil)
    }

    // ------------------------------------------------------------------ //
    // Double

    @Test("Double equality: same double is deduped")
    func testDoubleEqual() async {
        let storage = InMemoryRepositoryStorage()
        let id = await storeNew(storage, ["id": "d1", "score": 3.14 as Double])
        let result = await reStore(storage, id: id, extra: ["score": 3.14 as Double])
        #expect(result.isUpdate == true)
        #expect(result.oldValue == nil)
    }

    // ------------------------------------------------------------------ //
    // Bool

    @Test("Bool equality: same bool is deduped")
    func testBoolEqual() async {
        let storage = InMemoryRepositoryStorage()
        let id = await storeNew(storage, ["id": "b1", "active": true as Bool])
        let result = await reStore(storage, id: id, extra: ["active": true as Bool])
        #expect(result.isUpdate == true)
        #expect(result.oldValue == nil)
    }

    @Test("Bool inequality: different bool triggers update")
    func testBoolNotEqual() async {
        let storage = InMemoryRepositoryStorage()
        let id = await storeNew(storage, ["id": "b2", "active": true as Bool])
        let result = await reStore(storage, id: id, extra: ["active": false as Bool])
        #expect(result.isUpdate == true)
        #expect(result.oldValue != nil)
    }

    // ------------------------------------------------------------------ //
    // UUID

    @Test("UUID equality: same UUID is deduped")
    func testUUIDEqual() async {
        let storage = InMemoryRepositoryStorage()
        let uid = UUID()
        let id = await storeNew(storage, ["id": "u1", "ref": uid])
        let result = await reStore(storage, id: id, extra: ["ref": uid])
        #expect(result.isUpdate == true)
        #expect(result.oldValue == nil)
    }

    @Test("UUID inequality: different UUID triggers update")
    func testUUIDNotEqual() async {
        let storage = InMemoryRepositoryStorage()
        let id = await storeNew(storage, ["id": "u2", "ref": UUID()])
        let result = await reStore(storage, id: id, extra: ["ref": UUID()])
        #expect(result.isUpdate == true)
        #expect(result.oldValue != nil)
    }

    // ------------------------------------------------------------------ //
    // Date

    @Test("Date equality: same date is deduped")
    func testDateEqual() async {
        let storage = InMemoryRepositoryStorage()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let id = await storeNew(storage, ["id": "dt1", "ts": now])
        let result = await reStore(storage, id: id, extra: ["ts": now])
        #expect(result.isUpdate == true)
        #expect(result.oldValue == nil)
    }

    @Test("Date inequality: different date triggers update")
    func testDateNotEqual() async {
        let storage = InMemoryRepositoryStorage()
        let t1 = Date(timeIntervalSince1970: 1_000_000)
        let t2 = Date(timeIntervalSince1970: 2_000_000)
        let id = await storeNew(storage, ["id": "dt2", "ts": t1])
        let result = await reStore(storage, id: id, extra: ["ts": t2])
        #expect(result.isUpdate == true)
        #expect(result.oldValue != nil)
    }

    // ------------------------------------------------------------------ //
    // Nested dictionary

    @Test("Nested dict equality: identical nested dict is deduped")
    func testNestedDictEqual() async {
        let storage = InMemoryRepositoryStorage()
        let nested: [String: any Sendable] = ["city": "Berlin", "zip": "10115"]
        let id = await storeNew(storage, ["id": "nd1", "address": nested])
        let result = await reStore(storage, id: id, extra: ["address": nested])
        #expect(result.isUpdate == true)
        #expect(result.oldValue == nil)
    }

    @Test("Nested dict inequality: changed nested dict triggers update")
    func testNestedDictNotEqual() async {
        let storage = InMemoryRepositoryStorage()
        let addr1: [String: any Sendable] = ["city": "Berlin"]
        let addr2: [String: any Sendable] = ["city": "Munich"]
        let id = await storeNew(storage, ["id": "nd2", "address": addr1])
        let result = await reStore(storage, id: id, extra: ["address": addr2])
        #expect(result.isUpdate == true)
        #expect(result.oldValue != nil)
    }

    // ------------------------------------------------------------------ //
    // Unknown type — must NOT produce false positives

    struct Opaque: Sendable, CustomStringConvertible {
        let x: Int
        var description: String { "Opaque(\(x))" }
    }

    @Test("Unknown types with same description do NOT produce false positive deduplication")
    func testUnknownTypeNoFalsePositive() async {
        let storage = InMemoryRepositoryStorage()
        // Two Opaque values with the same String(describing:) output but are different objects.
        // Old code: String(describing:) == String(describing:) → false positive dedup.
        // New code: returns false → triggers update.
        let a = Opaque(x: 7)
        let b = Opaque(x: 7)  // same description "Opaque(7)"
        let id = await storeNew(storage, ["id": "op1", "val": a])
        let result = await reStore(storage, id: id, extra: ["val": b])
        // Unknown type → isEqual returns false → store sees changed value → oldValue != nil
        #expect(result.isUpdate == true)
        #expect(result.oldValue != nil)
    }
}
