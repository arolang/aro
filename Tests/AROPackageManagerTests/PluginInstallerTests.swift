// ============================================================
// PluginInstallerTests.swift
// AROPackageManager — install-directory naming + manifest fidelity
// ============================================================
//
// Two regressions guarded here, both found through `:plugin add`:
//
// 1. The install directory was named after the *repository*, while
//    every other layer (lock file, runtime loader, update/remove)
//    keys on the *manifest* name — a plugin in a differently-named
//    repo installed fine and then couldn't be loaded.
// 2. The installer's manifest rewrite went through a model without
//    a `handle` field, silently deleting the namespace handle — so
//    every installed plugin's qualifiers changed their spelling.

import Testing
import Foundation
@testable import AROPackageManager

@Suite("PluginInstaller", .serialized)
struct PluginInstallerTests {

    /// Create a local git repository at `repoDir` containing a
    /// minimal aro-files plugin with the given manifest name/handle.
    /// aro-files plugins have no build step, so the installer needs
    /// nothing but git.
    private func makePluginRepo(
        at repoDir: URL, name: String, handle: String?
    ) throws {
        try FileManager.default.createDirectory(
            at: repoDir.appendingPathComponent("features"),
            withIntermediateDirectories: true)
        var manifest = """
        name: \(name)
        version: 1.0.0
        """
        if let handle {
            manifest += "\nhandle: \(handle)"
        }
        manifest += """

        description: test plugin
        license: MIT
        provides:
          - type: aro-files
            path: features/
        """
        try manifest.write(
            to: repoDir.appendingPathComponent("plugin.yaml"),
            atomically: true, encoding: .utf8)
        try "(* placeholder *)\n".write(
            to: repoDir.appendingPathComponent("features/placeholder.aro"),
            atomically: true, encoding: .utf8)

        func git(_ args: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git", "-C", repoDir.path] + args
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
        }
        try git(["init", "-q"])
        try git(["-c", "user.email=t@t", "-c", "user.name=t", "add", "-A"])
        try git(["-c", "user.email=t@t", "-c", "user.name=t",
                 "commit", "-qm", "plugin"])
    }

    private func makeTempDir(_ label: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aro-installer-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Install directory is named after the manifest, not the repository")
    func manifestNamedDirectory() throws {
        let root = try makeTempDir("dirname")
        defer { try? FileManager.default.removeItem(at: root) }

        // Repository directory name ≠ manifest name.
        let repo = root.appendingPathComponent("stats-src")
        try makePluginRepo(at: repo, name: "plugin-collection", handle: "Stats")

        let pluginsDir = root.appendingPathComponent("Plugins")
        let installer = PluginInstaller(directory: pluginsDir)
        let result = try installer.install(from: "file://\(repo.path)")

        #expect(result.name == "plugin-collection")
        #expect(result.path.lastPathComponent == "plugin-collection")
        #expect(FileManager.default.fileExists(
            atPath: pluginsDir.appendingPathComponent("plugin-collection/plugin.yaml").path))
        // No stray repository-named directory.
        #expect(!FileManager.default.fileExists(
            atPath: pluginsDir.appendingPathComponent("stats-src").path))
    }

    @Test("The manifest rewrite preserves the namespace handle")
    func handleSurvivesRewrite() throws {
        let root = try makeTempDir("handle")
        defer { try? FileManager.default.removeItem(at: root) }

        let repo = root.appendingPathComponent("repo")
        try makePluginRepo(at: repo, name: "handled-plugin", handle: "Stats")

        let pluginsDir = root.appendingPathComponent("Plugins")
        let installer = PluginInstaller(directory: pluginsDir)
        let result = try installer.install(from: "file://\(repo.path)")

        let installedManifest = try PluginManifest.parse(
            from: result.path.appendingPathComponent("plugin.yaml"))
        #expect(installedManifest.handle == "Stats")
        // The rewrite's actual purpose still happens: source info added.
        #expect(installedManifest.source?.git?.contains(repo.lastPathComponent) == true)
    }

    @Test("A second install of the same plugin is refused by manifest name")
    func duplicateRefusedByManifestName() throws {
        let root = try makeTempDir("dup")
        defer { try? FileManager.default.removeItem(at: root) }

        // Two repos with different directory names but the same
        // manifest name — the second must be refused, not installed
        // alongside.
        let repoA = root.appendingPathComponent("repo-a")
        let repoB = root.appendingPathComponent("repo-b")
        try makePluginRepo(at: repoA, name: "same-name", handle: nil)
        try makePluginRepo(at: repoB, name: "same-name", handle: nil)

        let installer = PluginInstaller(directory: root.appendingPathComponent("Plugins"))
        _ = try installer.install(from: "file://\(repoA.path)")
        #expect(throws: (any Error).self) {
            _ = try installer.install(from: "file://\(repoB.path)")
        }
    }
}
