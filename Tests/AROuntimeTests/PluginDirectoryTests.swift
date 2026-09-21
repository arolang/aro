// ============================================================
// PluginDirectoryTests.swift
// ARORuntime — one plugin directory, everywhere (GitLab #848)
// ============================================================
//
// A project's plugins were found by two loaders looking for two names
// that differ only in case: `Plugins/` for manifest-bearing plugins and
// `plugins/` for loose files and manifest-less packages. On macOS and
// Windows those are one directory, so both loaders walked it and one
// succeeded. On Linux they are two, and only the matching loader ran —
// so a project loaded a different set of plugins depending on the
// developer's filesystem, and three shipped examples depended on it.

import Testing
import Foundation
@testable import ARORuntime

@Suite("Plugin directory")
struct PluginDirectoryTests {

    private func project(_ subdirectories: [String]) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aro-plugindir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
        for name in subdirectories {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(name),
                withIntermediateDirectories: true)
        }
        return root
    }

    /// True when this machine's temp volume is case-insensitive, which
    /// decides what half of these tests can even be set up.
    private func isCaseInsensitive(_ root: URL) -> Bool {
        let probe = root.appendingPathComponent("CaseProbe")
        try? FileManager.default.createDirectory(at: probe,
                                                 withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: probe) }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: root.appendingPathComponent("caseprobe").path,
            isDirectory: &isDir)
    }

    @Test func aProjectWithNoPluginsResolvesToNothing() throws {
        let root = try project([])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(PluginDirectory.resolve(in: root) == nil)
    }

    @Test func theCanonicalSpellingIsFound() throws {
        let root = try project(["Plugins"])
        defer { try? FileManager.default.removeItem(at: root) }
        let resolved = try #require(PluginDirectory.resolve(in: root))
        #expect(resolved.spelling == .canonical)
        #expect(resolved.url.lastPathComponent == "Plugins")
    }

    @Test func theLegacySpellingIsFoundAndReportedAsLegacy() throws {
        let root = try project([])
        defer { try? FileManager.default.removeItem(at: root) }
        // Created directly so a case-insensitive volume does not turn
        // this into the canonical name behind our back.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("plugins"),
            withIntermediateDirectories: true)

        let resolved = try #require(PluginDirectory.resolve(in: root))
        // On a case-insensitive volume this directory answers to both
        // names, and the canonical one is the right thing to report.
        if isCaseInsensitive(root) {
            #expect(resolved.spelling == .canonical)
        } else {
            #expect(resolved.spelling == .legacy)
            #expect(resolved.url.lastPathComponent == "plugins")
        }
    }

    @Test func aFileNamedPluginsIsNotADirectory() throws {
        let root = try project([])
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("not a directory".utf8)
            .write(to: root.appendingPathComponent("Plugins"))
        // `fileExists` alone would say yes, and the loader would then
        // fail listing its contents.
        #expect(PluginDirectory.resolve(in: root) == nil)
    }

    @Test func oneDirectoryUnderTwoNamesIsReportedOnce() throws {
        let root = try project(["Plugins"])
        defer { try? FileManager.default.removeItem(at: root) }
        guard isCaseInsensitive(root) else { return }

        // This is the macOS situation the bug hid in: both names exist
        // as far as `fileExists` is concerned, and loading both would
        // load every plugin twice.
        #expect(PluginDirectory.sameDirectory(
            root.appendingPathComponent("Plugins"),
            root.appendingPathComponent("plugins")))
        let resolved = try #require(PluginDirectory.resolve(in: root))
        #expect(resolved.spelling == .canonical)
        #expect(PluginDirectory.shadowedDirectory(in: root) == nil)
    }

    @Test func twoGenuinelyDifferentDirectoriesPreferTheCanonicalOne() throws {
        let root = try project(["Plugins"])
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(
            at: root.appendingPathComponent("plugins"),
            withIntermediateDirectories: true)
        guard !isCaseInsensitive(root) else { return }  // Linux only

        let resolved = try #require(PluginDirectory.resolve(in: root))
        #expect(resolved.spelling == .canonical)
        // And the other one is named, rather than silently ignored.
        #expect(PluginDirectory.shadowedDirectory(in: root)?.lastPathComponent
                == "plugins")
    }

    @Test func distinctDirectoriesAreNotTheSameDirectory() throws {
        let root = try project(["Plugins", "Sources"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!PluginDirectory.sameDirectory(
            root.appendingPathComponent("Plugins"),
            root.appendingPathComponent("Sources")))
    }

    @Test func aSymlinkToThePluginDirectoryIsTheSameDirectory() throws {
        let root = try project(["Plugins"])
        defer { try? FileManager.default.removeItem(at: root) }
        let link = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: root.appendingPathComponent("Plugins"))
        #expect(PluginDirectory.sameDirectory(
            root.appendingPathComponent("Plugins"), link))
    }

    @Test func theDeprecationWarningNamesBothSpellingsAndTheProject() throws {
        let root = try project([])
        defer { try? FileManager.default.removeItem(at: root) }
        let warning = PluginDirectory.deprecationWarning(for: root)
        #expect(warning.contains("plugins/"))
        #expect(warning.contains("Plugins/"))
        #expect(warning.contains(root.lastPathComponent))
        // The reason it matters, not just the instruction.
        #expect(warning.contains("Linux"))
    }
}
