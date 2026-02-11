// ============================================================
// PluginsCommand.swift
// ARO CLI - Plugins Management Command
// ============================================================

import ArgumentParser
import Foundation
import AROPackageManager

/// Command group for plugin management
struct PluginsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "plugins",
        abstract: "Manage installed plugins",
        discussion: """
            Commands for managing ARO plugins.

            Example:
              aro plugins list           # List installed plugins
              aro plugins update         # Update all plugins
              aro plugins update my-plugin  # Update specific plugin
              aro plugins export         # Export plugin sources
              aro plugins restore        # Restore from .aro-sources
            """,
        subcommands: [
            ListPlugins.self,
            UpdatePlugins.self,
            ExportPlugins.self,
            RestorePlugins.self,
            ValidatePlugins.self,
        ],
        defaultSubcommand: ListPlugins.self
    )
}

// MARK: - List Plugins

/// List all installed plugins
struct ListPlugins: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List installed plugins"
    )

    @Option(name: .shortAndLong, help: "Application directory (default: current directory)")
    var directory: String?

    @Flag(name: .long, help: "Show detailed information")
    var verbose: Bool = false

    func run() throws {
        let appDir = directory.map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

        let pm = PackageManager(applicationDirectory: appDir)
        let plugins = try pm.list()

        if plugins.isEmpty {
            print("No plugins installed.")
            print("")
            print("To add a plugin, use:")
            print("  aro add <git-url>")
            return
        }

        print("")
        print("Installed Plugins (from Plugins/):")
        print("───────────────────────────────────────────────────────────────────")

        // Calculate column widths
        let maxNameLen = max(30, plugins.map { $0.manifest.name.count }.max() ?? 30)

        // Header
        let nameHeader = "Name".padding(toLength: maxNameLen, withPad: " ", startingAt: 0)
        print(" \(nameHeader)  Version   Source                    Provides")

        for plugin in plugins {
            let name = plugin.manifest.name.padding(toLength: maxNameLen, withPad: " ", startingAt: 0)
            let version = plugin.manifest.version.padding(toLength: 8, withPad: " ", startingAt: 0)

            // Source info
            let source: String
            if let sourceInfo = plugin.manifest.source, let git = sourceInfo.git {
                let urlInfo = GitClient.shared.parseURL(git)
                source = urlInfo.host.prefix(24).padding(toLength: 24, withPad: " ", startingAt: 0)
            } else {
                source = "(local)".padding(toLength: 24, withPad: " ", startingAt: 0)
            }

            // Count provides
            var counts: [String] = []
            let aroCount = plugin.manifest.provides.filter { $0.type == .aroFiles }.count
            let swiftCount = plugin.manifest.provides.filter { $0.type == .swiftPlugin }.count
            let rustCount = plugin.manifest.provides.filter { $0.type == .rustPlugin }.count
            let cCount = plugin.manifest.provides.filter { $0.type == .cPlugin || $0.type == .cppPlugin }.count
            let pythonCount = plugin.manifest.provides.filter { $0.type == .pythonPlugin }.count

            if aroCount > 0 { counts.append("\(aroCount) .aro") }
            if swiftCount > 0 { counts.append("\(swiftCount) swift") }
            if rustCount > 0 { counts.append("\(rustCount) rust") }
            if cCount > 0 { counts.append("\(cCount) c") }
            if pythonCount > 0 { counts.append("\(pythonCount) py") }

            let provides = counts.joined(separator: ", ")

            print(" \(name)  \(version)  \(source)  \(provides)")

            if verbose {
                if let desc = plugin.manifest.description {
                    print("   Description: \(desc)")
                }
                if let author = plugin.manifest.author {
                    print("   Author: \(author)")
                }
                if let license = plugin.manifest.license {
                    print("   License: \(license)")
                }
                if let sourceInfo = plugin.manifest.source {
                    if let ref = sourceInfo.ref {
                        print("   Ref: \(ref)")
                    }
                    if let commit = sourceInfo.commit {
                        print("   Commit: \(commit.prefix(7))")
                    }
                }
                print("")
            }
        }

        print("───────────────────────────────────────────────────────────────────")
        print(" \(plugins.count) \(plugins.count == 1 ? "plugin" : "plugins") loaded")
    }
}

// MARK: - Update Plugins

