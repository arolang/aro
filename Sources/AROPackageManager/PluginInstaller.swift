// ============================================================
// PluginInstaller.swift
// ARO Package Manager - Plugin Installation
// ============================================================

import Foundation

// MARK: - Plugin Installer

/// Handles plugin installation, removal, and updates
public final class PluginInstaller: Sendable {
    /// The plugins directory
    private let pluginsDirectory: URL

    /// Git client
    private let git = GitClient.shared

    /// Initialize with a plugins directory
    /// - Parameter directory: Path to the Plugins/ directory
    public init(directory: URL) {
        self.pluginsDirectory = directory
    }

    /// Initialize with an application directory
    /// - Parameter applicationDirectory: Path to the application directory
    public init(applicationDirectory: URL) {
        self.pluginsDirectory = applicationDirectory.appendingPathComponent("Plugins")
    }

    // MARK: - Installation

    /// Install a plugin from a Git URL
    /// - Parameters:
    ///   - url: Git repository URL
    ///   - ref: Optional reference (branch, tag, commit)
    /// - Returns: Installation result
    public func install(from url: String, ref: String? = nil) throws -> InstallResult {
        // Parse URL to get plugin name
        let repoName = git.extractRepoName(from: url)

        // Check if already installed
        let pluginDir = pluginsDirectory.appendingPathComponent(repoName)
        if FileManager.default.fileExists(atPath: pluginDir.path) {
            throw InstallerError.alreadyInstalled(repoName)
        }

        // Create plugins directory if needed
        try FileManager.default.createDirectory(at: pluginsDirectory, withIntermediateDirectories: true)

        // Clone to temp directory first
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aro-install-\(UUID().uuidString)")

        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        // Clone repository
        let cloneResult = try git.clone(url: url, to: tempDir, ref: ref)

        // Validate plugin.yaml exists
        let manifestPath = tempDir.appendingPathComponent("plugin.yaml")
        guard FileManager.default.fileExists(atPath: manifestPath.path) else {
            throw InstallerError.missingManifest(repoName)
        }

        // Parse and validate manifest
        let manifest = try PluginManifest.parse(from: manifestPath)

        // Update manifest with source info
        let updatedManifest = PluginManifest(
            name: manifest.name,
            version: manifest.version,
            description: manifest.description,
            author: manifest.author,
            license: manifest.license,
            aroVersion: manifest.aroVersion,
            source: SourceInfo(
                git: url,
                ref: cloneResult.ref,
                commit: cloneResult.commit
            ),
            provides: manifest.provides,
            dependencies: manifest.dependencies,
            build: manifest.build
        )

        // Write updated manifest
        try updatedManifest.write(to: manifestPath)

        // Move to plugins directory
        try FileManager.default.moveItem(at: tempDir, to: pluginDir)

        // Build if necessary
        let buildResults = try buildPlugin(at: pluginDir, manifest: manifest)

        return InstallResult(
            name: manifest.name,
            version: manifest.version,
            path: pluginDir,
            ref: cloneResult.ref,
            commit: cloneResult.commit,
            provides: manifest.provides,
            buildResults: buildResults
        )
    }

    /// Install a plugin from a local directory
    /// - Parameter source: Path to the plugin source directory
    /// - Returns: Installation result
    public func installLocal(from source: URL) throws -> InstallResult {
        // Validate plugin.yaml exists
        let manifestPath = source.appendingPathComponent("plugin.yaml")
        guard FileManager.default.fileExists(atPath: manifestPath.path) else {
            throw InstallerError.missingManifest(source.lastPathComponent)
        }

        // Parse manifest
        let manifest = try PluginManifest.parse(from: manifestPath)

        // Check if already installed
        let pluginDir = pluginsDirectory.appendingPathComponent(manifest.name)
        if FileManager.default.fileExists(atPath: pluginDir.path) {
            throw InstallerError.alreadyInstalled(manifest.name)
        }

        // Create plugins directory if needed
        try FileManager.default.createDirectory(at: pluginsDirectory, withIntermediateDirectories: true)

        // Copy to plugins directory
        try FileManager.default.copyItem(at: source, to: pluginDir)

        // Build if necessary
        let buildResults = try buildPlugin(at: pluginDir, manifest: manifest)

        return InstallResult(
            name: manifest.name,
            version: manifest.version,
            path: pluginDir,
            ref: nil,
            commit: nil,
            provides: manifest.provides,
            buildResults: buildResults
        )
    }

    // MARK: - Removal

