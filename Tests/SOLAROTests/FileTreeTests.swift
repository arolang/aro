// ============================================================
// FileTreeTests.swift
// SOLARO — sidebar tree-building regression (Swift Testing)
// ============================================================

import Testing
import Foundation
@testable import SOLARO

@Suite("FileTreeBuilder")
struct FileTreeBuilderTests {

    // MARK: - Helpers

    private func makeProject(at root: URL, layout: [String]) throws -> ProjectModel {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        for rel in layout {
            let url = root.appendingPathComponent(rel)
            try fm.createDirectory(at: url.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        return try ProjectModel.load(Project(rootPath: root))
    }

    private func tmp() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("solaro-filetree-\(UUID().uuidString)")
    }

    // MARK: - Cases

    @Test func flatProjectProducesLeafNodes() throws {
        let project = try makeProject(at: tmp(), layout: ["main.aro"])
        let nodes = FileTreeBuilder.build(model: project)
        #expect(nodes.count == 1)
        #expect(nodes[0].name == "main.aro")
        #expect(nodes[0].kind == .aroSource)
        #expect(nodes[0].outlineChildren == nil)
    }

    @Test func nestedSourcesProduceDisclosureGroup() throws {
        let project = try makeProject(at: tmp(), layout: [
            "main.aro",
            "sources/users/users.aro",
            "sources/orders/orders.aro",
        ])
        let nodes = FileTreeBuilder.build(model: project)

        #expect(nodes.first?.name == "sources")
        #expect(nodes.first?.kind == .directory)

        let sources = try #require(nodes.first)
        let subNames = Set(sources.children.map(\.name))
        #expect(subNames == Set(["users", "orders"]))
        for child in sources.children {
            #expect(child.kind == .directory)
            #expect(child.children.count == 1)
            #expect(child.children.first?.kind == .aroSource)
        }

        #expect(nodes.last?.name == "main.aro")
    }

    @Test func openAPISpecBubblesToTopOfFileGroup() throws {
        let root = tmp()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("main.aro"))
        try Data().write(to: root.appendingPathComponent("openapi.yaml"))
        let project = try ProjectModel.load(Project(rootPath: root))

        let nodes = FileTreeBuilder.build(model: project)
        #expect(nodes.first?.name == "openapi.yaml")
        #expect(nodes.first?.kind == .openapi)
    }

    @Test func storeFilesAreIncluded() throws {
        let root = tmp()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("main.aro"))
        try Data().write(to: root.appendingPathComponent("products.store"))
        let project = try ProjectModel.load(Project(rootPath: root))

        let nodes = FileTreeBuilder.build(model: project)
        #expect(nodes.count == 2)
        #expect(nodes.contains { $0.kind == .storeFile && $0.name == "products.store" })
        #expect(nodes.contains { $0.kind == .aroSource && $0.name == "main.aro" })
    }

    /// #488 — markdown docs are part of the project view so the
    /// rendered inline editor is reachable without flipping the
    /// Files tab into "All files".
    @Test func markdownFilesAreIncluded() throws {
        let project = try makeProject(at: tmp(), layout: [
            "main.aro",
            "README.md",
            "docs/guide.markdown",
        ])
        let nodes = FileTreeBuilder.build(model: project)
        #expect(nodes.contains { $0.kind == .markdown && $0.name == "README.md" })
        let docs = try #require(nodes.first { $0.name == "docs" })
        #expect(docs.children.contains {
            $0.kind == .markdown && $0.name == "guide.markdown"
        })
    }

    @Test func buildDirectoriesAreNotScannedForMarkdown() throws {
        let root = tmp()
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent(".build"),
                               withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("main.aro"))
        try Data().write(to: root.appendingPathComponent(".build/NOTES.md"))
        let project = try ProjectModel.load(Project(rootPath: root))

        let nodes = FileTreeBuilder.build(model: project)
        #expect(!nodes.contains { $0.name == ".build" })
        #expect(!nodes.contains { $0.kind == .markdown })
    }

    @Test func directoriesSortBeforeFiles() throws {
        let project = try makeProject(at: tmp(), layout: [
            "z-main.aro",
            "a-sources/users.aro",
        ])
        let nodes = FileTreeBuilder.build(model: project)
        #expect(nodes.first?.kind == .directory)
        #expect(nodes.last?.kind == .aroSource)
    }
}
