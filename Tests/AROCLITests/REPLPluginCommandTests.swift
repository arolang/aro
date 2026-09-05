// ============================================================
// REPLPluginCommandTests.swift
// AROCLI — :plugin meta-command plumbing
// ============================================================
//
// The full install path (git clone + build + load) is exercised by
// the package-manager tests and the manual REPL flow; what belongs
// here is the name→directory resolution the update/remove
// subcommands depend on, and the directory override that keeps
// tests and sandboxed CI out of the real home directory.

import Testing
import Foundation
@testable import AROCLI

@Suite("REPL :plugin command", .serialized)
struct REPLPluginCommandTests {

    /// Point ARO_REPL_PLUGINS_DIR at a scratch dir for the duration
    /// of one test body.
    private func withPluginsDir<T>(
        _ body: (URL) throws -> T
    ) throws -> T {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aro-repl-plugins-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Plugins"),
            withIntermediateDirectories: true)
        setenv("ARO_REPL_PLUGINS_DIR", dir.path, 1)
        defer {
            unsetenv("ARO_REPL_PLUGINS_DIR")
            try? FileManager.default.removeItem(at: dir)
        }
        return try body(dir)
    }

    private func writePlugin(
        in pluginsDir: URL, directory: String, manifestName: String
    ) throws {
        let dir = pluginsDir.appendingPathComponent(directory)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        try """
        name: \(manifestName)
        version: 1.0.0
        provides:
          - type: aro-files
            path: features/
        """.write(to: dir.appendingPathComponent("plugin.yaml"),
                  atomically: true, encoding: .utf8)
    }

    @Test("ARO_REPL_PLUGINS_DIR overrides the home-directory default")
    func directoryOverride() throws {
        try withPluginsDir { dir in
            #expect(PluginCommand.replPluginsDirectory.path == dir.path)
        }
        // Cleared again afterwards: back to the home default.
        #expect(PluginCommand.replPluginsDirectory.path.contains(".aro/repl-plugins"))
    }

    @Test("Directory resolution finds a plugin by its directory name")
    func resolvesByDirectoryName() throws {
        try withPluginsDir { dir in
            let pluginsDir = dir.appendingPathComponent("Plugins")
            try writePlugin(in: pluginsDir, directory: "simple", manifestName: "simple")
            let found = PluginCommand.installedPluginDirectory(named: "simple")
            #expect(found?.lastPathComponent == "simple")
        }
    }

    @Test("Directory resolution falls back to a manifest scan for legacy installs")
    func resolvesByManifestScan() throws {
        try withPluginsDir { dir in
            let pluginsDir = dir.appendingPathComponent("Plugins")
            // Pre-fix install: directory named after the repository.
            try writePlugin(in: pluginsDir,
                            directory: "stats-src",
                            manifestName: "plugin-collection")
            let found = PluginCommand.installedPluginDirectory(named: "plugin-collection")
            #expect(found?.lastPathComponent == "stats-src")
            // And an unknown name stays unknown.
            #expect(PluginCommand.installedPluginDirectory(named: "nope") == nil)
        }
    }
}