    /// Remove an installed plugin
    /// - Parameter name: Plugin name
    public func remove(name: String) throws {
        let pluginDir = pluginsDirectory.appendingPathComponent(name)

        guard FileManager.default.fileExists(atPath: pluginDir.path) else {
            throw InstallerError.notInstalled(name)
        }

        try FileManager.default.removeItem(at: pluginDir)
    }

    // MARK: - Update

    /// Update an installed plugin
    /// - Parameters:
    ///   - name: Plugin name
    ///   - ref: Optional new reference to update to
    /// - Returns: Update result
    public func update(name: String, ref: String? = nil) throws -> UpdateResult {
        let pluginDir = pluginsDirectory.appendingPathComponent(name)

        guard FileManager.default.fileExists(atPath: pluginDir.path) else {
            throw InstallerError.notInstalled(name)
        }

        // Read current manifest
        let manifestPath = pluginDir.appendingPathComponent("plugin.yaml")
        let manifest = try PluginManifest.parse(from: manifestPath)

        // Check if we have source info
        guard let source = manifest.source, let gitURL = source.git else {
            throw InstallerError.noSourceInfo(name)
        }

        let oldCommit = source.commit ?? "unknown"

        // Pull or fetch+checkout
        if let newRef = ref {
            try git.fetchAndReset(to: newRef, in: pluginDir)
        } else {
            try git.pull(in: pluginDir)
        }

        // Get new commit
        let newCommit = try git.getHeadCommit(in: pluginDir)
        let currentRef = ref ?? (try? git.getCurrentBranch(in: pluginDir)) ?? source.ref ?? "HEAD"

        // Update manifest with new commit info
        let updatedManifest = try PluginManifest.parse(from: manifestPath)
        let finalManifest = PluginManifest(
            name: updatedManifest.name,
            version: updatedManifest.version,
            description: updatedManifest.description,
            author: updatedManifest.author,
            license: updatedManifest.license,
            aroVersion: updatedManifest.aroVersion,
            source: SourceInfo(
                git: gitURL,
                ref: currentRef,
                commit: newCommit
            ),
            provides: updatedManifest.provides,
            dependencies: updatedManifest.dependencies,
            build: updatedManifest.build
        )
        try finalManifest.write(to: manifestPath)

        // Rebuild if necessary
        let buildResults = try buildPlugin(at: pluginDir, manifest: updatedManifest)

        return UpdateResult(
            name: name,
            oldVersion: manifest.version,
            newVersion: updatedManifest.version,
            oldCommit: oldCommit,
            newCommit: newCommit,
            buildResults: buildResults
        )
    }

    // MARK: - Building

    /// Build a plugin based on its provides entries
    private func buildPlugin(at pluginDir: URL, manifest: PluginManifest) throws -> [BuildResult] {
        var results: [BuildResult] = []

        for provide in manifest.provides {
            let providePath = pluginDir.appendingPathComponent(provide.path)

            switch provide.type {
            case .swiftPlugin:
                // Check for Package.swift
                let packageSwift = providePath.appendingPathComponent("Package.swift")
                if FileManager.default.fileExists(atPath: packageSwift.path) {
                    do {
                        try buildSwiftPackage(at: providePath)
                        results.append(BuildResult(type: .swiftPlugin, success: true, message: "Swift package built"))
                    } catch {
                        results.append(BuildResult(type: .swiftPlugin, success: false, message: "\(error)"))
                    }
                } else {
                    // Single file Swift plugins are compiled on-demand by PluginLoader
                    results.append(BuildResult(type: .swiftPlugin, success: true, message: "Swift sources ready"))
                }

            case .rustPlugin:
                if let build = provide.build {
                    do {
                        try buildRustPlugin(at: providePath, config: build)
                        results.append(BuildResult(type: .rustPlugin, success: true, message: "Rust plugin built"))
                    } catch {
                        results.append(BuildResult(type: .rustPlugin, success: false, message: "\(error)"))
                    }
                }

            case .cPlugin, .cppPlugin:
                if let build = provide.build {
                    do {
                        try buildCPlugin(at: providePath, config: build, isCpp: provide.type == .cppPlugin)
                        results.append(BuildResult(type: provide.type, success: true, message: "Native plugin built"))
                    } catch {
                        results.append(BuildResult(type: provide.type, success: false, message: "\(error)"))
                    }
                }

            case .pythonPlugin:
                // Check for requirements.txt
                if let pythonConfig = provide.python,
                   let requirements = pythonConfig.requirements {
                    let reqPath = providePath.appendingPathComponent(requirements)
                    if FileManager.default.fileExists(atPath: reqPath.path) {
                        do {
                            try installPythonDependencies(at: reqPath)
                            results.append(BuildResult(type: .pythonPlugin, success: true, message: "Python dependencies installed"))
                        } catch {
                            results.append(BuildResult(type: .pythonPlugin, success: false, message: "\(error)"))
                        }
                    }
                } else {
                    results.append(BuildResult(type: .pythonPlugin, success: true, message: "Python plugin ready"))
                }

            case .aroFiles, .aroTemplates:
                // No build needed for ARO files
                results.append(BuildResult(type: provide.type, success: true, message: "ARO files ready"))
            }
        }

        return results
    }

