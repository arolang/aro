// ============================================================
// FileOpsTests.swift
// AROCLI - Tests for background FileManager wrappers (issue #365)
// ============================================================

import Testing
import Foundation
@testable import AROCLI

@Suite("FileOps — background file operations")
struct FileOpsTests {

    /// Fresh scratch directory per test.
    private func makeScratchDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aro-fileops-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("createDirectory creates intermediate directories")
    func createDirectoryIntermediates() async throws {
        let scratch = try makeScratchDir()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let nested = scratch.appendingPathComponent("a/b/c")
        try await FileOps.createDirectory(at: nested)

        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: nested.path, isDirectory: &isDir))
        #expect(isDir.boolValue)
    }

    @Test("createDirectoryIfNeeded is idempotent on an existing directory")
    func createDirectoryIfNeededIdempotent() async throws {
        let scratch = try makeScratchDir()
        defer { try? FileManager.default.removeItem(at: scratch) }

        await FileOps.createDirectoryIfNeeded(at: scratch)
        await FileOps.createDirectoryIfNeeded(at: scratch)
        #expect(FileManager.default.fileExists(atPath: scratch.path))
    }

    @Test("removeItem deletes a directory tree and throws on missing paths")
    func removeItemSemantics() async throws {
        let scratch = try makeScratchDir()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let tree = scratch.appendingPathComponent("tree/sub")
        try await FileOps.createDirectory(at: tree)
        try "hello".write(to: tree.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)

        try await FileOps.removeItem(at: scratch.appendingPathComponent("tree"))
        #expect(!FileManager.default.fileExists(atPath: scratch.appendingPathComponent("tree").path))

        // Same error behavior as FileManager: missing item throws
        await #expect(throws: Error.self) {
            try await FileOps.removeItem(at: scratch.appendingPathComponent("does-not-exist"))
        }
    }

    @Test("removeItemIfPresent does not throw for a missing item")
    func removeItemIfPresentMissing() async throws {
        let scratch = try makeScratchDir()
        defer { try? FileManager.default.removeItem(at: scratch) }

        // Must be a no-op, not a crash or error
        await FileOps.removeItemIfPresent(at: scratch.appendingPathComponent("nope"))
        #expect(FileManager.default.fileExists(atPath: scratch.path))
    }

    @Test("contentsOfDirectory matches FileManager results")
    func contentsOfDirectoryMatches() async throws {
        let scratch = try makeScratchDir()
        defer { try? FileManager.default.removeItem(at: scratch) }

        for name in ["one.txt", "two.txt", "three.txt"] {
            try "x".write(to: scratch.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        let listed = try await FileOps.contentsOfDirectory(at: scratch)
        #expect(Set(listed.map(\.lastPathComponent)) == ["one.txt", "two.txt", "three.txt"])
    }

    @Test("background propagates the operation's return value and errors")
    func backgroundPropagation() async throws {
        let value = try await FileOps.background { 21 * 2 }
        #expect(value == 42)

        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            try await FileOps.background { throw Boom() }
        }
    }
}
