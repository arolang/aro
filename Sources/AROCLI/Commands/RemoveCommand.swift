// ============================================================
// RemoveCommand.swift
// ARO CLI - Remove Plugin Command
// ============================================================

import ArgumentParser
import Foundation
import AROPackageManager

/// Command to remove an installed plugin
struct RemoveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove an installed plugin",
        discussion: """
            Removes a plugin from your ARO application's Plugins/ directory.

            Example:
              aro remove plugin-csv
              aro remove my-custom-plugin
            """
    )

    // MARK: - Arguments

    @Argument(help: "Name of the plugin to remove")
    var name: String

    @Option(name: .shortAndLong, help: "Application directory (default: current directory)")
    var directory: String?

    @Flag(name: .shortAndLong, help: "Skip confirmation prompt")
    var force: Bool = false

    // MARK: - Run

    func run() throws {
        let appDir = directory.map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

        let pm = PackageManager(applicationDirectory: appDir)

        // Check if plugin exists
        guard let plugin = try pm.getPlugin(name: name) else {
            print("❌ Plugin '\(name)' is not installed")
            throw ExitCode.failure
        }

        // Show plugin info
        print("📦 Plugin: \(plugin.manifest.name) v\(plugin.manifest.version)")
        if let description = plugin.manifest.description {
            print("   \(description)")
        }

        // Confirm removal unless --force
        if !force {
            print("")
            print("Are you sure you want to remove this plugin? [y/N] ", terminator: "")
            guard let response = readLine()?.lowercased(), response == "y" || response == "yes" else {
                print("Cancelled.")
                return
            }
        }

        do {
            try pm.remove(name: name)
            print("")
            print("✅ Plugin '\(name)' removed successfully.")
        } catch {
            print("")
            print("❌ Failed to remove plugin: \(error)")
            throw ExitCode.failure
        }
    }
}
