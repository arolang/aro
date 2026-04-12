// ============================================================
// StoreFileTests.swift
// ARO Runtime - Store File Loader and Flush Service Tests
// ============================================================

import Foundation
import Testing
@testable import ARORuntime

// MARK: - StoreFileLoader Discovery Tests

@Suite("StoreFileLoader Discovery Tests")
struct StoreFileLoaderDiscoveryTests {

    @Test("Discover .store files in directory")
    func testDiscoverStoreFiles() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("aro-store-discover-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let usersStore = tmp.appendingPathComponent("users.store")
        try "- id: \"1\"\n  name: \"Alice\"\n".write(to: usersStore, atomically: true, encoding: .utf8)

        let ordersStore = tmp.appendingPathComponent("orders.store")
        try "- id: \"10\"\n  total: 42\n".write(to: ordersStore, atomically: true, encoding: .utf8)

        let loader = StoreFileLoader()
        let descriptors = try loader.discover(in: tmp)

        #expect(descriptors.count == 2)

        let names = descriptors.map(\.repositoryName)
        #expect(names.contains("users-repository"))
        #expect(names.contains("orders-repository"))
    }

    @Test("Non-.store files are ignored during discovery")
    func testIgnoresNonStoreFiles() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("aro-store-ignore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try "main content".write(
            to: tmp.appendingPathComponent("main.aro"),
            atomically: true, encoding: .utf8
        )
        try "some: yaml".write(
            to: tmp.appendingPathComponent("openapi.yaml"),
            atomically: true, encoding: .utf8
        )
        try "- id: \"1\"\n".write(
            to: tmp.appendingPathComponent("data.store"),
            atomically: true, encoding: .utf8
        )

        let loader = StoreFileLoader()
        let descriptors = try loader.discover(in: tmp)

        #expect(descriptors.count == 1)
        #expect(descriptors.first?.repositoryName == "data-repository")
    }

    @Test("Missing directory returns empty array")
    func testMissingDirectoryReturnsEmpty() throws {
        let nonexistent = FileManager.default.temporaryDirectory
            .appendingPathComponent("aro-store-missing-\(UUID().uuidString)")

        let loader = StoreFileLoader()
        let descriptors = try loader.discover(in: nonexistent)

        #expect(descriptors.isEmpty)
    }

    @Test("Descriptors are sorted by repository name")
    func testDescriptorsSortedByName() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("aro-store-sort-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try "- id: \"1\"\n".write(to: tmp.appendingPathComponent("zebra.store"), atomically: true, encoding: .utf8)
        try "- id: \"2\"\n".write(to: tmp.appendingPathComponent("alpha.store"), atomically: true, encoding: .utf8)
        try "- id: \"3\"\n".write(to: tmp.appendingPathComponent("middle.store"), atomically: true, encoding: .utf8)

        let loader = StoreFileLoader()
        let descriptors = try loader.discover(in: tmp)

        #expect(descriptors.count == 3)
        #expect(descriptors[0].repositoryName == "alpha-repository")
        #expect(descriptors[1].repositoryName == "middle-repository")
        #expect(descriptors[2].repositoryName == "zebra-repository")
    }
}

// MARK: - StoreFileLoader YAML Parsing Tests

@Suite("StoreFileLoader YAML Parsing Tests")
struct StoreFileLoaderParsingTests {