    /// Build a Swift package
    private func buildSwiftPackage(at path: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        process.currentDirectoryURL = path
        process.arguments = ["build", "-c", "release"]

        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw InstallerError.buildFailed("Swift build failed: \(errorMessage)")
        }
    }

    /// Build a Rust plugin
    private func buildRustPlugin(at path: URL, config: ProvideEntryBuild) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.currentDirectoryURL = path
        process.arguments = ["cargo", "build", "--release"]

        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw InstallerError.buildFailed("Cargo build failed: \(errorMessage)")
        }
    }

    /// Build a C/C++ plugin
    private func buildCPlugin(at path: URL, config: ProvideEntryBuild, isCpp: Bool) throws {
        let compiler = config.compiler ?? (isCpp ? "clang++" : "clang")
        let flags = config.flags ?? ["-O2", "-shared", "-fPIC"]
        let output = config.output ?? "libplugin.dylib"

        // Find source files
        let sources = try FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: nil)
            .filter { isCpp ? ($0.pathExtension == "cpp" || $0.pathExtension == "cc") : $0.pathExtension == "c" }

        guard !sources.isEmpty else {
            throw InstallerError.buildFailed("No source files found")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/\(compiler)")
        process.currentDirectoryURL = path
        process.arguments = flags + sources.map { $0.path } + ["-o", output]

        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw InstallerError.buildFailed("\(compiler) build failed: \(errorMessage)")
        }
    }

    /// Install Python dependencies
    private func installPythonDependencies(at requirementsPath: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["pip3", "install", "-r", requirementsPath.path, "--quiet"]

        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw InstallerError.buildFailed("pip install failed: \(errorMessage)")
        }
    }
}

// MARK: - Install Result

/// Result of a plugin installation
public struct InstallResult: Sendable {
    /// Plugin name
    public let name: String

    /// Plugin version
    public let version: String

    /// Installation path
    public let path: URL

    /// Git reference
    public let ref: String?

    /// Git commit hash
    public let commit: String?

    /// What the plugin provides
    public let provides: [ProvideEntry]

    /// Build results
    public let buildResults: [BuildResult]
}

// MARK: - Update Result

/// Result of a plugin update
public struct UpdateResult: Sendable {
    /// Plugin name
    public let name: String

    /// Previous version
    public let oldVersion: String

    /// New version
    public let newVersion: String

    /// Previous commit
    public let oldCommit: String

    /// New commit
    public let newCommit: String

    /// Build results
    public let buildResults: [BuildResult]

    /// Whether anything changed
    public var hasChanges: Bool {
        oldCommit != newCommit
    }
}

// MARK: - Build Result

/// Result of building a plugin component
public struct BuildResult: Sendable {
    /// Type of component built
    public let type: ProvideType

    /// Whether build succeeded
    public let success: Bool

    /// Build message
    public let message: String
}

// MARK: - Installer Errors

/// Errors that can occur during installation
public enum InstallerError: Error, CustomStringConvertible {
    case alreadyInstalled(String)
    case notInstalled(String)
    case missingManifest(String)
    case noSourceInfo(String)
    case buildFailed(String)
    case dependencyMissing(String)

    public var description: String {
        switch self {
        case .alreadyInstalled(let name):
            return "Plugin '\(name)' is already installed"
        case .notInstalled(let name):
            return "Plugin '\(name)' is not installed"
        case .missingManifest(let name):
            return "Plugin '\(name)' is missing plugin.yaml"
        case .noSourceInfo(let name):
            return "Plugin '\(name)' has no source info (was it installed manually?)"
        case .buildFailed(let message):
            return "Build failed: \(message)"
        case .dependencyMissing(let dep):
            return "Missing dependency: \(dep)"
        }
    }
}
