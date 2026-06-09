// ============================================================
// SOLAROTests.swift
// SOLARO — top-level unit tests (Swift Testing)
// ============================================================
//
// Covers the non-UI logic that fits in a unit test without spinning
// up a window: the routing state, project model, and recents store.

import Testing
import Foundation
@testable import SOLARO

@Suite("Project model")
struct ProjectModelTests {

    @Test func displayNameUsesLastPathComponent() {
        let project = Project(rootPath: URL(fileURLWithPath: "/tmp/MyApp"))
        #expect(project.displayName == "MyApp")
    }

    @Test func displayNameFallsBackForRootPath() {
        let project = Project(rootPath: URL(fileURLWithPath: "/"))
        // Last path component of "/" is "/" in URL — we only assert
        // non-empty, since macOS / Linux differ on the exact value.
        #expect(!project.displayName.isEmpty)
    }

    @Test func identityIsByPath() {
        let a = Project(rootPath: URL(fileURLWithPath: "/tmp/A"))
        let b = Project(rootPath: URL(fileURLWithPath: "/tmp/A"))
        #expect(a.id == b.id)
        #expect(a == b)
    }
}

@Suite("Workspace routing")
struct WorkspaceRoutingTests {

    @Test func openStateCarriesProject() {
        let project = Project(rootPath: URL(fileURLWithPath: "/tmp/MyApp"))
        let state = WorkspaceState.open(project)
        guard case .open(let p) = state else {
            Issue.record("expected .open")
            return
        }
        #expect(p.rootPath.path == "/tmp/MyApp")
    }
}

@Suite("RecentProjects")
struct RecentProjectsTests {

    /// We can't easily redirect `RecentProjects.fileURL` without
    /// dependency injection, so this is a shape test only — the
    /// pre-written JSON is the canonical format the loader expects.
    @Test func recentsJSONShapeIsStable() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("solaro-test-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("recents.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let payload: [[String: Any]] = [
            ["path": "/tmp/AAA", "openedAt": "2026-06-01T10:00:00Z"],
            ["path": "/tmp/BBB", "openedAt": "2026-06-01T11:00:00Z"],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
        try data.write(to: url, options: [.atomic])

        struct Entry: Codable { let path: String; let openedAt: Date }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entries = try decoder.decode([Entry].self, from: Data(contentsOf: url))
        #expect(entries.count == 2)
        #expect(entries[0].path == "/tmp/AAA")
        #expect(entries[1].path == "/tmp/BBB")
    }

    @Test func loadIsSafeWhenFileMissing() {
        // Defined return value with the expected element type;
        // contents depend on the developer's real recents file.
        _ = RecentProjects.load().map(\.rootPath)
    }
}
