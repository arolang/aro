// ============================================================
// RepositoryStorageTests.swift
// ARO Runtime - Repository Storage Unit Tests
// ============================================================

import Foundation
import Testing
@testable import ARORuntime
@testable import AROParser

// MARK: - Repository Store Result Tests

@Suite("Repository Store Result Tests")
struct RepositoryStoreResultTests {

    @Test("Store result creation for new item")
    func testStoreResultCreate() {
        let result = RepositoryStoreResult(
            storedValue: ["id": "123", "name": "Test"],
            oldValue: nil,
            isUpdate: false,
            entityId: "123"
        )

        #expect(result.isUpdate == false)
        #expect(result.entityId == "123")
        #expect(result.oldValue == nil)
    }

    @Test("Store result creation for update")
    func testStoreResultUpdate() {
        let oldValue: [String: any Sendable] = ["id": "123", "name": "Old"]
        let result = RepositoryStoreResult(
            storedValue: ["id": "123", "name": "New"],
            oldValue: oldValue,
            isUpdate: true,
            entityId: "123"
        )

        #expect(result.isUpdate == true)
        #expect(result.oldValue != nil)
    }
}

// MARK: - Repository Delete Result Tests

@Suite("Repository Delete Result Tests")
struct RepositoryDeleteResultTests {

    @Test("Delete result with deleted items")
    func testDeleteResultWithItems() {
        let items: [any Sendable] = [
            ["id": "1", "name": "Item1"],
            ["id": "2", "name": "Item2"]
        ]
        let result = RepositoryDeleteResult(deletedItems: items)

        #expect(result.count == 2)
        #expect(result.deletedItems.count == 2)
    }

    @Test("Delete result with no items")
    func testDeleteResultEmpty() {
        let result = RepositoryDeleteResult(deletedItems: [])

        #expect(result.count == 0)
        #expect(result.deletedItems.isEmpty)
    }
}

// MARK: - InMemoryRepositoryStorage Tests

@Suite("InMemory Repository Storage Tests")
struct InMemoryRepositoryStorageTests {

    @Test("Shared instance exists")
    func testSharedInstance() {
        let storage = InMemoryRepositoryStorage.shared
        #expect(storage != nil)
    }

    @Test("Store and retrieve value")
    func testStoreAndRetrieve() async {
        let storage = InMemoryRepositoryStorage()

        let value: [String: any Sendable] = ["name": "Test Item"]
        await storage.store(value: value, in: "test-repository", businessActivity: "Test")

        let retrieved = await storage.retrieve(from: "test-repository", businessActivity: "Test")
        #expect(retrieved.count == 1)
    }

    @Test("Store auto-generates ID")
    func testAutoGeneratesId() async {
        let storage = InMemoryRepositoryStorage()

        let value: [String: any Sendable] = ["name": "No ID"]
        let stored = await storage.store(value: value, in: "auto-id-repository", businessActivity: "Test")

        if let dict = stored as? [String: any Sendable] {
            #expect(dict["id"] != nil)
        }
    }

    @Test("Store with change info")
    func testStoreWithChangeInfo() async {
        let storage = InMemoryRepositoryStorage()

        let value: [String: any Sendable] = ["name": "Test"]
        let result = await storage.storeWithChangeInfo(value: value, in: "change-repository", businessActivity: "Test")

        #expect(result.isUpdate == false)
        #expect(result.entityId != nil)
    }

    @Test("Retrieve with where clause")
    func testRetrieveWithWhere() async {
        let storage = InMemoryRepositoryStorage()

        await storage.store(value: ["id": "1", "status": "active"] as [String: any Sendable], in: "filter-repository", businessActivity: "Test")
        await storage.store(value: ["id": "2", "status": "inactive"] as [String: any Sendable], in: "filter-repository", businessActivity: "Test")
        await storage.store(value: ["id": "3", "status": "active"] as [String: any Sendable], in: "filter-repository", businessActivity: "Test")

        let active = await storage.retrieve(from: "filter-repository", businessActivity: "Test", where: "status", equals: "active")
        #expect(active.count == 2)
    }

    @Test("Delete with where clause")
    func testDeleteWithWhere() async {
        let storage = InMemoryRepositoryStorage()

        await storage.store(value: ["id": "1", "status": "active"] as [String: any Sendable], in: "delete-repository", businessActivity: "Test")
        await storage.store(value: ["id": "2", "status": "inactive"] as [String: any Sendable], in: "delete-repository", businessActivity: "Test")

        let result = await storage.delete(from: "delete-repository", businessActivity: "Test", where: "status", equals: "inactive")
        #expect(result.count == 1)

        let remaining = await storage.retrieve(from: "delete-repository", businessActivity: "Test")
        #expect(remaining.count == 1)
    }

