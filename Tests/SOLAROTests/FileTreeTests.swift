// ============================================================
// FileTreeTests.swift
// SOLARO — Phase 5: sidebar tree-building regression coverage
// ============================================================

import XCTest
@testable import SOLARO

final class FileTreeTests: XCTestCase {

    // MARK: - Helpers

    private func makeProject(at: URL, layout: [String]) throws -> ProjectModel {
        let fm = FileManager.default
        try fm.createDirectory(at: at, withIntermediateDirectories: true)
        for rel in layout {
            let url = at.appendingPathComponent(rel)
            try fm.createDirectory(at: url.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        return try ProjectModel.load(Project(rootPath: at))
    }

    private func tmp() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("solaro-filetree-\(UUID().uuidString)")
        return dir
    }

    // MARK: - Cases

    func testFlatProjectProducesLeafNodes() throws {
        let project = try makeProject(at: tmp(), layout: ["main.aro"])
        let nodes = FileTreeBuilder.build(model: project)
        XCTAssertEqual(nodes.count, 1)
        XCTAssertEqual(nodes[0].name, "main.aro")
        XCTAssertEqual(nodes[0].kind, .aroSource)
        XCTAssertNil(nodes[0].outlineChildren)
    }

    func testNestedSourcesProduceDisclosureGroup() throws {
        let project = try makeProject(at: tmp(), layout: [
            "main.aro",
            "sources/users/users.aro",
            "sources/orders/orders.aro",
        ])
        let nodes = FileTreeBuilder.build(model: project)

        // Directories first, files after — so `sources/` is at index 0.
        XCTAssertEqual(nodes.first?.name, "sources")
        XCTAssertEqual(nodes.first?.kind, .directory)

        // Each subdirectory itself contains one file leaf.
        let sources = nodes.first!
        let subNames = Set(sources.children.map(\.name))
        XCTAssertEqual(subNames, Set(["users", "orders"]))
        for child in sources.children {
            XCTAssertEqual(child.kind, .directory)
            XCTAssertEqual(child.children.count, 1)
            XCTAssertEqual(child.children.first?.kind, .aroSource)
        }

        // The root file `main.aro` is the last entry — files after dirs.
        XCTAssertEqual(nodes.last?.name, "main.aro")
    }

    func testOpenAPISpecBubblesToTopOfFileGroup() throws {
        let root = tmp()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("main.aro"))
        try Data().write(to: root.appendingPathComponent("openapi.yaml"))
        let project = try ProjectModel.load(Project(rootPath: root))

        let nodes = FileTreeBuilder.build(model: project)
        // `openapi.yaml` precedes `main.aro` even though alphabetic
        // order would have put `main.aro` first.
        XCTAssertEqual(nodes.first?.name, "openapi.yaml")
        XCTAssertEqual(nodes.first?.kind, .openapi)
    }

    func testStoreFilesAreIncluded() throws {
        let root = tmp()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("main.aro"))
        try Data().write(to: root.appendingPathComponent("products.store"))
        let project = try ProjectModel.load(Project(rootPath: root))

        let nodes = FileTreeBuilder.build(model: project)
        XCTAssertEqual(nodes.count, 2)
        XCTAssertTrue(nodes.contains { $0.kind == .storeFile && $0.name == "products.store" })
        XCTAssertTrue(nodes.contains { $0.kind == .aroSource && $0.name == "main.aro" })
    }

    func testDirectoriesAreSortedBeforeFiles() throws {
        let project = try makeProject(at: tmp(), layout: [
            "z-main.aro",            // file
            "a-sources/users.aro",   // dir
        ])
        let nodes = FileTreeBuilder.build(model: project)
        XCTAssertEqual(nodes.first?.kind, .directory)
        XCTAssertEqual(nodes.last?.kind, .aroSource)
    }
}
