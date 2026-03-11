// ============================================================
// CheckCommand.swift
// ARO CLI - Check Command
// ============================================================

import ArgumentParser
import Foundation
import AROParser
import AROPackageManager
import AROVersion

struct CheckCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check",
        abstract: "Check ARO source files or plugins",
        subcommands: [SourceCheckSubcommand.self, PluginCheckSubcommand.self],
        defaultSubcommand: SourceCheckSubcommand.self
    )
}

// MARK: - Source Check

struct SourceCheckSubcommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "source",
        abstract: "Check ARO source files for errors"
    )

    @Argument(help: "Path to source file or directory")
    var path: String

    @Flag(name: .long, inversion: .prefixedNo, help: "Show warnings")
    var warnings: Bool = true

    @Flag(name: .long, help: "Show verbose diagnostic information")
    var verbose: Bool = false

    func run() throws {
        let resolvedPath = URL(fileURLWithPath: path)

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedPath.path, isDirectory: &isDirectory) else {
            print("Error: Path not found: \(path)")
            throw ExitCode.failure
        }

        let sourceFiles: [URL]

        if isDirectory.boolValue {
            sourceFiles = try findSourceFiles(in: resolvedPath)
        } else {
            sourceFiles = [resolvedPath]
        }

        if sourceFiles.isEmpty {
            print("Error: No .aro files found")
            throw ExitCode.failure
        }

        var totalErrors = 0
        var totalWarnings = 0

        for sourceFile in sourceFiles {
            let (errors, warnings) = try checkFile(sourceFile)
            totalErrors += errors
            totalWarnings += warnings
        }

        // Summary
        print()
        if totalErrors == 0 && totalWarnings == 0 {
            print("✅ No issues found in \(sourceFiles.count) file(s)")
        } else {
            if totalErrors > 0 {
                print("❌ \(totalErrors) error(s) found")
            }
            if totalWarnings > 0 && warnings {
                print("⚠️  \(totalWarnings) warning(s) found")
            }
        }

        if totalErrors > 0 {
            Foundation.exit(1)
        }
    }

    private func findSourceFiles(in directory: URL) throws -> [URL] {
        let fileManager = FileManager.default

        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var sourceFiles: [URL] = []

        for case let fileURL as URL in enumerator {
            if fileURL.pathExtension == "aro" {
                sourceFiles.append(fileURL)
            }
        }

        return sourceFiles.sorted { $0.path < $1.path }
    }

    private func checkFile(_ file: URL) throws -> (errors: Int, warnings: Int) {
        let source = try String(contentsOf: file, encoding: .utf8)
        let compiler = Compiler()
        let result = compiler.compile(source)

        let errors = result.diagnostics.filter { $0.severity == .error }
        let warningDiags = result.diagnostics.filter { $0.severity == .warning }

        if !errors.isEmpty || (!warningDiags.isEmpty && warnings) {
            print("\(file.lastPathComponent):")

            for error in errors {
                let location = formatLocation(error.location)
                print("  \(location) error: \(error.message)")

                for hint in error.hints {
                    print("    hint: \(hint)")
                }
            }

            if warnings {
                for warning in warningDiags {
                    let location = formatLocation(warning.location)
                    print("  \(location) warning: \(warning.message)")

                    for hint in warning.hints {
                        print("    hint: \(hint)")
                    }
                }
            }

            // Per-file summary
            var parts: [String] = []
            if !errors.isEmpty { parts.append("\(errors.count) error(s)") }
            if !warningDiags.isEmpty && warnings { parts.append("\(warningDiags.count) warning(s)") }
            print("  Found \(parts.joined(separator: ", ")) in \(file.lastPathComponent)")
        } else if verbose {
            print("\(file.lastPathComponent): OK")
        }

        return (errors.count, warningDiags.count)
    }

    private func formatLocation(_ location: SourceLocation?) -> String {
        guard let loc = location else { return "" }
        return "\(loc.line):\(loc.column):"
    }
}

// MARK: - Plugin Check

/// Check plugin compatibility with the current ARO version
///
/// Usage: aro check plugins [--directory <path>] [--verbose]
struct PluginCheckSubcommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "plugins",
        abstract: "Check plugin compatibility with the current ARO version"
    )

    @Option(name: .shortAndLong, help: "Application directory (default: current directory)")
    var directory: String?

    @Flag(name: .long, help: "Show details for each plugin")
    var verbose: Bool = false

    func run() throws {
        let appDir = directory.map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

        let pm = PackageManager(applicationDirectory: appDir)
        let currentVersion = AROVersion.version

        print("🔍 Checking plugins against ARO \(currentVersion)...")
        print("")

        var hasIssues = false

        // 1. ARO version compatibility (top-level + per-action since)
        let results = try pm.checkAROVersionCompatibility(currentAROVersion: currentVersion)
        let incompatible = results.filter { !$0.isCompatible }

        if incompatible.isEmpty {
            print("✅ All plugins are compatible with ARO \(currentVersion)")
        } else {
            hasIssues = true
            print("❌ Incompatible plugins:")
            for result in incompatible.sorted(by: { $0.pluginName < $1.pluginName }) {
                if let constraint = result.pluginConstraint {
                    print("   • \(result.pluginName) requires ARO \(constraint)")
                }
                for (actionName, since) in result.incompatibleActions {
                    print("   • \(result.pluginName)/\(actionName) requires ARO >=\(since)")
                }
            }
        }

        // 2. Missing plugin dependencies
        let missingDeps = try pm.checkDependencies()
        if !missingDeps.isEmpty {
            hasIssues = true
            print("")
            print("📦 Missing dependencies:")
            for (plugin, deps) in missingDeps.sorted(by: { $0.key < $1.key }) {
                print("   • \(plugin) requires: \(deps.joined(separator: ", "))")
            }
        }

        // 3. Lock file verification
        let mismatches = try pm.verifyLockFile()
        if !mismatches.isEmpty {
            hasIssues = true
            print("")
            print("🔒 Lock file mismatches (run 'aro plugins update' to fix):")
            for name in mismatches {
                print("   • \(name)")
            }
        } else if pm.lockFile.exists {
            print("🔒 Lock file verified — all commits match")
        }

        // 4. Verbose: per-plugin details
        if verbose {
            let plugins = try pm.list()
            if !plugins.isEmpty {
                print("")
                print("Plugin details:")
                for plugin in plugins {
                    let constraint = plugin.manifest.aroVersion ?? "(any)"
                    let lock = pm.lockFile.load().entry(for: plugin.manifest.name)
                    let commit = lock?.commit.map { String($0.prefix(7)) } ?? "not locked"
                    print("   \(plugin.manifest.name) v\(plugin.manifest.version)")
                    print("     aro-version: \(constraint)")
                    print("     commit:      \(commit)")
                    if let system = plugin.manifest.system, !system.isEmpty {
                        print("     system:      \(system.joined(separator: ", "))")
                    }
                    // Show per-action since values
                    let actions = plugin.manifest.provides.flatMap { $0.actions ?? [] }.filter { $0.since != nil }
                    if !actions.isEmpty {
                        print("     actions:")
                        for action in actions {
                            print("       \(action.name) (since \(action.since!))")
                        }
                    }
                }
            }
        }

        print("")
        if hasIssues {
            throw ExitCode.failure
        } else {
            print("✅ All checks passed")
        }
    }
}
