// ============================================================
// PluginsCommand.swift
// ARO CLI - Plugins Management Command
// ============================================================

import ArgumentParser
import Foundation
import AROPackageManager
import ARORuntime
import AROVersion

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
            CheckPlugins.self,
            UpdatePlugins.self,
            ExportPlugins.self,
            RestorePlugins.self,
            ValidatePlugins.self,
            RebuildPlugins.self,
            DocsPlugins.self,
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

        // List managed plugins from Plugins/ directory
        let pm = PackageManager(applicationDirectory: appDir)
        let managedPlugins = try pm.list()

        // List local plugins from plugins/ directory
        let localPlugins = try PluginLoader.shared.listLocalPlugins(from: appDir)

        if managedPlugins.isEmpty && localPlugins.isEmpty {
            print("No plugins found.")
            print("")
            print("To add a managed plugin, use:")
            print("  aro add <git-url>")
            print("")
            print("To add a local plugin, create:")
            print("  plugins/MyPlugin.swift")
            return
        }

        // Show managed plugins if any
        if !managedPlugins.isEmpty {
            print("")
            print("Managed Plugins (from Plugins/):")
            print("───────────────────────────────────────────────────────────────────")

            // Calculate column widths
            let maxNameLen = max(30, managedPlugins.map { $0.manifest.name.count }.max() ?? 30)

            // Header
            let nameHeader = "Name".padding(toLength: maxNameLen, withPad: " ", startingAt: 0)
            print(" \(nameHeader)  Version   Source                    Provides")

            for plugin in managedPlugins {
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
            print(" \(managedPlugins.count) managed \(managedPlugins.count == 1 ? "plugin" : "plugins")")
        }

        // Show local plugins if any
        if !localPlugins.isEmpty {
            print("")
            print("Local Plugins (from plugins/):")
            print("───────────────────────────────────────────────────────────────────")

            // Calculate column widths
            let maxSourceLen = max(30, localPlugins.map { $0.source.count }.max() ?? 30)

            // Header
            let sourceHeader = "Source".padding(toLength: maxSourceLen, withPad: " ", startingAt: 0)
            print(" \(sourceHeader)  Service           Methods")

            for plugin in localPlugins {
                let source = plugin.source.padding(toLength: maxSourceLen, withPad: " ", startingAt: 0)

                if let error = plugin.error {
                    print(" \(source)  (error: \(error.prefix(40)))")
                } else if plugin.services.isEmpty {
                    print(" \(source)  (no services exported)")
                } else {
                    for (index, service) in plugin.services.enumerated() {
                        // Service name already includes convention, no need to add suffix
                        let serviceName = service.name.padding(toLength: 18, withPad: " ", startingAt: 0)
                        let methods = service.methods.isEmpty ? "(any)" : service.methods.joined(separator: ", ")

                        if index == 0 {
                            print(" \(source)  \(serviceName)  \(methods)")
                        } else {
                            let padding = String(repeating: " ", count: maxSourceLen + 1)
                            print(" \(padding)  \(serviceName)  \(methods)")
                        }
                    }
                }

                if verbose {
                    let typeStr = plugin.type == .swiftFile ? "Single-file Swift" : "Swift Package"
                    print("   Type: \(typeStr)")
                    print("")
                }
            }

            print("───────────────────────────────────────────────────────────────────")
            print(" \(localPlugins.count) local \(localPlugins.count == 1 ? "plugin" : "plugins")")
        }
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

// MARK: - Check Plugins

/// Check plugin compatibility with the current ARO version and verify the lock file
struct CheckPlugins: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check",
        abstract: "Check plugin compatibility and lock file integrity"
    )

    @Option(name: .shortAndLong, help: "Application directory (default: current directory)")
    var directory: String?

    @Flag(name: .long, help: "Show detailed information for each plugin")
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
        let versionResults = try pm.checkAROVersionCompatibility(currentAROVersion: currentVersion)
        let incompatible = versionResults.filter { !$0.isCompatible }
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

        // 4. Verbose: show each plugin's declared constraint
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

// MARK: - Rebuild Plugins

