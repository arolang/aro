// ============================================================
// ContextStoreTests.swift
// ============================================================

import XCTest
@testable import AROLM

final class ContextStoreTests: XCTestCase {
    func testLoadOrCreateProducesSystemPrompt() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ContextStore(workingDirectory: dir)
        let context = try store.loadOrCreate(model: "test/model")
        XCTAssertEqual(context.messages.first?.role, "system")
        XCTAssertTrue(context.messages.first?.content?.contains("ARO") ?? false)
    }

    func testSaveRoundTrip() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ContextStore(workingDirectory: dir)
        var context = try store.loadOrCreate(model: "test/model")
        context.messages.append(LMMessage(role: "user", content: "hello"))
        try store.save(context)
        let loaded = try store.load()
        XCTAssertEqual(loaded?.messages.last?.role, "user")
        XCTAssertEqual(loaded?.messages.last?.content, "hello")
    }

    func testClearRemovesFile() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ContextStore(workingDirectory: dir)
        let context = try store.loadOrCreate(model: "test/model")
        try store.save(context)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.contextPath.path))
        XCTAssertTrue(try store.clear())
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.contextPath.path))
    }

    private func makeTempDir() -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("aro-lm-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
}
