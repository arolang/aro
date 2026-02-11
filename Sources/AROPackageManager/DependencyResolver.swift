// ============================================================
// DependencyResolver.swift
// ARO Package Manager - Dependency Resolution
// ============================================================

import Foundation

// MARK: - Dependency Resolver

/// Resolves plugin dependencies
///
/// The resolver ensures all dependencies are satisfied and determines
/// the correct installation order.
public final class DependencyResolver: Sendable {
    /// Currently installed plugins
    private let installedPlugins: [String: PluginManifest]

    /// Initialize with installed plugins
    /// - Parameter installed: Map of plugin name to manifest
    public init(installed: [String: PluginManifest] = [:]) {
        self.installedPlugins = installed
    }

    /// Initialize from a plugins directory
    /// - Parameter directory: Path to Plugins/ directory
    public init(directory: URL) throws {
        let scanner = PluginScanner(directory: directory)
        let plugins = try scanner.scan()
        var installed: [String: PluginManifest] = [:]
        for plugin in plugins {
            installed[plugin.manifest.name] = plugin.manifest
        }
        self.installedPlugins = installed
    }

    // MARK: - Resolution

    /// Resolve dependencies for a new plugin
    /// - Parameter manifest: The plugin to resolve dependencies for
    /// - Returns: Resolution result with required actions
    public func resolve(_ manifest: PluginManifest) throws -> ResolutionResult {
        var toInstall: [DependencySpec] = []
        var satisfied: [String] = []
        var conflicts: [DependencyConflict] = []

        guard let dependencies = manifest.dependencies else {
            // No dependencies
            return ResolutionResult(
                toInstall: [],
                satisfied: [],
                conflicts: []
            )
        }

        for (depName, depSpec) in dependencies {
            if let installed = installedPlugins[depName] {
                // Check version compatibility
                if let requiredRef = depSpec.ref {
                    let compatible = isVersionCompatible(
                        installed: installed.version,
                        required: requiredRef
                    )
                    if compatible {
                        satisfied.append(depName)
                    } else {
                        conflicts.append(DependencyConflict(
                            dependency: depName,
                            installedVersion: installed.version,
                            requiredVersion: requiredRef,
                            requiredBy: manifest.name
                        ))
                    }
                } else {
                    // No specific version required
                    satisfied.append(depName)
                }
            } else {
                // Need to install
                toInstall.append(DependencySpec(git: depSpec.git, ref: depSpec.ref))
            }
        }

        return ResolutionResult(
            toInstall: toInstall,
            satisfied: satisfied,
            conflicts: conflicts
        )
    }

    /// Check if all dependencies for a manifest are satisfied
    /// - Parameter manifest: The manifest to check
    /// - Returns: List of missing dependencies
    public func checkDependencies(_ manifest: PluginManifest) -> [String] {
        var missing: [String] = []

        guard let dependencies = manifest.dependencies else {
            return []
        }

        for depName in dependencies.keys {
            if installedPlugins[depName] == nil {
                missing.append(depName)
            }
        }

        return missing
    }

    /// Get the installation order for a set of plugins
    /// - Parameter plugins: Plugins to order
    /// - Returns: Ordered list (dependencies first)
    public func installationOrder(_ plugins: [PluginManifest]) throws -> [PluginManifest] {
        // Build dependency graph
        var nameToManifest: [String: PluginManifest] = [:]
        for plugin in plugins {
            nameToManifest[plugin.name] = plugin
        }

        // Add installed plugins
        for (name, manifest) in installedPlugins {
            nameToManifest[name] = manifest
        }

        // Topological sort
        var inDegree: [String: Int] = [:]
        var graph: [String: [String]] = [:]

        for plugin in plugins {
            inDegree[plugin.name] = 0
            graph[plugin.name] = []
        }

        for plugin in plugins {
            if let deps = plugin.dependencies {
                for depName in deps.keys {
                    if nameToManifest[depName] != nil {
                        inDegree[plugin.name, default: 0] += 1
                        graph[depName, default: []].append(plugin.name)
                    }
                }
            }
        }

        var queue: [String] = []
        for (name, degree) in inDegree {
            if degree == 0 {
                queue.append(name)
            }
        }

        var sorted: [PluginManifest] = []
        while !queue.isEmpty {
            let name = queue.removeFirst()
            if let manifest = nameToManifest[name], plugins.contains(where: { $0.name == name }) {
                sorted.append(manifest)
            }

            for dependent in graph[name, default: []] {
                inDegree[dependent, default: 0] -= 1
                if inDegree[dependent] == 0 {
                    queue.append(dependent)
                }
            }
        }

        if sorted.count != plugins.count {
            throw ResolverError.circularDependency
        }

        return sorted
    }

