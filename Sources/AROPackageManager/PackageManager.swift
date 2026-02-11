// ============================================================
// PackageManager.swift
// ARO Package Manager - Main Logic
// ============================================================

import Foundation

// MARK: - Package Manager

/// Main entry point for package management operations
///
/// The PackageManager coordinates scanning, dependency resolution,
/// installation, and updates of ARO plugins.
///
/// ## Usage
/// ```swift
/// let pm = PackageManager(applicationDirectory: appDir)
///
/// // Install a plugin
/// let result = try await pm.add(url: "git@github.com:user/plugin.git")
///
/// // List installed plugins
/// let plugins = try pm.list()
///
/// // Update all plugins
/// let updates = try await pm.updateAll()
/// ```
public final class PackageManager: Sendable {
    /// The application directory
    public let applicationDirectory: URL

    /// The plugins directory
    public let pluginsDirectory: URL

    /// Plugin installer
    private let installer: PluginInstaller

    /// Plugin scanner
    private let scanner: PluginScanner

    // MARK: - Initialization

    /// Initialize with an application directory
    /// - Parameter applicationDirectory: Path to the ARO application
    public init(applicationDirectory: URL) {
        self.applicationDirectory = applicationDirectory
        self.pluginsDirectory = applicationDirectory.appendingPathComponent("Plugins")
        self.installer = PluginInstaller(directory: pluginsDirectory)
        self.scanner = PluginScanner(directory: pluginsDirectory)
    }

    /// Initialize with a specific plugins directory
    /// - Parameters:
    ///   - applicationDirectory: Path to the ARO application
    ///   - pluginsDirectory: Custom plugins directory path
    public init(applicationDirectory: URL, pluginsDirectory: URL) {
        self.applicationDirectory = applicationDirectory
        self.pluginsDirectory = pluginsDirectory
        self.installer = PluginInstaller(directory: pluginsDirectory)
        self.scanner = PluginScanner(directory: pluginsDirectory)
    }

    // MARK: - Add

    /// Add a plugin from a Git URL
    /// - Parameters:
    ///   - url: Git repository URL
    ///   - ref: Optional reference (branch, tag, commit)
    /// - Returns: Installation result
    public func add(url: String, ref: String? = nil) throws -> InstallResult {
        // Resolve dependencies first
        let resolver = try DependencyResolver(directory: pluginsDirectory)

        // Install the plugin
        let result = try installer.install(from: url, ref: ref)

        // Check and install dependencies
        let depResult = try resolver.resolve(result.toManifest())
        if !depResult.conflicts.isEmpty {
            print("[PackageManager] Warning: Dependency conflicts detected")
            for conflict in depResult.conflicts {
                print("  - \(conflict.dependency): installed \(conflict.installedVersion), required \(conflict.requiredVersion)")
            }
        }

        for dep in depResult.toInstall {
            print("[PackageManager] Installing dependency: \(GitClient.shared.extractRepoName(from: dep.git))")
            _ = try installer.install(from: dep.git, ref: dep.ref)
        }

        return result
    }

    /// Add a plugin from a local directory
    /// - Parameter path: Path to the plugin directory
    /// - Returns: Installation result
    public func addLocal(path: URL) throws -> InstallResult {
        try installer.installLocal(from: path)
    }

    // MARK: - Remove

    /// Remove an installed plugin
    /// - Parameter name: Plugin name
    public func remove(name: String) throws {
        // Check for dependents
        let plugins = try scanner.scan()
        for plugin in plugins {
            if let deps = plugin.manifest.dependencies, deps.keys.contains(name) {
                throw PackageManagerError.hasDependent(name, dependent: plugin.manifest.name)
            }
        }

        try installer.remove(name: name)
    }

    // MARK: - List

    /// List all installed plugins
    /// - Returns: Array of discovered plugins
    public func list() throws -> [DiscoveredPlugin] {
        try scanner.scan()
    }

    /// Get plugin info by name
    /// - Parameter name: Plugin name
    /// - Returns: Plugin info or nil if not found
    public func getPlugin(name: String) throws -> DiscoveredPlugin? {
        let plugins = try scanner.scan()
        return plugins.first { $0.manifest.name == name }
    }

    // MARK: - Update

