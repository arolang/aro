// ============================================================
// PluginScanner.swift
// ARO Package Manager - Plugin Directory Scanner
// ============================================================

import Foundation

// MARK: - Plugin Scanner

/// Scans the Plugins/ directory and discovers installed plugins
///
/// The scanner reads plugin.yaml files from each subdirectory in Plugins/
/// and builds a registry of available plugins.
///
/// ## Discovery Algorithm
/// ```
/// 1. Scan Plugins/ directory (one level deep)
/// 2. For each subdirectory:
///    a. Search for plugin.yaml
///    b. If not present → Issue warning, ignore directory
///    c. If present → Parse plugin.yaml
///    d. Validate required fields (name, version, provides)
///    e. Register plugin in PluginRegistry
/// 3. Check dependencies of all plugins against each other
/// 4. Load plugins in topological order (dependencies first)
/// ```
public final class PluginScanner: Sendable {
    /// The plugins directory to scan
    private let pluginsDirectory: URL

    /// Initialize with a plugins directory
    /// - Parameter directory: Path to the Plugins/ directory
    public init(directory: URL) {
        self.pluginsDirectory = directory
    }

    /// Initialize with an application directory (looks for Plugins/ subdirectory)
    /// - Parameter applicationDirectory: Path to the application directory
    public init(applicationDirectory: URL) {
        self.pluginsDirectory = applicationDirectory.appendingPathComponent("Plugins")
    }

    // MARK: - Scanning

    /// Scan the plugins directory and return discovered plugins
    /// - Returns: Array of discovered plugins with their manifests
    public func scan() throws -> [DiscoveredPlugin] {
        var plugins: [DiscoveredPlugin] = []
        var warnings: [String] = []

        // Check if plugins directory exists
        guard FileManager.default.fileExists(atPath: pluginsDirectory.path) else {
            return [] // No plugins directory, nothing to load
        }

        // Get subdirectories
        let contents = try FileManager.default.contentsOfDirectory(
            at: pluginsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        for item in contents {
            // Check if it's a directory
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: item.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                continue
            }

            // Look for plugin.yaml
            let manifestPath = item.appendingPathComponent("plugin.yaml")
            guard FileManager.default.fileExists(atPath: manifestPath.path) else {
                warnings.append("Directory '\(item.lastPathComponent)' missing plugin.yaml, skipping")
                continue
            }

            // Parse manifest
            do {
                let manifest = try PluginManifest.parse(from: manifestPath)
                let plugin = DiscoveredPlugin(
                    path: item,
                    manifest: manifest
                )
                plugins.append(plugin)
            } catch {
                warnings.append("Failed to parse \(item.lastPathComponent)/plugin.yaml: \(error)")
            }
        }

        // Print warnings
        for warning in warnings {
            print("[PluginScanner] Warning: \(warning)")
        }

        return plugins
    }

    /// Scan and return plugins sorted by dependencies (dependencies first)
    /// - Returns: Sorted array of plugins
    public func scanSorted() throws -> [DiscoveredPlugin] {
        let plugins = try scan()
        return try sortByDependencies(plugins)
    }

    /// Sort plugins by dependencies using topological sort
    /// - Parameter plugins: Unsorted plugins
    /// - Returns: Plugins sorted so dependencies come first
    private func sortByDependencies(_ plugins: [DiscoveredPlugin]) throws -> [DiscoveredPlugin] {
        // Build name-to-plugin map
        var nameToPlugin: [String: DiscoveredPlugin] = [:]
        for plugin in plugins {
            nameToPlugin[plugin.manifest.name] = plugin
        }

        // Build dependency graph
        var inDegree: [String: Int] = [:]
        var graph: [String: [String]] = [:]

        for plugin in plugins {
            let name = plugin.manifest.name
            inDegree[name] = 0
            graph[name] = []
        }

        for plugin in plugins {
            let name = plugin.manifest.name
            if let deps = plugin.manifest.dependencies {
                for depName in deps.keys {
                    // Only count dependencies that are available locally
                    if nameToPlugin[depName] != nil {
                        inDegree[name, default: 0] += 1
                        graph[depName, default: []].append(name)
                    }
                }
            }
        }

        // Kahn's algorithm for topological sort
        var queue: [String] = []
        for (name, degree) in inDegree {
            if degree == 0 {
                queue.append(name)
            }
        }

        var sorted: [DiscoveredPlugin] = []
        while !queue.isEmpty {
            let name = queue.removeFirst()
            if let plugin = nameToPlugin[name] {
                sorted.append(plugin)
            }

            for dependent in graph[name, default: []] {
                inDegree[dependent, default: 0] -= 1
                if inDegree[dependent] == 0 {
                    queue.append(dependent)
                }
            }
        }

        // Check for cycles
        if sorted.count != plugins.count {
            let missing = Set(plugins.map { $0.manifest.name }).subtracting(sorted.map { $0.manifest.name })
            throw ScannerError.circularDependency(Array(missing))
        }

        return sorted
    }

    // MARK: - Validation

    /// Validate all discovered plugins and their dependencies
    /// - Parameter plugins: Plugins to validate
    /// - Returns: Validation result with any issues found
    public func validate(_ plugins: [DiscoveredPlugin]) -> ValidationResult {
        var errors: [String] = []
        var warnings: [String] = []

        // Check for duplicate plugin names
        var seenNames: Set<String> = []
        for plugin in plugins {
            if seenNames.contains(plugin.manifest.name) {
                errors.append("Duplicate plugin name: \(plugin.manifest.name)")
            }
            seenNames.insert(plugin.manifest.name)
        }

        // Check dependencies
        for plugin in plugins {
            if let deps = plugin.manifest.dependencies {
                for (depName, depSpec) in deps {
                    if !seenNames.contains(depName) {
                        warnings.append("\(plugin.manifest.name) depends on '\(depName)' which is not installed")
                    }
                    // Could add version checking here
                    _ = depSpec // Use the spec for future version checking
                }
            }
        }

        return ValidationResult(errors: errors, warnings: warnings)
    }
}

// MARK: - Discovered Plugin

/// A plugin discovered during scanning
public struct DiscoveredPlugin: Sendable {
    /// Path to the plugin directory
    public let path: URL

    /// Parsed manifest
    public let manifest: PluginManifest

    /// Get the path to a provided entry
    public func pathForProvide(_ provide: ProvideEntry) -> URL {
        path.appendingPathComponent(provide.path)
    }
}

// MARK: - Validation Result

/// Result of plugin validation
public struct ValidationResult: Sendable {
    /// Critical errors that prevent loading
    public let errors: [String]

    /// Non-critical warnings
    public let warnings: [String]

    /// Whether validation passed (no errors)
    public var isValid: Bool {
        errors.isEmpty
    }
}

// MARK: - Scanner Errors

/// Errors that can occur during scanning
public enum ScannerError: Error, CustomStringConvertible {
    case directoryNotFound(String)
    case circularDependency([String])
    case missingDependency(plugin: String, dependency: String)

    public var description: String {
        switch self {
        case .directoryNotFound(let path):
            return "Plugins directory not found: \(path)"
        case .circularDependency(let plugins):
            return "Circular dependency detected involving: \(plugins.joined(separator: ", "))"
        case .missingDependency(let plugin, let dependency):
            return "Plugin '\(plugin)' requires '\(dependency)' which is not installed"
        }
    }
}
