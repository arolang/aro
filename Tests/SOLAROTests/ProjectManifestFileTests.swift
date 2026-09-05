// ============================================================
// ProjectManifestFileTests.swift
// SOLARO — aro.yaml / <name>.aroproject equivalence
// ============================================================

import Testing
import Foundation
@testable import SOLARO

@Suite("ProjectManifestFile")
struct ProjectManifestFileTests {

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aro-manifest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Both spellings are manifests; other YAML is not")
    func recognition() {
        let base = URL(fileURLWithPath: "/tmp/p")
        #expect(ProjectManifestFile.isManifest(base.appendingPathComponent("aro.yaml")))
        #expect(ProjectManifestFile.isManifest(base.appendingPathComponent("aro.yml")))
        #expect(ProjectManifestFile.isManifest(base.appendingPathComponent("Shop.aroproject")))
        #expect(ProjectManifestFile.isManifest(base.appendingPathComponent("shop.AROPROJECT")))
        #expect(!ProjectManifestFile.isManifest(base.appendingPathComponent("openapi.yaml")))
        #expect(!ProjectManifestFile.isManifest(base.appendingPathComponent("menu.yaml")))
        #expect(!ProjectManifestFile.isManifest(base.appendingPathComponent("main.aro")))
    }

    @Test("find() prefers the canonical name, falls back to .aroproject")
    func findPrecedence() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(ProjectManifestFile.find(in: dir) == nil)

        let dedicated = dir.appendingPathComponent("Shop.aroproject")
        try "name: shop\n".write(to: dedicated, atomically: true, encoding: .utf8)
        #expect(ProjectManifestFile.find(in: dir)?.lastPathComponent == "Shop.aroproject")

        let canonical = dir.appendingPathComponent("aro.yaml")
        try "name: shop\n".write(to: canonical, atomically: true, encoding: .utf8)
        #expect(ProjectManifestFile.find(in: dir)?.lastPathComponent == "aro.yaml")
    }

    @Test("The file tree classifies .aroproject as the project manifest")
    func fileTreeClassification() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "name: shop\n".write(
            to: dir.appendingPathComponent("Shop.aroproject"),
            atomically: true, encoding: .utf8)
        try "(X: Interactive) {\n}\n".write(
            to: dir.appendingPathComponent("main.aro"),
            atomically: true, encoding: .utf8)

        let model = try ProjectModel.load(Project(rootPath: dir))
        let tree = FileTreeBuilder.build(model: model)
        let manifest = tree.first { $0.kind == .projectManifest }
        #expect(manifest?.name == "Shop.aroproject")
    }
}
