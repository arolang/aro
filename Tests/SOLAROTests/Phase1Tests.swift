// ============================================================
// Phase1Tests.swift
// SOLARO — Phase 1 unit tests (project loading, layout sidecar)
// ============================================================

import XCTest
@testable import SOLARO

final class Phase1Tests: XCTestCase {

    // MARK: - ProjectModel.load

    func testProjectLoadDiscoversAroFiles() throws {
        let tmp = try makeProjectTree(files: [
            "main.aro": "(Application-Start: Probe) { Log \"hi\" to the <console>. }",
            "users.aro": "(createUser: User API) { Return an <OK: status> for the <result>. }",
            "sources/orders.aro": "(createOrder: Order API) { Return an <OK: status> for the <r>. }",
            "README.md": "ignore me",
        ])
        defer { try? FileManager.default.removeItem(at: tmp) }

        let project = Project(rootPath: tmp)
        let model = try ProjectModel.load(project)

        XCTAssertEqual(model.sourceFiles.count, 3)
        XCTAssertTrue(model.sourceFiles.contains { $0.lastPathComponent == "main.aro" })
        XCTAssertTrue(model.sourceFiles.contains { $0.lastPathComponent == "users.aro" })
        XCTAssertTrue(model.sourceFiles.contains { $0.lastPathComponent == "orders.aro" })
        XCTAssertNil(model.openAPISpec)
        XCTAssertTrue(model.storeFiles.isEmpty)
    }

    func testProjectLoadReadsOpenAPISpec() throws {
        let tmp = try makeProjectTree(files: [
            "main.aro": "(Application-Start: x) { Return an <OK: status> for the <r>. }",
            "openapi.yaml": "openapi: 3.0.3\ninfo: { title: t, version: '1' }",
        ])
        defer { try? FileManager.default.removeItem(at: tmp) }

        let project = Project(rootPath: tmp)
        let model = try ProjectModel.load(project)
        XCTAssertNotNil(model.openAPISpec)
        XCTAssertEqual(model.openAPISpec?.lastPathComponent, "openapi.yaml")
    }

    func testProjectLoadFindsStoreFiles() throws {
        let tmp = try makeProjectTree(files: [
            "main.aro": "(Application-Start: x) { Return an <OK: status> for the <r>. }",
            "products.store": "- name: A",
            "sessions.store": "- token: abc",
        ])
        defer { try? FileManager.default.removeItem(at: tmp) }

        let project = Project(rootPath: tmp)
        let model = try ProjectModel.load(project)
        XCTAssertEqual(model.storeFiles.count, 2)
    }

    func testProjectLoadEmptyProjectIsOK() throws {
        let tmp = try makeProjectTree(files: [:])
        defer { try? FileManager.default.removeItem(at: tmp) }

        let project = Project(rootPath: tmp)
        let model = try ProjectModel.load(project)
        XCTAssertTrue(model.sourceFiles.isEmpty)
        XCTAssertNil(model.openAPISpec)
    }

    // MARK: - LayoutSidecar

    func testLayoutSidecarDefaultPaneMode() {
        let sidecar = LayoutSidecar()
        XCTAssertEqual(sidecar.paneMode, .canvas)
    }

    func testLayoutSidecarRoundTripsThroughDisk() throws {
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
        XCTAssertEqual(reloaded.paneMode, .split)
        XCTAssertEqual(reloaded.view.zoom, 1.5)
    }

    func testLayoutSidecarLoadMissingIsDefault() {
        let url = URL(fileURLWithPath: "/tmp/never-exists-\(UUID().uuidString).aro")
        let sidecar = LayoutSidecar.load(for: url)
        XCTAssertEqual(sidecar.paneMode, .canvas)
    }

    func testLayoutSidecarFilenameConvention() {
        let source = URL(fileURLWithPath: "/tmp/MyApp/users.aro")
        let sidecar = LayoutSidecar.sidecarURL(for: source)
        XCTAssertEqual(sidecar.lastPathComponent, "users.aro.layout.json")
        XCTAssertEqual(sidecar.deletingLastPathComponent().path, "/tmp/MyApp")
    }

    // MARK: - SourceFileState

    func testSourceFileStateParsesValidProgram() throws {
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
        XCTAssertNotNil(state.program)
        XCTAssertEqual(state.program?.featureSets.first?.name, "Application-Start")
        XCTAssertEqual(state.program?.featureSets.first?.businessActivity, "Entry Point")
        XCTAssertTrue(state.diagnostics.isEmpty)
    }

    func testSourceFileStateReparsesAfterEdit() throws {
        let tmp = try makeProjectTree(files: [
            "main.aro": "(Application-Start: x) { Return an <OK: status> for the <r>. }",
        ])
        defer { try? FileManager.default.removeItem(at: tmp) }
        let state = SourceFileState(url: tmp.appendingPathComponent("main.aro"))
        XCTAssertNotNil(state.program)

        state.text = "this is not valid aro syntax;;;"
        state.reparse()
        // Either program is nil OR diagnostics are present.
        XCTAssertTrue(state.program == nil || !state.diagnostics.isEmpty)
    }

    // MARK: - Helpers

    private func makeProjectTree(files: [String: String]) throws -> URL {
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
}
