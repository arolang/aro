// ============================================================
// Phase1Tests.swift
// SOLARO — project loading + layout sidecar (Swift Testing)
// ============================================================

import Testing
import Foundation
@testable import SOLARO

// Shared helper — re-used by Phase 1 / Phase 3 / FileTreeTests.
func makeProjectTree(files: [String: String]) throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("solaro-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for (relPath, body) in files {
        let url = root.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try body.write(to: url, atomically: true, encoding: .utf8)
    }
    return root
}

@Suite("ProjectModel.load")
struct ProjectModelLoadTests {

    @Test func discoversAroFiles() throws {
        let tmp = try makeProjectTree(files: [
            "main.aro": "(Application-Start: Probe) { Log \"hi\" to the <console>. }",
            "users.aro": "(createUser: User API) { Return an <OK: status> for the <result>. }",
            "sources/orders.aro": "(createOrder: Order API) { Return an <OK: status> for the <r>. }",
            "README.md": "ignore me",
        ])
        defer { try? FileManager.default.removeItem(at: tmp) }

        let model = try ProjectModel.load(Project(rootPath: tmp))

        #expect(model.sourceFiles.count == 3)
        #expect(model.sourceFiles.contains { $0.lastPathComponent == "main.aro" })
        #expect(model.sourceFiles.contains { $0.lastPathComponent == "users.aro" })
        #expect(model.sourceFiles.contains { $0.lastPathComponent == "orders.aro" })
        #expect(model.openAPISpec == nil)
        #expect(model.storeFiles.isEmpty)
    }

    @Test func readsOpenAPISpec() throws {
        let tmp = try makeProjectTree(files: [
            "main.aro": "(Application-Start: x) { Return an <OK: status> for the <r>. }",
            "openapi.yaml": "openapi: 3.0.3\ninfo: { title: t, version: '1' }",
        ])
        defer { try? FileManager.default.removeItem(at: tmp) }

        let model = try ProjectModel.load(Project(rootPath: tmp))
        #expect(model.openAPISpec != nil)
        #expect(model.openAPISpec?.lastPathComponent == "openapi.yaml")
    }

    @Test func findsStoreFiles() throws {
        let tmp = try makeProjectTree(files: [
            "main.aro": "(Application-Start: x) { Return an <OK: status> for the <r>. }",
            "products.store": "- name: A",
            "sessions.store": "- token: abc",
        ])
        defer { try? FileManager.default.removeItem(at: tmp) }

        let model = try ProjectModel.load(Project(rootPath: tmp))
        #expect(model.storeFiles.count == 2)
    }

    @Test func emptyProjectIsOK() throws {
        let tmp = try makeProjectTree(files: [:])
        defer { try? FileManager.default.removeItem(at: tmp) }

        let model = try ProjectModel.load(Project(rootPath: tmp))
        #expect(model.sourceFiles.isEmpty)
        #expect(model.openAPISpec == nil)
    }
}

@Suite("LayoutSidecar")
struct LayoutSidecarTests {

    @Test func defaultPaneModeIsText() {
        // Phase 7: default flipped from .canvas to .text so new
        // files open in the always-implemented text editor.
        let sidecar = LayoutSidecar()
        #expect(sidecar.paneMode == .text)
    }

    @Test func roundTripsThroughDisk() throws {
        let tmp = try makeProjectTree(files: [
            "main.aro": "(Application-Start: x) { Return an <OK: status> for the <r>. }",
        ])
        defer { try? FileManager.default.removeItem(at: tmp) }
        let source = tmp.appendingPathComponent("main.aro")

        var sidecar = LayoutSidecar()
        sidecar.paneMode = .split
        sidecar.view.zoom = 1.5
        try sidecar.save(for: source)

        let reloaded = LayoutSidecar.load(for: source)
        #expect(reloaded.paneMode == .split)
        #expect(reloaded.view.zoom == 1.5)
    }

    @Test func loadingMissingFileReturnsDefault() {
        let url = URL(fileURLWithPath: "/tmp/never-exists-\(UUID().uuidString).aro")
        let sidecar = LayoutSidecar.load(for: url)
        #expect(sidecar.paneMode == .text)
    }

    @Test func filenameConventionIsDoubleExtension() {
        let source = URL(fileURLWithPath: "/tmp/MyApp/users.aro")
        let sidecar = LayoutSidecar.sidecarURL(for: source)
        #expect(sidecar.lastPathComponent == "users.aro.layout.json")
        #expect(sidecar.deletingLastPathComponent().path == "/tmp/MyApp")
    }
}

@Suite("SourceFileState")
struct SourceFileStateTests {

    @Test func parsesValidProgram() throws {
        let tmp = try makeProjectTree(files: [
            "main.aro": """
            (Application-Start: Entry Point) {
                Log "Hello" to the <console>.
                Return an <OK: status> for the <application>.
            }
            """,
        ])
        defer { try? FileManager.default.removeItem(at: tmp) }
        let state = SourceFileState(url: tmp.appendingPathComponent("main.aro"))
        #expect(state.program != nil)
        #expect(state.program?.featureSets.first?.name == "Application-Start")
        #expect(state.program?.featureSets.first?.businessActivity == "Entry Point")
        #expect(state.diagnostics.isEmpty)
    }

    @Test func reparsesAfterEdit() throws {
        let tmp = try makeProjectTree(files: [
            "main.aro": "(Application-Start: x) { Return an <OK: status> for the <r>. }",
        ])
        defer { try? FileManager.default.removeItem(at: tmp) }
        let state = SourceFileState(url: tmp.appendingPathComponent("main.aro"))
        #expect(state.program != nil)

        state.text = "this is not valid aro syntax;;;"
        state.reparse()
        #expect(state.program == nil || !state.diagnostics.isEmpty)
    }
}