    /// Update a specific plugin
    /// - Parameters:
    ///   - name: Plugin name
    ///   - ref: Optional new reference
    /// - Returns: Update result
    public func update(name: String, ref: String? = nil) throws -> UpdateResult {
        try installer.update(name: name, ref: ref)
    }

    /// Update all installed plugins
    /// - Returns: Array of update results
    public func updateAll() throws -> [UpdateResult] {
        var results: [UpdateResult] = []

        let plugins = try scanner.scan()
        for plugin in plugins {
            // Only update plugins with source info
            if plugin.manifest.source?.git != nil {
                do {
                    let result = try installer.update(name: plugin.manifest.name)
                    results.append(result)
                } catch {
                    print("[PackageManager] Failed to update \(plugin.manifest.name): \(error)")
                }
            }
        }

        return results
    }

    // MARK: - Validation

    /// Validate all installed plugins
    /// - Returns: Validation result
    public func validate() throws -> ValidationResult {
        let plugins = try scanner.scan()
        return scanner.validate(plugins)
    }

    /// Check if all dependencies are satisfied
    /// - Returns: List of missing dependencies
    public func checkDependencies() throws -> [String: [String]] {
        var missing: [String: [String]] = [:]

        let plugins = try scanner.scan()
        let resolver = try DependencyResolver(directory: pluginsDirectory)

        for plugin in plugins {
            let deps = resolver.checkDependencies(plugin.manifest)
            if !deps.isEmpty {
                missing[plugin.manifest.name] = deps
            }
        }

        return missing
    }

    // MARK: - Restore

    /// Restore plugins from a .aro-sources file
    /// - Parameter sourcesFile: Path to .aro-sources file
    /// - Returns: Array of installation results
    public func restore(from sourcesFile: URL) throws -> [InstallResult] {
        var results: [InstallResult] = []

        let contents = try String(contentsOf: sourcesFile, encoding: .utf8)
        let lines = contents.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }

        for line in lines {
            // Skip comments and empty lines
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }

            // Parse: url [ref]
            let parts = line.split(separator: " ", maxSplits: 1)
            let url = String(parts[0])
            let ref = parts.count > 1 ? String(parts[1]) : nil

            do {
                let result = try add(url: url, ref: ref)
                results.append(result)
            } catch InstallerError.alreadyInstalled {
                // Already installed, skip
                continue
            }
        }

        return results
    }

    /// Export installed plugins to a .aro-sources file
    /// - Parameter sourcesFile: Path to write .aro-sources file
    public func export(to sourcesFile: URL) throws {
        var lines: [String] = [
            "# ARO Plugin Sources",
            "# Generated by aro plugins export",
            "# Format: git-url [ref]",
            ""
        ]

        let plugins = try scanner.scan()
        for plugin in plugins {
            if let source = plugin.manifest.source, let git = source.git {
                let ref = source.ref ?? ""
                lines.append("\(git) \(ref)".trimmingCharacters(in: .whitespaces))
            }
        }

        let content = lines.joined(separator: "\n")
        try content.write(to: sourcesFile, atomically: true, encoding: .utf8)
    }
}

// MARK: - InstallResult Extension

extension InstallResult {
    /// Convert to PluginManifest
    func toManifest() -> PluginManifest {
        PluginManifest(
            name: name,
            version: version,
            source: SourceInfo(git: nil, ref: ref, commit: commit),
            provides: provides
        )
    }
}

// MARK: - Package Manager Errors

/// Errors that can occur during package management
public enum PackageManagerError: Error, CustomStringConvertible {
    case hasDependent(String, dependent: String)
    case invalidSourcesFile(String)

    public var description: String {
        switch self {
        case .hasDependent(let plugin, let dependent):
            return "Cannot remove '\(plugin)': required by '\(dependent)'"
        case .invalidSourcesFile(let message):
            return "Invalid .aro-sources file: \(message)"
        }
    }
}

// MARK: - Exports

/// Public exports for the package
public struct AROPackageManagerExports {
    /// Re-export main types
    public typealias Manifest = PluginManifest
    public typealias Scanner = PluginScanner
    public typealias Installer = PluginInstaller
    public typealias Resolver = DependencyResolver
    public typealias Git = GitClient
    public typealias Manager = PackageManager
}
