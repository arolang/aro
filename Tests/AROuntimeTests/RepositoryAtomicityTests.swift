// ============================================================
// RepositoryAtomicityTests.swift
// ARO Runtime - RepositoryStorage TOCTOU fix (Issue #163)
// ============================================================
//
// The TOCTOU hazard: before this fix each operation was two actor turns:
//   let key = await actor.resolveKey(...)   // turn 1 — reads applicationScope
//   await actor.store(value:key:)           // turn 2 — between turns, export() could remap
//
// After the fix each public actor method calls resolveKey internally,
// so key resolution and mutation happen in a single actor turn.
//
// These tests verify that after export() the subsequent operations
// correctly use the exported (remapped) repository, which only works
// reliably when resolution is atomic with the operation.

import Foundation
import Testing
@testable import ARORuntime

@Suite("RepositoryStorage Atomicity Tests")
struct RepositoryAtomicityTests {

    // MARK: - Helpers

    private func storage() -> InMemoryRepositoryStorage { InMemoryRepositoryStorage() }

    // MARK: - export() + store atomicity

    @Test("store() after export() writes into the exported repository")
    func testStoreUsesExportedRepository() async {
        let s = storage()
        // Seed data into the canonical repo
        _ = await s.store(value: ["name": "original"] as [String: any Sendable],
                          in: "source-repository", businessActivity: "test")

        // Export source → alias
        await s.export(repository: "source-repository", from: "test", as: "alias-repository")

        // Store via the alias — should land in source-repository
        _ = await s.store(value: ["name": "via-alias"] as [String: any Sendable],
                          in: "alias-repository", businessActivity: "test")

        let fromSource = await s.retrieve(from: "source-repository", businessActivity: "test")
        let names = fromSource.compactMap { ($0 as? [String: any Sendable])?["name"] as? String }
        #expect(names.contains("original"))
        #expect(names.contains("via-alias"))
    }

    @Test("retrieve() after export() reads from the exported repository")
    func testRetrieveUsesExportedRepository() async {
        let s = storage()
        _ = await s.store(value: ["name": "Alice"] as [String: any Sendable],
                          in: "users-repository", businessActivity: "test")

        await s.export(repository: "users-repository", from: "test", as: "all-users-repository")

        let results = await s.retrieve(from: "all-users-repository", businessActivity: "test")
        let names = results.compactMap { ($0 as? [String: any Sendable])?["name"] as? String }
        #expect(names == ["Alice"])
    }

    @Test("retrieve(where:) after export() reads from the exported repository")
    func testRetrieveFilteredUsesExportedRepository() async {
        let s = storage()
        _ = await s.store(value: ["role": "admin", "name": "Alice"] as [String: any Sendable],
                          in: "staff-repository", businessActivity: "test")
        _ = await s.store(value: ["role": "user", "name": "Bob"] as [String: any Sendable],
                          in: "staff-repository", businessActivity: "test")

        await s.export(repository: "staff-repository", from: "test", as: "members-repository")

        let admins = await s.retrieve(from: "members-repository", businessActivity: "test",
                                      where: "role", equals: "admin")
        let names = admins.compactMap { ($0 as? [String: any Sendable])?["name"] as? String }
        #expect(names == ["Alice"])
    }

    @Test("exists() after export() reflects the exported repository")
    func testExistsUsesExportedRepository() async {
        let s = storage()
        _ = await s.store(value: "item" as any Sendable,
                          in: "items-repository", businessActivity: "test")

        await s.export(repository: "items-repository", from: "test", as: "things-repository")

        let exists = await s.exists(repository: "things-repository", businessActivity: "test")
        #expect(exists == true)
    }

    @Test("count() after export() counts from the exported repository")
    func testCountUsesExportedRepository() async {
        let s = storage()
        _ = await s.store(value: ["x": 1] as [String: any Sendable], in: "num-repository", businessActivity: "test")
        _ = await s.store(value: ["x": 2] as [String: any Sendable], in: "num-repository", businessActivity: "test")

        await s.export(repository: "num-repository", from: "test", as: "numbers-repository")

        let c = await s.count(repository: "numbers-repository", businessActivity: "test")
        #expect(c == 2)
    }

    @Test("delete() after export() removes from the exported repository")
    func testDeleteUsesExportedRepository() async {
        let s = storage()
        _ = await s.store(value: ["tag": "remove-me"] as [String: any Sendable],
                          in: "tags-repository", businessActivity: "test")
        _ = await s.store(value: ["tag": "keep-me"] as [String: any Sendable],
                          in: "tags-repository", businessActivity: "test")

        await s.export(repository: "tags-repository", from: "test", as: "labels-repository")

        let result = await s.delete(from: "labels-repository", businessActivity: "test",
                                    where: "tag", equals: "remove-me")
        #expect(result.count == 1)

        let remaining = await s.retrieve(from: "tags-repository", businessActivity: "test")
        let tags = remaining.compactMap { ($0 as? [String: any Sendable])?["tag"] as? String }
        #expect(tags == ["keep-me"])
    }

    @Test("clear() after export() clears the exported repository")
    func testClearUsesExportedRepository() async {
        let s = storage()
        _ = await s.store(value: ["v": 1] as [String: any Sendable], in: "data-repository", businessActivity: "test")

        await s.export(repository: "data-repository", from: "test", as: "cache-repository")

        await s.clear(repository: "cache-repository", businessActivity: "test")

        let items = await s.retrieve(from: "data-repository", businessActivity: "test")
        #expect(items.isEmpty)
    }

    @Test("findById() after export() finds item in the exported repository")
    func testFindByIdUsesExportedRepository() async {
        let s = storage()
        let stored = await s.store(value: ["name": "Carol"] as [String: any Sendable],
                                   in: "people-repository", businessActivity: "test")
        guard let id = (stored as? [String: any Sendable])?["id"] as? String else {
            Issue.record("stored value should have an id")
            return
        }

        await s.export(repository: "people-repository", from: "test", as: "contacts-repository")

        let found = await s.findById(in: "contacts-repository", businessActivity: "test", id: id)
        let name = (found as? [String: any Sendable])?["name"] as? String
        #expect(name == "Carol")
    }

    // MARK: - No false TOCTOU across concurrent stores

    @Test("Concurrent stores into the same repository are all visible")
    func testConcurrentStoresAreVisible() async {
        let s = storage()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask {
                    _ = await s.store(value: ["seq": i] as [String: any Sendable],
                                      in: "concurrent-repository", businessActivity: "test")
                }
            }
        }
        let count = await s.count(repository: "concurrent-repository", businessActivity: "test")
        #expect(count == 20)
    }
}
