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
import AROCompiler
import ARORuntime
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

    // MARK: - Link mode reaches the plugin stage (GitLab #815)

    @Test("--dynamic resolves to a dynamic link, and is the only way to get one")
    func dynamicFlagResolvesToDynamicLink() throws {
        #expect(try CompilationStrategy.resolveLinkMode(staticLink: false, dynamicLink: true) == .dynamicLink)
        // Static is the default, with or without the flag.
        #expect(try CompilationStrategy.resolveLinkMode(staticLink: false, dynamicLink: false) == .staticLink)
        #expect(try CompilationStrategy.resolveLinkMode(staticLink: true, dynamicLink: false) == .staticLink)
    }

    @Test("--static and --dynamic together are refused")
    func mutuallyExclusiveLinkFlags() {
        #expect(throws: (any Error).self) {
            _ = try CompilationStrategy.resolveLinkMode(staticLink: true, dynamicLink: true)
        }
    }

    @Test("the name baked into the binary is the one the runtime parses (#618)")
    func recordedLinkModeNamesRoundTrip() {
        // The compiler writes `recordedName` into the binary and the runtime
        // reads it back as an AROLinkMode. If these ever drift, a compiled
        // binary silently falls back to the interpreter default.
        #expect(AROLinkMode(rawValue: CCompiler.LinkMode.staticLink.recordedName) == .static)
        #expect(AROLinkMode(rawValue: CCompiler.LinkMode.dynamicLink.recordedName) == .dynamic)
    }

    // MARK: - findPluginSharedLibrary

    @Test("findPluginSharedLibrary finds a library the managed compile produced")
    func findsManagedPluginLibrary() throws {
        let dir = try makeScratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sources = dir.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let ext = PluginCompiler.sharedLibraryExtension
        try touch(sources.appendingPathComponent("libgreeter.\(ext)"))

        #expect(PluginCompiler.findPluginSharedLibrary(in: [dir])?.lastPathComponent == "libgreeter.\(ext)")
    }

    @Test("findPluginSharedLibrary returns nil when only sources are present")
    func noLibraryForSourcesOnly() throws {
        let dir = try makeScratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try touch(dir.appendingPathComponent("Package.swift"))
        try touch(dir.appendingPathComponent("plugin.yaml"))

        #expect(PluginCompiler.findPluginSharedLibrary(in: [dir]) == nil)
    }

    // MARK: - Embedded Python and the standalone contract (GitLab #608)

    /// A compiler configured for one link mode, with no plugin directories —
    /// the Python policy is decided from the link mode and the plugin names.
    private func compiler(linkMode: CCompiler.LinkMode) -> PluginCompiler {
        let nowhere = URL(fileURLWithPath: "/nonexistent-aro-plugin-dir")
        return PluginCompiler(
            sourcePluginsDir: nowhere,
            outputPluginsDir: nowhere,
            staticBuildDir: nowhere,
            linkMode: linkMode,
            verbose: false
        )
    }

    @Test("a --static build refuses a Python plugin")
    func staticBuildRefusesPythonPlugin() {
        // A standalone binary cannot carry an interpreter it resolved from the
        // build machine's paths; the build says so rather than the customer's
        // machine saying it later.
        #expect(throws: (any Error).self) {
            try compiler(linkMode: .staticLink)
                .reportEmbeddedPythonDependency(plugins: ["plugin-python-markdown"], python: nil)
        }
    }

    @Test("a --dynamic build allows a Python plugin")
    func dynamicBuildAllowsPythonPlugin() throws {
        // --dynamic already means "not one file"; a dependency on a local
        // Python is consistent with what it promises, and is warned about.
        try compiler(linkMode: .dynamicLink)
            .reportEmbeddedPythonDependency(plugins: ["plugin-python-markdown"], python: nil)
    }

    @Test("a build with no Python plugins is unaffected in either mode")
    func noPythonPluginsNoPolicy() throws {
        for mode in [CCompiler.LinkMode.staticLink, .dynamicLink] {
            try compiler(linkMode: mode).reportEmbeddedPythonDependency(plugins: [], python: nil)
        }
    }
}

#endif  // !os(Windows)
