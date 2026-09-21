// ============================================================
// CanvasGraphCacheTests.swift
// SOLARO — the canvas graph is built on change, not per frame (#749)
// ============================================================

import Testing
import Foundation
@testable import SOLARO

@Suite("Canvas graph cache")
struct CanvasGraphCacheTests {

    /// The cache is asked only whether to rebuild, so the graph's contents
    /// are irrelevant here — what each test counts is how often the closure
    /// that would do the expensive work actually runs.
    private var emptyGraph: CanvasGraph {
        CanvasGraph(nodes: [], edges: [])
    }

    private func temporaryProject() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("solaro-canvas-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
        // A project marker, so `ProjectLayoutStore.storeURL` stops its
        // upward walk here. Without one it climbs past the temp
        // directory into a shared ancestor, and two tests running in
        // parallel then stamp against the same `.layout.json`.
        try Data("openapi: 3.0.3\n".utf8)
            .write(to: root.appendingPathComponent("openapi.yaml"))
        return root
    }

    @Test func buildsOnceAndThenServesTheCachedGraph() throws {
        let root = try temporaryProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("main.aro")

        var cache = CanvasGraphCache()
        var builds = 0
        for _ in 0..<50 {
            _ = cache.graph(for: file) { builds += 1; return emptyGraph }
        }
        // Fifty body passes — an event-heavy second of a run — one build.
        #expect(builds == 1)
    }

    @Test func aReparseRetiresTheCachedGraph() throws {
        let root = try temporaryProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("main.aro")

        var cache = CanvasGraphCache()
        var builds = 0
        _ = cache.graph(for: file) { builds += 1; return emptyGraph }
        cache.noteProgramsChanged()
        _ = cache.graph(for: file) { builds += 1; return emptyGraph }

        #expect(builds == 2)
    }

    @Test func aSidecarWriteRetiresTheCachedGraph() throws {
        let root = try temporaryProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("main.aro")

        var cache = CanvasGraphCache()
        var builds = 0
        _ = cache.graph(for: file) { builds += 1; return emptyGraph }
        // Dragging a node writes positions; the graph that reads them is
        // stale even though the program did not change.
        cache.noteSidecarChanged()
        _ = cache.graph(for: file) { builds += 1; return emptyGraph }

        #expect(builds == 2)
    }

    @Test func aSidecarAppearingOnDiskIsNoticedWithoutBeingTold() throws {
        let root = try temporaryProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("main.aro")

        var cache = CanvasGraphCache()
        var builds = 0
        // No sidecar yet — the common case, and it must still cache.
        _ = cache.graph(for: file) { builds += 1; return emptyGraph }
        _ = cache.graph(for: file) { builds += 1; return emptyGraph }
        #expect(builds == 1)

        // Another process writes the layout store. The stamp is taken from
        // the file itself, so this is caught with nobody announcing it.
        let store = ProjectLayoutStore.storeURL(for: file)
        try Data("{}".utf8).write(to: store)
        _ = cache.graph(for: file) { builds += 1; return emptyGraph }
        #expect(builds == 2)
    }

    @Test func separateFilesAreCachedSeparately() throws {
        let root = try temporaryProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("users.aro")
        let second = root.appendingPathComponent("orders.aro")

        var cache = CanvasGraphCache()
        var builds = 0
        _ = cache.graph(for: first) { builds += 1; return emptyGraph }
        _ = cache.graph(for: second) { builds += 1; return emptyGraph }
        // Switching back must not rebuild — tab switching is frequent.
        _ = cache.graph(for: first) { builds += 1; return emptyGraph }
        #expect(builds == 2)
    }
}