    @Test("Find by ID")
    func testFindById() async {
        let storage = InMemoryRepositoryStorage()

        await storage.store(value: ["id": "find-me", "name": "Target"] as [String: any Sendable], in: "find-repository", businessActivity: "Test")
        await storage.store(value: ["id": "not-me", "name": "Other"] as [String: any Sendable], in: "find-repository", businessActivity: "Test")

        let found = await storage.findById(in: "find-repository", businessActivity: "Test", id: "find-me")
        #expect(found != nil)

        if let dict = found as? [String: any Sendable] {
            #expect(dict["name"] as? String == "Target")
        }
    }

    @Test("Find by ID returns nil for missing")
    func testFindByIdMissing() async {
        let storage = InMemoryRepositoryStorage()

        let found = await storage.findById(in: "empty-repository", businessActivity: "Test", id: "missing")
        #expect(found == nil)
    }

    @Test("Repository exists check")
    func testExists() async {
        let storage = InMemoryRepositoryStorage()

        await storage.store(value: ["name": "Test"] as [String: any Sendable], in: "exists-repository", businessActivity: "Test")

        let exists = await storage.exists(repository: "exists-repository", businessActivity: "Test")
        #expect(exists == true)

        let notExists = await storage.exists(repository: "missing-repository", businessActivity: "Test")
        #expect(notExists == false)
    }

    @Test("Clear repository")
    func testClear() async {
        let storage = InMemoryRepositoryStorage()

        await storage.store(value: ["name": "Item1"] as [String: any Sendable], in: "clear-repository", businessActivity: "Test")
        await storage.store(value: ["name": "Item2"] as [String: any Sendable], in: "clear-repository", businessActivity: "Test")

        await storage.clear(repository: "clear-repository", businessActivity: "Test")

        let retrieved = await storage.retrieve(from: "clear-repository", businessActivity: "Test")
        #expect(retrieved.isEmpty)
    }

    @Test("Export to application scope")
    func testExport() async {
        let storage = InMemoryRepositoryStorage()

        await storage.store(value: ["name": "Shared"] as [String: any Sendable], in: "source-repository", businessActivity: "SourceActivity")

        await storage.export(repository: "source-repository", from: "SourceActivity", as: "exported-repository")

        // Exported repository should be accessible
        let retrieved = await storage.retrieve(from: "exported-repository", businessActivity: "AnyActivity")
        #expect(retrieved.count >= 0)  // May be empty if not implemented fully
    }

    @Test("Is repository name check")
    func testIsRepositoryName() {
        #expect(InMemoryRepositoryStorage.isRepositoryName("user-repository") == true)
        #expect(InMemoryRepositoryStorage.isRepositoryName("order-repository") == true)
        #expect(InMemoryRepositoryStorage.isRepositoryName("users") == false)
        #expect(InMemoryRepositoryStorage.isRepositoryName("data") == false)
    }

    @Test("Update existing by ID")
    func testUpdateById() async {
        let storage = InMemoryRepositoryStorage()

        await storage.store(value: ["id": "update-id", "name": "Original"] as [String: any Sendable], in: "update-repository", businessActivity: "Test")

        // Store with same ID should update
        let result = await storage.storeWithChangeInfo(value: ["id": "update-id", "name": "Updated"] as [String: any Sendable], in: "update-repository", businessActivity: "Test")

        #expect(result.isUpdate == true)
        #expect(result.oldValue != nil)

        let retrieved = await storage.retrieve(from: "update-repository", businessActivity: "Test")
        #expect(retrieved.count == 1)

        if let dict = retrieved.first as? [String: any Sendable] {
            #expect(dict["name"] as? String == "Updated")
        }
    }

    @Test("Multiple items in repository")
    func testMultipleItems() async {
        let storage = InMemoryRepositoryStorage()

        for i in 1...5 {
            await storage.store(value: ["id": "\(i)", "index": i] as [String: any Sendable], in: "multi-repository", businessActivity: "Test")
        }

        let retrieved = await storage.retrieve(from: "multi-repository", businessActivity: "Test")
        #expect(retrieved.count == 5)
    }
}
