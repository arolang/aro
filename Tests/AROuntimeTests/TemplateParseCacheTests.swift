// ============================================================
// TemplateParseCacheTests.swift
// ARO Runtime - Template Parse Cache Tests (Issue #160)
// ============================================================

import Foundation
import Testing
@testable import ARORuntime
@testable import AROParser

// MARK: - Template Parse Cache Tests

@Suite("Template Parse Cache Tests")
struct TemplateParseCacheTests {

    // MARK: - Helpers

    private func makeService(dir: String) -> AROTemplateService {
        AROTemplateService(templatesDirectory: dir)
    }

    private func writeTemplate(at path: String, content: String) throws {
        try content.write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: - File-system caching

    @Test("First render reads from disk and caches the parse result")
    func testFirstRenderCachesParseResult() async throws {
        let dir = NSTemporaryDirectory() + "aro_cache_test_\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let filePath = dir + "hello.screen"
        try writeTemplate(at: filePath, content: "Hello, {{ <name> }}!")

        let service = makeService(dir: dir)
        let registry = ActionRegistry.shared
        let eventBus = EventBus()
        let executor = TemplateExecutor(actionRegistry: registry, eventBus: eventBus)
        service.setExecutor(executor)

        let ctx = RuntimeContext(featureSetName: "test", businessActivity: "test")
        ctx.bind("name", value: "World")

        let result1 = try await service.render(path: "hello.screen", context: ctx)
        #expect(result1 == "Hello, World!")

        // Render a second time — should use cached parse result (same output)
        let result2 = try await service.render(path: "hello.screen", context: ctx)
        #expect(result2 == "Hello, World!")
    }

    @Test("Cache is invalidated when file mtime changes")
    func testCacheInvalidatedOnMtimeChange() async throws {
        let dir = NSTemporaryDirectory() + "aro_cache_mtime_\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let filePath = dir + "dynamic.screen"
        try writeTemplate(at: filePath, content: "Version 1")

        let service = makeService(dir: dir)
        let registry = ActionRegistry.shared
        let eventBus = EventBus()
        let executor = TemplateExecutor(actionRegistry: registry, eventBus: eventBus)
        service.setExecutor(executor)

        let ctx = RuntimeContext(featureSetName: "test", businessActivity: "test")

        let result1 = try await service.render(path: "dynamic.screen", context: ctx)
        #expect(result1 == "Version 1")

        // Simulate file update: write new content and bump mtime by 1 second
        // Use a small sleep to ensure the mtime is different
        try await Task.sleep(for: .seconds(1))
        try writeTemplate(at: filePath, content: "Version 2")

        let result2 = try await service.render(path: "dynamic.screen", context: ctx)
        #expect(result2 == "Version 2")
    }

    @Test("Multiple templates are cached independently (path-keying)")
    func testMultipleTemplatesCachedIndependently() async throws {
        let dir = NSTemporaryDirectory() + "aro_cache_multi_\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        try writeTemplate(at: dir + "a.screen", content: "Template A")
        try writeTemplate(at: dir + "b.screen", content: "Template B")

        let service = makeService(dir: dir)
        let registry = ActionRegistry.shared
        let eventBus = EventBus()
        let executor = TemplateExecutor(actionRegistry: registry, eventBus: eventBus)
        service.setExecutor(executor)

        let ctx = RuntimeContext(featureSetName: "test", businessActivity: "test")

        let a1 = try await service.render(path: "a.screen", context: ctx)
        let b1 = try await service.render(path: "b.screen", context: ctx)
        #expect(a1 == "Template A")
        #expect(b1 == "Template B")

        // Second pass — each path returns its own cached result
        let a2 = try await service.render(path: "a.screen", context: ctx)
        let b2 = try await service.render(path: "b.screen", context: ctx)
        #expect(a2 == "Template A")
        #expect(b2 == "Template B")
    }

    // MARK: - Registered template caching

    @Test("Registered templates are cached unconditionally")
    func testRegisteredTemplateCachedUnconditionally() async throws {
        let service = makeService(dir: "/nonexistent")
        let registry = ActionRegistry.shared
        let eventBus = EventBus()
        let executor = TemplateExecutor(actionRegistry: registry, eventBus: eventBus)
        service.setExecutor(executor)

        service.registerEmbeddedTemplate(path: "greet.screen", content: "Hello, {{ <name> }}!")

        // Give the Task time to register
        try await Task.sleep(for: .milliseconds(100))

        let ctx = RuntimeContext(featureSetName: "test", businessActivity: "test")
        ctx.bind("name", value: "ARO")

        let result1 = try await service.render(path: "greet.screen", context: ctx)
        #expect(result1 == "Hello, ARO!")

        // Second render hits cache, same result
        let result2 = try await service.render(path: "greet.screen", context: ctx)
        #expect(result2 == "Hello, ARO!")
    }

    // MARK: - renderAndTrack uses cache

    @Test("renderAndTrack also benefits from parse cache")
    func testRenderAndTrackUsesCacheOk() async throws {
        let dir = NSTemporaryDirectory() + "aro_cache_track_\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let filePath = dir + "track.screen"
        try writeTemplate(at: filePath, content: "Tracking {{ <val> }}")

        let service = makeService(dir: dir)
        let registry = ActionRegistry.shared
        let eventBus = EventBus()
        let executor = TemplateExecutor(actionRegistry: registry, eventBus: eventBus)
        service.setExecutor(executor)

        let ctx = RuntimeContext(featureSetName: "test", businessActivity: "test")
        ctx.bind("val", value: "42")

        let (rendered, positions) = try await service.renderAndTrack(path: "track.screen", context: ctx)
        #expect(rendered == "Tracking 42")
        #expect(positions["val"] != nil)

        // Second call re-uses cache
        let (rendered2, _) = try await service.renderAndTrack(path: "track.screen", context: ctx)
        #expect(rendered2 == "Tracking 42")
    }
}
