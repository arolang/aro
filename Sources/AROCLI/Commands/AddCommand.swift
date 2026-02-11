// ============================================================
// AddCommand.swift
// ARO CLI - Add Plugin Command
// ============================================================

import ArgumentParser
import Foundation
import AROPackageManager

/// Command to add a plugin from a Git repository
struct AddCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Add a plugin from a Git repository",
        discussion: """
            Adds a plugin to your ARO application by cloning it from a Git repository.

            The plugin must have a plugin.yaml manifest file in its root directory.

            Example:
              aro add git@github.com:arolang/plugin-csv.git
              aro add https://github.com/arolang/plugin-csv.git
              aro add git@github.com:arolang/plugin-csv.git --ref v1.0.0
              aro add git@github.com:arolang/plugin-csv.git --branch develop
            """
    )

    // MARK: - Arguments

    @Argument(help: "Git repository URL (SSH or HTTPS)")
    var url: String

    @Option(name: .long, help: "Git reference (tag or commit) to checkout")
    var ref: String?

    @Option(name: .long, help: "Git branch to checkout")
    var branch: String?

    @Option(name: .shortAndLong, help: "Application directory (default: current directory)")
    var directory: String?

    // MARK: - Run

    func run() throws {
        let appDir = directory.map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

        // Use branch as ref if specified
        let gitRef = ref ?? branch

        let pm = PackageManager(applicationDirectory: appDir)

        print("📦 Resolving package: \(GitClient.shared.extractRepoName(from: url))")
        print("   Cloning from \(url)...")

        do {
            let result = try pm.add(url: url, ref: gitRef)

            print("   ✓ Cloned (ref: \(result.ref ?? "HEAD"), commit: \(String(result.commit?.prefix(7) ?? "unknown")))")
            print("")
            print("📂 Reading plugin.yaml:")
            print("   Name:    \(result.name)")
            print("   Version: \(result.version)")

            // Count provides by type
            var aroCount = 0
            var swiftCount = 0
            var otherCount = 0

            for provide in result.provides {
                switch provide.type {
                case .aroFiles:
                    aroCount += 1
                case .swiftPlugin:
                    swiftCount += 1
                default:
                    otherCount += 1
                }
            }

            if aroCount > 0 {
                print("   Found \(aroCount) .aro file \(aroCount == 1 ? "set" : "sets")")
            }
            if swiftCount > 0 {
                print("   Found \(swiftCount) Swift plugin \(swiftCount == 1 ? "source" : "sources")")
            }
            if otherCount > 0 {
                print("   Found \(otherCount) other \(otherCount == 1 ? "component" : "components")")
            }

            print("")
            print("🔗 Installing to Plugins/\(result.name)/")

            for buildResult in result.buildResults {
                let icon = buildResult.success ? "✓" : "✗"
                print("   \(icon) \(buildResult.message)")
            }

            print("")
            print("✅ Package \"\(result.name)\" v\(result.version) installed successfully.")

        } catch {
            print("")
            print("❌ Failed to install package: \(error)")
            throw ExitCode.failure
        }
    }
}