    @Test("Parse YAML list entries into dictionaries")
    func testParseYAMLListEntries() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("aro-store-parse-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let yaml = """
        - id: "1"
          name: "Alice"
          age: 30
        - id: "2"
          name: "Bob"
          age: 25
        """
        let storeFile = tmp.appendingPathComponent("users.store")
        try yaml.write(to: storeFile, atomically: true, encoding: .utf8)

        let loader = StoreFileLoader()
        let descriptors = try loader.discover(in: tmp)

        #expect(descriptors.count == 1)
        let entries = descriptors[0].entries
        #expect(entries.count == 2)

        #expect(entries[0]["id"] as? String == "1")
        #expect(entries[0]["name"] as? String == "Alice")
        #expect(entries[1]["id"] as? String == "2")
        #expect(entries[1]["name"] as? String == "Bob")
    }

    @Test("Empty file produces empty entries")
    func testEmptyFileProducesEmptyEntries() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("aro-store-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let storeFile = tmp.appendingPathComponent("empty.store")
        try "".write(to: storeFile, atomically: true, encoding: .utf8)

        let loader = StoreFileLoader()
        let descriptors = try loader.discover(in: tmp)

        #expect(descriptors.count == 1)
        #expect(descriptors[0].entries.isEmpty)
        #expect(descriptors[0].repositoryName == "empty-repository")
    }

    @Test("Whitespace-only file produces empty entries")
    func testWhitespaceOnlyFileProducesEmptyEntries() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("aro-store-ws-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let storeFile = tmp.appendingPathComponent("blank.store")
        try "   \n  \n  ".write(to: storeFile, atomically: true, encoding: .utf8)

        let loader = StoreFileLoader()
        let descriptors = try loader.discover(in: tmp)

        #expect(descriptors.count == 1)
        #expect(descriptors[0].entries.isEmpty)
    }

    @Test("YAML comments are skipped")
    func testYAMLCommentsSkipped() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("aro-store-comments-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let yaml = """
        # This is a comment
        - id: "1"
          name: "Alice"
        # Another comment
        - id: "2"
          name: "Bob"
        """
        let storeFile = tmp.appendingPathComponent("commented.store")
        try yaml.write(to: storeFile, atomically: true, encoding: .utf8)

        let loader = StoreFileLoader()
        let descriptors = try loader.discover(in: tmp)

        #expect(descriptors.count == 1)
        #expect(descriptors[0].entries.count == 2)
        #expect(descriptors[0].entries[0]["name"] as? String == "Alice")
        #expect(descriptors[0].entries[1]["name"] as? String == "Bob")
    }

    @Test("Single dictionary entry is wrapped in array")
    func testSingleDictWrapped() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("aro-store-single-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let yaml = """
        id: "42"
        name: "Singleton"
        """
        let storeFile = tmp.appendingPathComponent("config.store")
        try yaml.write(to: storeFile, atomically: true, encoding: .utf8)

        let loader = StoreFileLoader()
        let descriptors = try loader.discover(in: tmp)

        #expect(descriptors.count == 1)
        #expect(descriptors[0].entries.count == 1)
        #expect(descriptors[0].entries[0]["id"] as? String == "42")
        #expect(descriptors[0].entries[0]["name"] as? String == "Singleton")
    }
}

// MARK: - StoreFileLoader Repository Name Derivation Tests

@Suite("StoreFileLoader Repository Name Derivation Tests")
struct StoreFileLoaderNameDerivationTests {

    @Test("Repository name derived from filename")
    func testRepositoryNameFromFilename() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("aro-store-name-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let cases: [(filename: String, expected: String)] = [
            ("users.store", "users-repository"),
            ("orders.store", "orders-repository"),
            ("product-catalog.store", "product-catalog-repository"),
            ("a.store", "a-repository"),
        ]

        for testCase in cases {
            let storeFile = tmp.appendingPathComponent(testCase.filename)
            try "- id: \"1\"\n".write(to: storeFile, atomically: true, encoding: .utf8)
        }

        let loader = StoreFileLoader()
        let descriptors = try loader.discover(in: tmp)

        let names = Set(descriptors.map(\.repositoryName))
        for testCase in cases {
            #expect(names.contains(testCase.expected), "Expected \(testCase.expected) in repository names")
        }

        // Cleanup for next tests
        for testCase in cases {
            try? FileManager.default.removeItem(at: tmp.appendingPathComponent(testCase.filename))
        }
    }
}

// MARK: - StoreFileLoader Permission Tests

@Suite("StoreFileLoader Permission Tests")
struct StoreFileLoaderPermissionTests {

    @Test("Writable when POSIX other-write bit is set")
    func testWritableWithOtherWriteBit() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("aro-store-perm-w-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let storeFile = tmp.appendingPathComponent("writable.store")
        try "- id: \"1\"\n".write(to: storeFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o646], ofItemAtPath: storeFile.path)

        let loader = StoreFileLoader()
        let descriptors = try loader.discover(in: tmp)

        #expect(descriptors.count == 1)
        #expect(descriptors[0].isWritable == true)
    }

    @Test("Not writable when other-write bit is not set")
    func testNotWritableWithoutOtherWriteBit() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("aro-store-perm-r-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let storeFile = tmp.appendingPathComponent("readonly.store")
        try "- id: \"1\"\n".write(to: storeFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: storeFile.path)

        let loader = StoreFileLoader()
        let descriptors = try loader.discover(in: tmp)

        #expect(descriptors.count == 1)
        #expect(descriptors[0].isWritable == false)
    }

    @Test("Mixed writable and read-only stores")
    func testMixedPermissions() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("aro-store-perm-mix-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let writableFile = tmp.appendingPathComponent("mutable.store")
        try "- id: \"1\"\n".write(to: writableFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: writableFile.path)

        let readonlyFile = tmp.appendingPathComponent("immutable.store")
        try "- id: \"2\"\n".write(to: readonlyFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: readonlyFile.path)

        let loader = StoreFileLoader()
        let descriptors = try loader.discover(in: tmp)

        #expect(descriptors.count == 2)
        let writable = descriptors.first { $0.repositoryName == "mutable-repository" }
        let readonly = descriptors.first { $0.repositoryName == "immutable-repository" }
        #expect(writable?.isWritable == true)
        #expect(readonly?.isWritable == false)
    }
}

// MARK: - StoreFlushService Tests

@Suite("StoreFlushService Tests")
struct StoreFlushServiceTests {

    @Test("Register writable stores")
    func testRegisterWritableStores() async {
        let storage = InMemoryRepositoryStorage()
        let service = StoreFlushService(storage: storage)

        let writable = StoreFileDescriptor(
            filePath: URL(fileURLWithPath: "/tmp/writable.store"),
            repositoryName: "writable-repository",
            isWritable: true,
            entries: []
        )
        let readonly = StoreFileDescriptor(
            filePath: URL(fileURLWithPath: "/tmp/readonly.store"),
            repositoryName: "readonly-repository",
            isWritable: false,
            entries: []
        )

        await service.register(stores: [writable, readonly])

        let isWritable = await service.isWritable(repository: "writable-repository")
        let isReadonly = await service.isWritable(repository: "readonly-repository")
        #expect(isWritable == true)
        #expect(isReadonly == false)
    }

    @Test("Writable repository names")
    func testWritableRepositoryNames() async {
        let storage = InMemoryRepositoryStorage()
        let service = StoreFlushService(storage: storage)

        let stores = [
            StoreFileDescriptor(
                filePath: URL(fileURLWithPath: "/tmp/a.store"),
                repositoryName: "a-repository",
                isWritable: true,
                entries: []
            ),
            StoreFileDescriptor(
                filePath: URL(fileURLWithPath: "/tmp/b.store"),
                repositoryName: "b-repository",
                isWritable: true,
                entries: []
            ),
            StoreFileDescriptor(
                filePath: URL(fileURLWithPath: "/tmp/c.store"),
                repositoryName: "c-repository",
                isWritable: false,
                entries: []
            ),
        ]

        await service.register(stores: stores)

        let names = await service.writableRepositoryNames
        #expect(names.count == 2)
        #expect(names.contains("a-repository"))
        #expect(names.contains("b-repository"))
        #expect(!names.contains("c-repository"))
    }

    @Test("flushAll writes repository data to disk")
    func testFlushAllWritesToDisk() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("aro-store-flush-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let storeFile = tmp.appendingPathComponent("items.store")
        try "- id: \"1\"\n  name: \"Original\"\n".write(to: storeFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o646], ofItemAtPath: storeFile.path)

        let storage = InMemoryRepositoryStorage()
        let service = StoreFlushService(storage: storage)

        let descriptor = StoreFileDescriptor(
            filePath: storeFile,
            repositoryName: "items-repository",
            isWritable: true,
            entries: [["id": "1", "name": "Original"]]
        )
        await service.register(stores: [descriptor])

        // Store new data in the repository
        await storage.store(
            value: ["id": "99", "name": "New Item"] as [String: any Sendable],
            in: "items-repository",
            businessActivity: "store-flush"
        )

        // Mark dirty and flush
        await service.markDirty(repositoryName: "items-repository")
        await service.flushAll()

        // Read back the file and verify it was written
        let content = try String(contentsOf: storeFile, encoding: .utf8)
        #expect(content.contains("New Item"))
    }

    @Test("Atomic write produces valid YAML")
    func testAtomicWriteProducesValidYAML() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("aro-store-atomic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let storeFile = tmp.appendingPathComponent("products.store")
        try "- id: \"seed\"\n".write(to: storeFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o646], ofItemAtPath: storeFile.path)

        let storage = InMemoryRepositoryStorage()
        let service = StoreFlushService(storage: storage)

        let descriptor = StoreFileDescriptor(
            filePath: storeFile,
            repositoryName: "products-repository",
            isWritable: true,
            entries: []
        )
        await service.register(stores: [descriptor])

        await storage.store(
            value: ["id": "p1", "name": "Widget", "price": 9.99] as [String: any Sendable],
            in: "products-repository",
            businessActivity: "store-flush"
        )
        await storage.store(
            value: ["id": "p2", "name": "Gadget", "price": 19.99] as [String: any Sendable],
            in: "products-repository",
            businessActivity: "store-flush"
        )

        await service.markDirty(repositoryName: "products-repository")
        await service.flushAll()

        // Verify no .tmp file is left behind
        let tmpFile = storeFile.appendingPathExtension("tmp")
        #expect(!FileManager.default.fileExists(atPath: tmpFile.path))

        // Verify the file can be re-parsed by StoreFileLoader
        let loader = StoreFileLoader()
        let reloaded = try loader.discover(in: tmp)
        #expect(reloaded.count == 1)
        #expect(reloaded[0].entries.count >= 2)
    }
}

// MARK: - Store File Integration Tests

@Suite("Store File Integration Tests")
struct StoreFileIntegrationTests {

    @Test("Load store file, seed repository, and retrieve data")
    func testLoadSeedAndRetrieve() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("aro-store-integration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let yaml = """
        - id: "u1"
          name: "Alice"
          role: "admin"
        - id: "u2"
          name: "Bob"
          role: "user"
        - id: "u3"
          name: "Charlie"
          role: "user"
        """
        let storeFile = tmp.appendingPathComponent("users.store")
        try yaml.write(to: storeFile, atomically: true, encoding: .utf8)

        // Step 1: Load with StoreFileLoader
        let loader = StoreFileLoader()
        let descriptors = try loader.discover(in: tmp)

        #expect(descriptors.count == 1)
        let descriptor = descriptors[0]
        #expect(descriptor.repositoryName == "users-repository")
        #expect(descriptor.entries.count == 3)

        // Step 2: Seed a repository with the parsed entries
        let storage = InMemoryRepositoryStorage()
        for entry in descriptor.entries {
            await storage.store(
                value: entry,
                in: descriptor.repositoryName,
                businessActivity: "seed"
            )
        }

        // Step 3: Verify retrieval returns the seeded data
        let allUsers = await storage.retrieve(
            from: "users-repository",
            businessActivity: "seed"
        )
        #expect(allUsers.count == 3)

        // Step 4: Verify filtered retrieval works
        let admins = await storage.retrieve(
            from: "users-repository",
            businessActivity: "seed",
            where: "role",
            equals: "admin"
        )
        #expect(admins.count == 1)

        if let admin = admins.first as? [String: any Sendable] {
            #expect(admin["name"] as? String == "Alice")
        }

        // Step 5: Verify findById works on seeded data
        let bob = await storage.findById(
            in: "users-repository",
            businessActivity: "seed",
            id: "u2"
        )
        #expect(bob != nil)
        if let bobDict = bob as? [String: any Sendable] {
            #expect(bobDict["name"] as? String == "Bob")
        }
    }

    @Test("Round-trip: load, modify, flush, reload")
    func testRoundTripLoadModifyFlushReload() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("aro-store-roundtrip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let yaml = """
        - id: "1"
          name: "Original"
        """
        let storeFile = tmp.appendingPathComponent("items.store")
        try yaml.write(to: storeFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o646], ofItemAtPath: storeFile.path)

        // Load
        let loader = StoreFileLoader()
        let descriptors = try loader.discover(in: tmp)
        let descriptor = descriptors[0]

        // Seed
        let storage = InMemoryRepositoryStorage()
        for entry in descriptor.entries {
            await storage.store(value: entry, in: descriptor.repositoryName, businessActivity: "seed")
        }

        // Modify: add a new entry
        await storage.store(
            value: ["id": "2", "name": "Added"] as [String: any Sendable],
            in: "items-repository",
            businessActivity: "seed"
        )

        // Flush
        let flushService = StoreFlushService(storage: storage)
        await flushService.register(stores: descriptors)
        await flushService.markDirty(repositoryName: "items-repository")
        await flushService.flushAll()

        // Reload from disk
        let reloaded = try loader.discover(in: tmp)
        #expect(reloaded.count == 1)
        #expect(reloaded[0].entries.count == 2)

        let names = reloaded[0].entries.compactMap { $0["name"] as? String }
        #expect(names.contains("Original"))
        #expect(names.contains("Added"))
    }
}