    // MARK: - Version Checking

    /// Check if an installed version satisfies the requirement
    private func isVersionCompatible(installed: String, required: String) -> Bool {
        // Handle version constraints like >=1.0.0, ^1.0.0, ~1.0.0
        if required.hasPrefix(">=") {
            let minVersion = String(required.dropFirst(2))
            return compareVersions(installed, minVersion) >= 0
        } else if required.hasPrefix("<=") {
            let maxVersion = String(required.dropFirst(2))
            return compareVersions(installed, maxVersion) <= 0
        } else if required.hasPrefix("^") {
            // Caret: compatible with major version
            let baseVersion = String(required.dropFirst(1))
            return isMajorCompatible(installed, baseVersion)
        } else if required.hasPrefix("~") {
            // Tilde: compatible with minor version
            let baseVersion = String(required.dropFirst(1))
            return isMinorCompatible(installed, baseVersion)
        } else if required.hasPrefix("v") {
            // Exact version with v prefix
            return installed == String(required.dropFirst(1)) || installed == required
        } else {
            // Exact version match or ref name
            return installed == required
        }
    }

    /// Compare two semver version strings
    /// Returns: negative if v1 < v2, 0 if equal, positive if v1 > v2
    private func compareVersions(_ v1: String, _ v2: String) -> Int {
        let parts1 = v1.split(separator: ".").compactMap { Int($0) }
        let parts2 = v2.split(separator: ".").compactMap { Int($0) }

        let maxLen = max(parts1.count, parts2.count)
        for i in 0..<maxLen {
            let p1 = i < parts1.count ? parts1[i] : 0
            let p2 = i < parts2.count ? parts2[i] : 0
            if p1 != p2 {
                return p1 - p2
            }
        }
        return 0
    }

    /// Check major version compatibility (^1.0.0 style)
    private func isMajorCompatible(_ installed: String, _ required: String) -> Bool {
        let instParts = installed.split(separator: ".").compactMap { Int($0) }
        let reqParts = required.split(separator: ".").compactMap { Int($0) }

        guard !instParts.isEmpty, !reqParts.isEmpty else { return false }

        // Major must match, installed >= required
        return instParts[0] == reqParts[0] && compareVersions(installed, required) >= 0
    }

    /// Check minor version compatibility (~1.0.0 style)
    private func isMinorCompatible(_ installed: String, _ required: String) -> Bool {
        let instParts = installed.split(separator: ".").compactMap { Int($0) }
        let reqParts = required.split(separator: ".").compactMap { Int($0) }

        guard instParts.count >= 2, reqParts.count >= 2 else { return false }

        // Major and minor must match, installed >= required
        return instParts[0] == reqParts[0] &&
               instParts[1] == reqParts[1] &&
               compareVersions(installed, required) >= 0
    }
}

// MARK: - Resolution Result

/// Result of dependency resolution
public struct ResolutionResult: Sendable {
    /// Dependencies that need to be installed
    public let toInstall: [DependencySpec]

    /// Dependencies that are already satisfied
    public let satisfied: [String]

    /// Conflicting dependencies
    public let conflicts: [DependencyConflict]

    /// Whether resolution was successful (no conflicts)
    public var isResolved: Bool {
        conflicts.isEmpty
    }
}

// MARK: - Dependency Conflict

/// Represents a dependency conflict
public struct DependencyConflict: Sendable {
    /// Name of the conflicting dependency
    public let dependency: String

    /// Currently installed version
    public let installedVersion: String

    /// Version required by the new plugin
    public let requiredVersion: String

    /// Plugin that requires this version
    public let requiredBy: String
}

// MARK: - Resolver Errors

/// Errors that can occur during dependency resolution
public enum ResolverError: Error, CustomStringConvertible {
    case circularDependency
    case unsatisfiableDependency(String)
    case versionConflict(DependencyConflict)

    public var description: String {
        switch self {
        case .circularDependency:
            return "Circular dependency detected"
        case .unsatisfiableDependency(let name):
            return "Cannot satisfy dependency: \(name)"
        case .versionConflict(let conflict):
            return "Version conflict for '\(conflict.dependency)': installed \(conflict.installedVersion), required \(conflict.requiredVersion) by \(conflict.requiredBy)"
        }
    }
}
