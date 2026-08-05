// ============================================================
// PluginCompilerTests.swift
// AROCLI - Tests for PluginCompiler pure helpers (issue #435)
// ============================================================
//
// #435 (follow-up to !351): the plugin pre-compilation pipeline needs real
// toolchains (swiftc, cargo, python) to run end-to-end, so it can't be
// exercised in a unit test. But two pieces are pure and deterministic — the
// Rust staticlib locator and the manifest language detection — and those are
// covered here without touching a compiler.

#if !os(Windows)

import Testing
import Foundation
@testable import AROCLI

@Suite("PluginCompiler — pure helpers (#435)")
struct PluginCompilerTests {

    /// Fresh scratch directory per test, removed by the caller's `defer`.
    private func makeScratchDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aro-plugincompiler-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func touch(_ url: URL) throws {
        try Data().write(to: url)
    }

    // MARK: - findRustStaticLib

    @Test("findRustStaticLib finds a lib*.a staticlib")
    func findsLibStaticLib() throws {
        let dir = try makeScratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try touch(dir.appendingPathComponent("libgreeter.a"))

        let found = PluginCompiler.findRustStaticLib(in: dir)
        #expect(found?.lastPathComponent == "libgreeter.a")
    }

    @Test("findRustStaticLib returns nil when the directory has no .a files")
    func nilWhenNoArchives() throws {
        let dir = try makeScratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try touch(dir.appendingPathComponent("greeter.rs"))
        try touch(dir.appendingPathComponent("Cargo.toml"))

        #expect(PluginCompiler.findRustStaticLib(in: dir) == nil)
    }

    @Test("findRustStaticLib returns nil for a non-existent directory")
    func nilForMissingDirectory() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("aro-does-not-exist-\(UUID().uuidString)")
        #expect(PluginCompiler.findRustStaticLib(in: missing) == nil)
    }

    @Test("findRustStaticLib ignores .a files without a lib prefix")
    func ignoresNonLibArchive() throws {
        let dir = try makeScratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // An archive that doesn't follow the lib*.a convention (cargo's
        // staticlib output is always lib-prefixed) must not be picked up.
        try touch(dir.appendingPathComponent("greeter.a"))

        #expect(PluginCompiler.findRustStaticLib(in: dir) == nil)
    }

    @Test("findRustStaticLib ignores lib-prefixed shared libs (.so / .dylib)")
    func ignoresSharedLibs() throws {
        let dir = try makeScratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try touch(dir.appendingPathComponent("libgreeter.so"))
        try touch(dir.appendingPathComponent("libgreeter.dylib"))

        // Only a static archive (.a) satisfies static linking; shared objects
        // must be rejected so we don't try to bake a .so into the binary.
        #expect(PluginCompiler.findRustStaticLib(in: dir) == nil)
    }

    @Test("findRustStaticLib picks the lib*.a among mixed artifacts")
    func picksArchiveAmongMixed() throws {
        let dir = try makeScratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try touch(dir.appendingPathComponent("libgreeter.so"))
        try touch(dir.appendingPathComponent("greeter.d"))
        try touch(dir.appendingPathComponent("libgreeter.a"))

        #expect(PluginCompiler.findRustStaticLib(in: dir)?.lastPathComponent == "libgreeter.a")
    }

    // MARK: - Manifest language detection

    @Test("manifestDeclaresPythonPlugin detects a python-plugin manifest")
    func detectsPythonPlugin() {
        let yaml = """
        name: markdown
        provides:
          - type: python-plugin
            path: src/
        """
        #expect(PluginCompiler.manifestDeclaresPythonPlugin(yaml))
        // A python plugin is not on the native static-link path.
        #expect(!PluginCompiler.manifestDeclaresNativePlugin(yaml))
    }

    @Test("manifestDeclaresNativePlugin detects each native plugin type")
    func detectsEachNativeType() {
        for type in ["swift-plugin", "c-plugin", "cpp-plugin", "rust-plugin"] {
            let yaml = "provides:\n  - type: \(type)\n"
            #expect(
                PluginCompiler.manifestDeclaresNativePlugin(yaml),
                "expected \(type) to be detected as native"
            )
            #expect(
                !PluginCompiler.manifestDeclaresPythonPlugin(yaml),
                "expected \(type) not to be detected as python"
            )
        }
    }

    @Test("cpp-plugin is not misread as c-plugin, and vice versa")
    func cppAndCAreDistinct() {
        // Both are "native", but the substring checks must not confuse them:
        // "cpp-plugin" does not contain the substring "c-plugin".
        let cpp = "type: cpp-plugin"
        let c = "type: c-plugin"
        #expect(PluginCompiler.manifestDeclaresNativePlugin(cpp))
        #expect(PluginCompiler.manifestDeclaresNativePlugin(c))
    }

    @Test("a feature-set-only manifest declares neither native nor python code")
    func featureSetOnlyManifest() {
        // Plugins that ship only .aro feature sets have nothing to link and
        // must be skipped by both branches.
        let yaml = """
        name: helpers
        version: 1.0.0
        handle: Helpers
        """
        #expect(!PluginCompiler.manifestDeclaresPythonPlugin(yaml))
        #expect(!PluginCompiler.manifestDeclaresNativePlugin(yaml))
    }

    @Test("empty manifest text declares nothing")
    func emptyManifest() {
        #expect(!PluginCompiler.manifestDeclaresPythonPlugin(""))
        #expect(!PluginCompiler.manifestDeclaresNativePlugin(""))
    }
}

#endif  // !os(Windows)
