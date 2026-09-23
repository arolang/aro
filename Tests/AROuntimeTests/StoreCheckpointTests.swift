// ============================================================
// StoreCheckpointTests.swift
// ARO Runtime — explicit .store checkpoints and durable writes
// ARO-0073 §5a, GitLab #863
// ============================================================
//
// A `.store` file was writable or not, with nothing in between: no explicit
// flush, no grouping, and a write-back path whose "atomic write" removed the
// destination before moving the replacement over it — so there was a window
// in which the file did not exist at all, and no fsync anywhere.

import Foundation
import Testing
@testable import ARORuntime

@Suite("Store checkpoints (#863)")
struct StoreCheckpointTests {

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aro-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func store(_ directory: URL, named name: String,
                       repository: String) throws -> StoreFileDescriptor {
        let path = directory.appendingPathComponent(name)
        try "- id: 1\n".write(to: path, atomically: true, encoding: .utf8)
        return StoreFileDescriptor(
            filePath: path,
            repositoryName: repository,
            isWritable: true,
            entries: [["id": 1]]
        )
    }

    @Test("Commit writes the store and reports what it wrote")
    func commitWritesOneStore() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let descriptor = try store(directory, named: "orders.store",
                                   repository: "orders-test-repository")
        let storage = InMemoryRepositoryStorage()
        await storage.store(value: ["id": 1] as [String: any Sendable],
                            in: "orders-test-repository", businessActivity: "seed")
        await storage.store(value: ["id": 2] as [String: any Sendable],
                            in: "orders-test-repository", businessActivity: "seed")

        let service = StoreFlushService(storage: storage)
        await service.register(stores: [descriptor])

        let checkpoint = try await service.checkpoint(repositories: ["orders-test-repository"])
        #expect(checkpoint.written == 1)
        #expect(checkpoint.items == 2)
        #expect(checkpoint.repositories == ["orders-test-repository"])

        let written = try String(contentsOf: descriptor.filePath, encoding: .utf8)
        #expect(written.contains("id: 2"))
    }

    @Test("the destination is replaced, never removed first")
    func destinationIsNeverMissing() async throws {
        // `moveItem` fails when the destination exists, which is why the old
        // implementation removed it first — and that removal is exactly the
        // window in which a crash left no file at all. `rename(2)` replaces
        // atomically and needs no removal.
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let descriptor = try store(directory, named: "items.store",
                                   repository: "items-test-repository")
        let inode = try FileManager.default
            .attributesOfItem(atPath: descriptor.filePath.path)[.systemFileNumber] as? Int

        let storage = InMemoryRepositoryStorage()
        await storage.store(value: ["id": 7] as [String: any Sendable],
                            in: "items-test-repository", businessActivity: "seed")
        let service = StoreFlushService(storage: storage)
        await service.register(stores: [descriptor])
        _ = try await service.checkpoint(repositories: ["items-test-repository"])

        #expect(FileManager.default.fileExists(atPath: descriptor.filePath.path))
        let newInode = try FileManager.default
            .attributesOfItem(atPath: descriptor.filePath.path)[.systemFileNumber] as? Int
        // A replacement, not a rewrite in place — which is what makes a
        // partially written file impossible.
        #expect(newInode != inode)

        // No temp file left behind.
        let leftovers = try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty)
    }

    @Test("a group checkpoint writes every store")
    func checkpointAllWritesEverything() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let orders = try store(directory, named: "orders.store", repository: "g-orders-repository")
        let customers = try store(directory, named: "customers.store", repository: "g-customers-repository")

        let storage = InMemoryRepositoryStorage()
        await storage.store(value: ["id": 10] as [String: any Sendable],
                            in: "g-orders-repository", businessActivity: "seed")
        await storage.store(value: ["id": 20] as [String: any Sendable],
                            in: "g-customers-repository", businessActivity: "seed")

        let service = StoreFlushService(storage: storage)
        await service.register(stores: [orders, customers])
        await service.markDirty(repositoryName: "g-orders-repository")
        await service.markDirty(repositoryName: "g-customers-repository")

        let checkpoint = try await service.checkpoint()
        #expect(checkpoint.written == 2)
        #expect(checkpoint.repositories == ["g-customers-repository", "g-orders-repository"])
        #expect(try String(contentsOf: orders.filePath, encoding: .utf8).contains("id: 10"))
        #expect(try String(contentsOf: customers.filePath, encoding: .utf8).contains("id: 20"))
    }

    @Test("a checkpoint of nothing writes nothing and does not fail")
    func emptyCheckpointIsFine() async throws {
        let service = StoreFlushService(storage: InMemoryRepositoryStorage())
        let checkpoint = try await service.checkpoint()
        #expect(checkpoint.written == 0)
        #expect(checkpoint.repositories.isEmpty)
    }

    @Test("a repository with no writable store is not written")
    func unregisteredRepositoryIsSkipped() async throws {
        let service = StoreFlushService(storage: InMemoryRepositoryStorage())
        let checkpoint = try await service.checkpoint(repositories: ["no-such-repository"])
        #expect(checkpoint.written == 0)
    }

    // MARK: - Write-back mode

    @Test("manual mode stops mutations scheduling their own write")
    func manualModeDefersWrites() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let descriptor = try store(directory, named: "notes.store",
                                   repository: "notes-test-repository")
        let storage = InMemoryRepositoryStorage()
        await storage.store(value: ["id": 99] as [String: any Sendable],
                            in: "notes-test-repository", businessActivity: "seed")

        let service = StoreFlushService(storage: storage)
        await service.register(stores: [descriptor])
        await service.setWriteBackMode(.manual)
        await service.markDirty(repositoryName: "notes-test-repository")

        // Well past the 1-second debounce auto mode would have used.
        try await Task.sleep(nanoseconds: 1_400_000_000)
        #expect(try !String(contentsOf: descriptor.filePath, encoding: .utf8).contains("id: 99"))

        _ = try await service.checkpoint()
        #expect(try String(contentsOf: descriptor.filePath, encoding: .utf8).contains("id: 99"))
    }

    @Test("the mode round-trips")
    func modeIsReadable() async {
        let service = StoreFlushService(storage: InMemoryRepositoryStorage())
        #expect(await service.currentWriteBackMode == .auto)
        await service.setWriteBackMode(.manual)
        #expect(await service.currentWriteBackMode == .manual)
    }

    @Test("write-back mode names are the two documented spellings")
    func modeParsing() {
        #expect(StoreWriteBackMode(rawValue: "auto") == .auto)
        #expect(StoreWriteBackMode(rawValue: "manual") == .manual)
        #expect(StoreWriteBackMode(rawValue: "sometimes") == nil)
    }
}