/// Update installed plugins
struct UpdatePlugins: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Update installed plugins"
    )

    @Argument(help: "Plugin name to update (optional, updates all if not specified)")
    var name: String?

    @Option(name: .shortAndLong, help: "Application directory (default: current directory)")
    var directory: String?

    @Option(name: .long, help: "Update to specific reference")
    var ref: String?

    func run() throws {
        let appDir = directory.map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

        let pm = PackageManager(applicationDirectory: appDir)

        if let pluginName = name {
            // Update specific plugin
            print("🔄 Updating \(pluginName)...")

            do {
                let result = try pm.update(name: pluginName, ref: ref)

                if result.hasChanges {
                    print("   ✓ Updated \(result.name)")
                    print("     \(result.oldVersion) (\(result.oldCommit.prefix(7))) → \(result.newVersion) (\(result.newCommit.prefix(7)))")
                } else {
                    print("   ✓ \(result.name) is already up to date")
                }
            } catch {
                print("   ✗ Failed: \(error)")
                throw ExitCode.failure
            }
        } else {
            // Update all plugins
            print("🔄 Updating all plugins...")
            print("")

            let results = try pm.updateAll()

            var updated = 0
            var upToDate = 0

            for result in results {
                if result.hasChanges {
                    print("   ✓ Updated \(result.name): \(result.oldCommit.prefix(7)) → \(result.newCommit.prefix(7))")
                    updated += 1
                } else {
                    upToDate += 1
                }
            }

            print("")
            print("✅ \(updated) \(updated == 1 ? "plugin" : "plugins") updated, \(upToDate) already up to date")
        }
    }
}

// MARK: - Export Plugins

/// Export plugin sources to a file
struct ExportPlugins: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export plugin sources to .aro-sources file"
    )

    @Option(name: .shortAndLong, help: "Output file (default: .aro-sources)")
    var output: String = ".aro-sources"

    @Option(name: .shortAndLong, help: "Application directory (default: current directory)")
    var directory: String?

    func run() throws {
        let appDir = directory.map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

        let outputURL = appDir.appendingPathComponent(output)
        let pm = PackageManager(applicationDirectory: appDir)

        try pm.export(to: outputURL)

        print("✅ Plugin sources exported to \(output)")
    }
}

// MARK: - Restore Plugins

/// Restore plugins from a sources file
struct RestorePlugins: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restore",
        abstract: "Restore plugins from .aro-sources file"
    )

    @Option(name: .shortAndLong, help: "Input file (default: .aro-sources)")
    var input: String = ".aro-sources"

    @Option(name: .shortAndLong, help: "Application directory (default: current directory)")
    var directory: String?

    func run() throws {
        let appDir = directory.map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

        let inputURL = appDir.appendingPathComponent(input)
        let pm = PackageManager(applicationDirectory: appDir)

        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            print("❌ File not found: \(input)")
            throw ExitCode.failure
        }

        print("📦 Restoring plugins from \(input)...")
        print("")

        let results = try pm.restore(from: inputURL)

        for result in results {
            print("   ✓ Installed \(result.name) v\(result.version)")
        }

        print("")
        print("✅ \(results.count) \(results.count == 1 ? "plugin" : "plugins") restored")
    }
}

// MARK: - Validate Plugins

/// Validate installed plugins
struct ValidatePlugins: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "validate",
        abstract: "Validate installed plugins and dependencies"
    )

    @Option(name: .shortAndLong, help: "Application directory (default: current directory)")
    var directory: String?

    func run() throws {
        let appDir = directory.map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

        let pm = PackageManager(applicationDirectory: appDir)

        print("🔍 Validating plugins...")
        print("")

        let result = try pm.validate()

        if !result.errors.isEmpty {
            print("❌ Errors:")
            for error in result.errors {
                print("   • \(error)")
            }
            print("")
        }

        if !result.warnings.isEmpty {
            print("⚠️  Warnings:")
            for warning in result.warnings {
                print("   • \(warning)")
            }
            print("")
        }

        // Check dependencies
        let missing = try pm.checkDependencies()
        if !missing.isEmpty {
            print("📦 Missing dependencies:")
            for (plugin, deps) in missing {
                print("   • \(plugin) requires: \(deps.joined(separator: ", "))")
            }
            print("")
        }

        if result.isValid && missing.isEmpty {
            print("✅ All plugins are valid")
        } else {
            throw ExitCode.failure
        }
    }
}