/// Recompile all native plugins from source
struct RebuildPlugins: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rebuild",
        abstract: "Recompile native plugins from source"
    )

    @Option(name: .shortAndLong, help: "Application directory (default: current directory)")
    var directory: String?

    @Argument(help: "Plugin name to rebuild (optional, rebuilds all if not specified)")
    var name: String?

    func run() throws {
        let appDir = directory.map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

        let pluginsDir = appDir.appendingPathComponent("Plugins")

        guard FileManager.default.fileExists(atPath: pluginsDir.path) else {
            print("No Plugins/ directory found in \(appDir.path)")
            throw ExitCode.failure
        }

        let contents = try FileManager.default.contentsOfDirectory(
            at: pluginsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        let pluginDirs = try contents.filter { item in
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: item.path, isDirectory: &isDir)
            return isDir.boolValue &&
                   FileManager.default.fileExists(atPath: item.appendingPathComponent("plugin.yaml").path)
        }

        if pluginDirs.isEmpty {
            print("No plugins with plugin.yaml found in Plugins/")
            return
        }

        var rebuilt = 0
        var skipped = 0
        var failed  = 0

        print("Rebuilding plugins...")
        print("")

        for pluginDir in pluginDirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let pluginName = pluginDir.lastPathComponent

            // If a specific plugin was requested, skip others
            if let targetName = name, pluginName != targetName {
                continue
            }

            let manifestURL = pluginDir.appendingPathComponent("plugin.yaml")
            guard let manifestData = try? String(contentsOf: manifestURL, encoding: .utf8) else {
                print("  ✗ \(pluginName): cannot read plugin.yaml")
                failed += 1
                continue
            }

            // Detect plugin type from manifest
            let pluginType = detectNativePluginType(manifest: manifestData)

            switch pluginType {
            case .rust:
                print("  Rebuilding \(pluginName) (Rust)...")
                do {
                    try rebuildRust(pluginDir: pluginDir, pluginName: pluginName)
                    print("  ✓ \(pluginName) rebuilt successfully")
                    rebuilt += 1
                } catch {
                    print("  ✗ \(pluginName): \(error)")
                    failed += 1
                }

            case .c, .cpp:
                let lang = pluginType == .cpp ? "C++" : "C"
                print("  Rebuilding \(pluginName) (\(lang))...")
                do {
                    try rebuildC(pluginDir: pluginDir, pluginName: pluginName, cpp: pluginType == .cpp)
                    print("  ✓ \(pluginName) rebuilt successfully")
                    rebuilt += 1
                } catch {
                    print("  ✗ \(pluginName): \(error)")
                    failed += 1
                }

            case .swift:
                print("  Rebuilding \(pluginName) (Swift)...")
                do {
                    try rebuildSwift(pluginDir: pluginDir, pluginName: pluginName)
                    print("  ✓ \(pluginName) rebuilt successfully")
                    rebuilt += 1
                } catch {
                    print("  ✗ \(pluginName): \(error)")
                    failed += 1
                }

            case .none:
                print("  - \(pluginName): not a native plugin, skipped")
                skipped += 1
            }
        }

        print("")
        print("Rebuilt: \(rebuilt)  Skipped: \(skipped)  Failed: \(failed)")

        if failed > 0 {
            throw ExitCode.failure
        }
    }

    // MARK: - Plugin Type Detection

    private enum NativePluginType: Equatable {
        case rust, c, cpp, swift
        case none
    }

    private func detectNativePluginType(manifest: String) -> NativePluginType {
        if manifest.contains("rust-plugin") {
            return .rust
        } else if manifest.contains("cpp-plugin") {
            return .cpp
        } else if manifest.contains("c-plugin") {
            return .c
        } else if manifest.contains("swift-plugin") {
            return .swift
        }
        return .none
    }

    // MARK: - Compilation Helpers

    private func rebuildRust(pluginDir: URL, pluginName: String) throws {
        // Look for Cargo.toml in the plugin directory or its src/ subdirectory
        let cargoTomlCandidates = [
            pluginDir.appendingPathComponent("Cargo.toml"),
            pluginDir.appendingPathComponent("src/Cargo.toml"),
        ]
        guard let cargoToml = cargoTomlCandidates.first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) else {
            throw RebuildError.sourceNotFound(pluginName, "Cargo.toml not found")
        }

        let projectDir = cargoToml.deletingLastPathComponent()

        let cargoPaths = [
            "\(FileManager.default.homeDirectoryForCurrentUser.path)/.cargo/bin/cargo",
            "/root/.cargo/bin/cargo",
            "/opt/homebrew/bin/cargo",
            "/usr/local/bin/cargo",
            "/usr/bin/cargo",
        ]
        guard let cargo = cargoPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw RebuildError.toolNotFound("cargo")
        }

        try runProcess(executable: cargo, arguments: ["build", "--release"],
                       workingDirectory: projectDir, pluginName: pluginName)
    }

    private func rebuildC(pluginDir: URL, pluginName: String, cpp: Bool) throws {
        // Find sources in pluginDir/src/ or pluginDir/ directly
        let ext = cpp ? "cpp" : "c"
        let srcDir = FileManager.default.fileExists(atPath: pluginDir.appendingPathComponent("src").path)
            ? pluginDir.appendingPathComponent("src")
            : pluginDir

        let sources = (try? FileManager.default.contentsOfDirectory(at: srcDir, includingPropertiesForKeys: nil))
            .map { $0.filter { $0.pathExtension == ext } } ?? []

        if sources.isEmpty {
            throw RebuildError.sourceNotFound(pluginName, "No .\(ext) files found")
        }

        let compiler: String
        if cpp {
            let clangpp = ["/usr/bin/clang++", "/usr/bin/g++", "/usr/local/bin/clang++"]
            guard let found = clangpp.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                throw RebuildError.toolNotFound("clang++")
            }
            compiler = found
        } else {
            let clang = ["/usr/bin/clang", "/usr/bin/gcc", "/usr/local/bin/clang"]
            guard let found = clang.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                throw RebuildError.toolNotFound("clang")
            }
            compiler = found
        }

        #if os(Linux)
        let libExt = "so"
        #elseif os(Windows)
        let libExt = "dll"
        #else
        let libExt = "dylib"
        #endif

        let outputPath = pluginDir.appendingPathComponent("\(pluginName).\(libExt)")
        var args = sources.map { $0.path }
        args += ["-shared", "-fPIC", "-o", outputPath.path]

        try runProcess(executable: compiler, arguments: args,
                       workingDirectory: pluginDir, pluginName: pluginName)
    }

    private func rebuildSwift(pluginDir: URL, pluginName: String) throws {
        let srcDir = FileManager.default.fileExists(atPath: pluginDir.appendingPathComponent("Sources").path)
            ? pluginDir.appendingPathComponent("Sources")
            : pluginDir.appendingPathComponent("src").pathComponents.isEmpty
                ? pluginDir
                : (FileManager.default.fileExists(atPath: pluginDir.appendingPathComponent("src").path)
                    ? pluginDir.appendingPathComponent("src")
                    : pluginDir)

        let swiftFiles = (try? FileManager.default.contentsOfDirectory(at: srcDir, includingPropertiesForKeys: nil,
                                                                        options: [.skipsHiddenFiles]))
            .map { $0.filter { $0.pathExtension == "swift" } } ?? []

        if swiftFiles.isEmpty {
            throw RebuildError.sourceNotFound(pluginName, "No .swift files found")
        }

        // Find swiftc
        let swiftcPaths = ["/usr/bin/swiftc", "/usr/share/swift/usr/bin/swiftc",
                           "/opt/swift/usr/bin/swiftc", "/opt/homebrew/bin/swiftc", "/usr/local/bin/swiftc"]
        let swiftcEnv = ProcessInfo.processInfo.environment["SWIFTC"]
        let swiftcPath: String?
        if let env = swiftcEnv, !env.isEmpty, FileManager.default.isExecutableFile(atPath: env) {
            swiftcPath = env
        } else {
            swiftcPath = swiftcPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        }
        guard let swiftc = swiftcPath else {
            throw RebuildError.toolNotFound("swiftc")
        }

        #if os(Linux)
        let libExt = "so"
        #elseif os(Windows)
        let libExt = "dll"
        #else
        let libExt = "dylib"
        #endif

        let outputPath = pluginDir.appendingPathComponent("lib\(pluginName).\(libExt)")
        var args = swiftFiles.map { $0.path }
        args += ["-emit-library", "-O", "-o", outputPath.path]

        try runProcess(executable: swiftc, arguments: args,
                       workingDirectory: pluginDir, pluginName: pluginName)
    }

    private func runProcess(executable: String, arguments: [String],
                            workingDirectory: URL, pluginName: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory

        let errorPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "exit code \(process.terminationStatus)"
            throw RebuildError.compilationFailed(pluginName, message)
        }
    }
}

private enum RebuildError: Error, CustomStringConvertible {
    case sourceNotFound(String, String)
    case toolNotFound(String)
    case compilationFailed(String, String)

    var description: String {
        switch self {
        case .sourceNotFound(let plugin, let detail):
            return "[\(plugin)] \(detail)"
        case .toolNotFound(let tool):
            return "Build tool not found: \(tool)"
        case .compilationFailed(let plugin, let message):
            return "[\(plugin)] Compilation failed: \(message)"
        }
    }
}

// MARK: - Docs Plugins

/// Generate documentation for a plugin from its metadata
struct DocsPlugins: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "docs",
        abstract: "Generate documentation for a plugin"
    )

    @Argument(help: "Plugin name (directory name under Plugins/)")
    var pluginName: String

    @Option(name: .shortAndLong, help: "Application directory (default: current directory)")
    var directory: String?

    @Flag(name: .long, help: "Output HTML instead of Markdown")
    var html: Bool = false

    @Option(name: .shortAndLong, help: "Output file (default: stdout)")
    var output: String?

    func run() throws {
        let appDir = directory.map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

        let pluginDir = appDir.appendingPathComponent("Plugins").appendingPathComponent(pluginName)
        let manifestURL = pluginDir.appendingPathComponent("plugin.yaml")

        guard FileManager.default.fileExists(atPath: pluginDir.path) else {
            print("Plugin not found: \(pluginDir.path)")
            throw ExitCode.failure
        }

        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            print("plugin.yaml not found in \(pluginDir.path)")
            throw ExitCode.failure
        }

        // Parse plugin.yaml manually (avoid importing Yams in CLI)
        let manifestYAML = try String(contentsOf: manifestURL, encoding: .utf8)
        let metadata = parseBasicManifest(yaml: manifestYAML)

        // Try to get richer info by loading the compiled library
        let pluginInfo = loadPluginInfo(pluginDir: pluginDir, metadata: metadata)

        // Generate documentation
        let doc = html
            ? generateHTML(metadata: metadata, info: pluginInfo)
            : generateMarkdown(metadata: metadata, info: pluginInfo)

        if let outputPath = output {
            let outputURL = URL(fileURLWithPath: outputPath)
            try doc.write(to: outputURL, atomically: true, encoding: .utf8)
            print("Documentation written to \(outputPath)")
        } else {
            print(doc)
        }
    }

    // MARK: - Manifest Parsing (lightweight, no Yams dependency in CLI layer)

    private struct BasicManifest {
        var name: String
        var version: String
        var description: String?
        var author: String?
        var license: String?
        var handle: String?
        var provides: [BasicProvide] = []
    }

    private struct BasicProvide {
        var type: String
        var path: String
        var handler: String?
    }

    private struct PluginDocInfo {
        var actions: [ActionDoc] = []
        var qualifiers: [QualifierDoc] = []
        var services: [ServiceDoc] = []
        var systemObjects: [SystemObjectDoc] = []
        var events: [String] = []
    }

    private struct ActionDoc {
        var name: String
        var verbs: [String]
        var role: String?
        var prepositions: [String]
        var description: String?
        var since: String?
    }

    private struct QualifierDoc {
        var name: String
        var inputTypes: [String]
        var description: String?
        var acceptsParameters: Bool
    }

    private struct ServiceDoc {
        var name: String
        var methods: [String]
    }

    private struct SystemObjectDoc {
        var identifier: String
        var capabilities: [String]
        var description: String?
    }

    private func parseBasicManifest(yaml: String) -> BasicManifest {
        var m = BasicManifest(name: pluginName, version: "1.0.0")

        for line in yaml.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("name:") {
                m.name = trimmed.dropPrefix("name:").trimmingCharacters(in: .whitespaces).unquoted
            } else if trimmed.hasPrefix("version:") {
                m.version = trimmed.dropPrefix("version:").trimmingCharacters(in: .whitespaces).unquoted
            } else if trimmed.hasPrefix("description:") {
                m.description = trimmed.dropPrefix("description:").trimmingCharacters(in: .whitespaces).unquoted
            } else if trimmed.hasPrefix("author:") {
                m.author = trimmed.dropPrefix("author:").trimmingCharacters(in: .whitespaces).unquoted
            } else if trimmed.hasPrefix("license:") {
                m.license = trimmed.dropPrefix("license:").trimmingCharacters(in: .whitespaces).unquoted
            } else if trimmed.hasPrefix("handle:") {
                m.handle = trimmed.dropPrefix("handle:").trimmingCharacters(in: .whitespaces).unquoted
            }
        }

        return m
    }

    private func loadPluginInfo(pluginDir: URL, metadata: BasicManifest) -> PluginDocInfo {
        var info = PluginDocInfo()

        // Try to find and call aro_plugin_info from the compiled library
        #if os(Windows)
        let ext = "dll"
        #elseif os(Linux)
        let ext = "so"
        #else
        let ext = "dylib"
        #endif

        // Common library name patterns
        let name = metadata.name
        let candidates = [
            pluginDir.appendingPathComponent("lib\(name).\(ext)"),
            pluginDir.appendingPathComponent("\(name).\(ext)"),
            pluginDir.appendingPathComponent("target/release/lib\(name).\(ext)"),
        ]

        guard let libURL = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let handle = dlopen(libURL.path, RTLD_NOW | RTLD_LOCAL) else {
            return info
        }
        defer { dlclose(handle) }

        typealias InfoFunc = @convention(c) () -> UnsafeMutablePointer<CChar>?
        typealias FreeFunc = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void

        guard let infoSym = dlsym(handle, "aro_plugin_info") else { return info }
        let infoFunc = unsafeBitCast(infoSym, to: InfoFunc.self)

        var freeFunc: FreeFunc? = nil
        if let freeSym = dlsym(handle, "aro_plugin_free") {
            freeFunc = unsafeBitCast(freeSym, to: FreeFunc.self)
        }

        guard let ptr = infoFunc() else { return info }
        defer { freeFunc?(ptr) }

        let jsonString = String(cString: ptr)
        guard let data = jsonString.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return info
        }

        // Parse actions
        if let actionObjects = dict["actions"] as? [[String: Any]] {
            for actionObj in actionObjects {
                guard let actionName = actionObj["name"] as? String else { continue }
                let verbs = actionObj["verbs"] as? [String] ?? [actionName.lowercased()]
                let role = actionObj["role"] as? String
                let preps = actionObj["prepositions"] as? [String] ?? []
                let desc = actionObj["description"] as? String
                let since = actionObj["since"] as? String
                info.actions.append(ActionDoc(name: actionName, verbs: verbs, role: role,
                                               prepositions: preps, description: desc, since: since))
            }
        } else if let actionStrings = dict["actions"] as? [String] {
            for actionName in actionStrings {
                info.actions.append(ActionDoc(name: actionName, verbs: [actionName.lowercased()],
                                               role: nil, prepositions: [], description: nil, since: nil))
            }
        }

        // Parse qualifiers
        if let qualifierObjects = dict["qualifiers"] as? [[String: Any]] {
            for q in qualifierObjects {
                guard let qName = q["name"] as? String else { continue }
                let types = q["inputTypes"] as? [String] ?? []
                let desc = q["description"] as? String
                let acceptsParams = q["accepts_parameters"] as? Bool ?? false
                info.qualifiers.append(QualifierDoc(name: qName, inputTypes: types,
                                                     description: desc, acceptsParameters: acceptsParams))
            }
        }

        // Parse services
        if let serviceObjects = dict["services"] as? [[String: Any]] {
            for s in serviceObjects {
                guard let sName = s["name"] as? String else { continue }
                let methods = s["methods"] as? [String] ?? []
                info.services.append(ServiceDoc(name: sName, methods: methods))
            }
        }

        // Parse system objects
        if let sysObjects = dict["system_objects"] as? [[String: Any]] {
            for o in sysObjects {
                guard let id = o["identifier"] as? String else { continue }
                let caps = o["capabilities"] as? [String] ?? []
                let desc = o["description"] as? String
                info.systemObjects.append(SystemObjectDoc(identifier: id, capabilities: caps, description: desc))
            }
        }

        // Parse event subscriptions
        if let events = dict["events"] as? [String: Any],
           let subscribes = events["subscribes"] as? [String] {
            info.events = subscribes
        }

        return info
    }

    // MARK: - Markdown Generation

    private func generateMarkdown(metadata: BasicManifest, info: PluginDocInfo) -> String {
        var lines: [String] = []

        let handle = metadata.handle.map { " (`\($0)`)" } ?? ""
        lines.append("# \(metadata.name)\(handle)")
        lines.append("")
        lines.append("**Version:** \(metadata.version)")
        if let author = metadata.author { lines.append("**Author:** \(author)") }
        if let license = metadata.license { lines.append("**License:** \(license)") }
        lines.append("")

        if let desc = metadata.description {
            lines.append(desc)
            lines.append("")
        }

        // Actions
        if !info.actions.isEmpty {
            lines.append("## Actions")
            lines.append("")
            for action in info.actions {
                lines.append("### \(action.name)")
                if let desc = action.description { lines.append("") ; lines.append(desc) }
                lines.append("")
                if let role = action.role { lines.append("- **Role:** \(role)") }
                if !action.verbs.isEmpty { lines.append("- **Verbs:** `\(action.verbs.joined(separator: "`, `"))`") }
                if !action.prepositions.isEmpty { lines.append("- **Prepositions:** \(action.prepositions.joined(separator: ", "))") }
                if let since = action.since { lines.append("- **Since:** \(since)") }
                lines.append("")
            }
        }

        // Qualifiers
        if !info.qualifiers.isEmpty {
            let ns = (metadata.handle ?? metadata.name).lowercased()
            lines.append("## Qualifiers")
            lines.append("")
            lines.append("Access qualifiers as `<value: \(ns).qualifier-name>`.")
            lines.append("")
            lines.append("| Qualifier | Input Types | Description |")
            lines.append("|-----------|-------------|-------------|")
            for q in info.qualifiers {
                let types = q.inputTypes.isEmpty ? "Any" : q.inputTypes.joined(separator: ", ")
                let desc = q.description ?? ""
                let params = q.acceptsParameters ? " *(accepts parameters)*" : ""
                lines.append("| `\(ns).\(q.name)` | \(types) | \(desc)\(params) |")
            }
            lines.append("")
        }

        // Services
        if !info.services.isEmpty {
            lines.append("## Services")
            lines.append("")
            for service in info.services {
                lines.append("### \(service.name)")
                if !service.methods.isEmpty {
                    lines.append("")
                    lines.append("Methods: `\(service.methods.joined(separator: "`, `"))`")
                }
                lines.append("")
            }
        }

        // System Objects
        if !info.systemObjects.isEmpty {
            lines.append("## System Objects")
            lines.append("")
            for obj in info.systemObjects {
                lines.append("### `\(obj.identifier)`")
                if let desc = obj.description { lines.append("") ; lines.append(desc) }
                if !obj.capabilities.isEmpty {
                    lines.append("")
                    lines.append("**Capabilities:** \(obj.capabilities.joined(separator: ", "))")
                }
                lines.append("")
            }
        }

        // Event Subscriptions
        if !info.events.isEmpty {
            lines.append("## Event Subscriptions")
            lines.append("")
            for event in info.events {
                lines.append("- `\(event)`")
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - HTML Generation

    private func generateHTML(metadata: BasicManifest, info: PluginDocInfo) -> String {
        let handle = metadata.handle.map { " (<code>\($0)</code>)" } ?? ""
        var html = """
            <!DOCTYPE html>
            <html lang="en">
            <head>
              <meta charset="UTF-8">
              <title>\(metadata.name) — ARO Plugin Documentation</title>
              <style>
                body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
                       max-width: 900px; margin: 2rem auto; padding: 0 1.5rem; line-height: 1.6; }
                h1 { border-bottom: 2px solid #ddd; padding-bottom: .4rem; }
                h2 { margin-top: 2rem; border-bottom: 1px solid #eee; }
                h3 { color: #333; }
                code { background: #f4f4f4; padding: .1rem .35rem; border-radius: 3px; font-size: .9em; }
                pre  { background: #f8f8f8; padding: 1rem; border-radius: 6px; overflow-x: auto; }
                table { border-collapse: collapse; width: 100%; }
                th, td { text-align: left; padding: .45rem .8rem; border-bottom: 1px solid #ddd; }
                th { background: #f5f5f5; }
                .meta { color: #666; font-size: .9em; margin-bottom: 1rem; }
                .badge { display: inline-block; background: #e0eaff; color: #1a3a7a;
                         padding: .1rem .5rem; border-radius: 12px; font-size: .8em; }
              </style>
            </head>
            <body>
            <h1>\(metadata.name)\(handle)</h1>
            <p class="meta">
              <strong>Version:</strong> \(metadata.version)
            """
        if let author = metadata.author { html += "  &nbsp;·&nbsp; <strong>Author:</strong> \(author)\n" }
        if let license = metadata.license { html += "  &nbsp;·&nbsp; <strong>License:</strong> \(license)\n" }
        html += "</p>\n"

        if let desc = metadata.description {
            html += "<p>\(htmlEscape(desc))</p>\n"
        }

        // Actions
        if !info.actions.isEmpty {
            html += "<h2>Actions</h2>\n"
            for action in info.actions {
                html += "<h3>\(action.name)</h3>\n"
                if let desc = action.description { html += "<p>\(htmlEscape(desc))</p>\n" }
                html += "<ul>\n"
                if let role = action.role { html += "  <li><strong>Role:</strong> \(role)</li>\n" }
                if !action.verbs.isEmpty {
                    let verbStr = action.verbs.map { "<code>\($0)</code>" }.joined(separator: ", ")
                    html += "  <li><strong>Verbs:</strong> \(verbStr)</li>\n"
                }
                if !action.prepositions.isEmpty {
                    html += "  <li><strong>Prepositions:</strong> \(action.prepositions.joined(separator: ", "))</li>\n"
                }
                if let since = action.since { html += "  <li><strong>Since:</strong> \(since)</li>\n" }
                html += "</ul>\n"
            }
        }

        // Qualifiers
        if !info.qualifiers.isEmpty {
            let ns = (metadata.handle ?? metadata.name).lowercased()
            html += "<h2>Qualifiers</h2>\n"
            html += "<p>Access as <code>&lt;value: \(ns).qualifier-name&gt;</code>.</p>\n"
            html += "<table><thead><tr><th>Qualifier</th><th>Input Types</th><th>Description</th></tr></thead><tbody>\n"
            for q in info.qualifiers {
                let types = q.inputTypes.isEmpty ? "Any" : q.inputTypes.joined(separator: ", ")
                let desc = q.description.map { htmlEscape($0) } ?? ""
                let params = q.acceptsParameters ? " <span class='badge'>params</span>" : ""
                html += "  <tr><td><code>\(ns).\(q.name)</code></td><td>\(types)</td><td>\(desc)\(params)</td></tr>\n"
            }
            html += "</tbody></table>\n"
        }

        // Services
        if !info.services.isEmpty {
            html += "<h2>Services</h2>\n"
            for service in info.services {
                html += "<h3>\(service.name)</h3>\n"
                if !service.methods.isEmpty {
                    let methodStr = service.methods.map { "<code>\($0)</code>" }.joined(separator: ", ")
                    html += "<p><strong>Methods:</strong> \(methodStr)</p>\n"
                }
            }
        }

        // System Objects
        if !info.systemObjects.isEmpty {
            html += "<h2>System Objects</h2>\n"
            for obj in info.systemObjects {
                html += "<h3><code>\(obj.identifier)</code></h3>\n"
                if let desc = obj.description { html += "<p>\(htmlEscape(desc))</p>\n" }
                if !obj.capabilities.isEmpty {
                    let capStr = obj.capabilities.map { "<code>\($0)</code>" }.joined(separator: ", ")
                    html += "<p><strong>Capabilities:</strong> \(capStr)</p>\n"
                }
            }
        }

        // Events
        if !info.events.isEmpty {
            html += "<h2>Event Subscriptions</h2>\n<ul>\n"
            for event in info.events { html += "  <li><code>\(htmlEscape(event))</code></li>\n" }
            html += "</ul>\n"
        }

        html += """
            </body>
            </html>
            """
        return html
    }

    private func htmlEscape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - String Helpers

private extension String {
    /// Drop a known prefix from the start of the string
    func dropPrefix(_ prefix: String) -> String {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self
    }

    /// Remove surrounding single or double quotes
    var unquoted: String {
        let t = trimmingCharacters(in: .whitespaces)
        if (t.hasPrefix("\"") && t.hasSuffix("\"")) ||
           (t.hasPrefix("'")  && t.hasSuffix("'")) {
            return String(t.dropFirst().dropLast())
        }
        return t
    }
}
