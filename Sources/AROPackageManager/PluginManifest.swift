// ============================================================
// PluginManifest.swift
// ARO Package Manager - Plugin Manifest Parser
// ============================================================

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Yams

// MARK: - Plugin Manifest

/// Represents the plugin.yaml manifest file
///
/// Every plugin must have a `plugin.yaml` in its root directory.
/// This file is the single source of truth for plugin metadata.
///
/// ## Example plugin.yaml
/// ```yaml
/// name: my-plugin
/// version: 1.0.0
/// description: "My awesome plugin"
/// author: "Developer Name"
/// license: MIT
/// aro-version: ">=0.1.0"
///
/// source:
///   git: "git@github.com:user/plugin.git"
///   ref: "main"
///   commit: "abc123"
///
/// provides:
///   - type: aro-files
///     path: features/
///   - type: swift-plugin
///     path: Sources/
///
/// dependencies:
///   other-plugin:
///     git: "git@github.com:user/other-plugin.git"
///     ref: "v1.0.0"
/// ```
public struct PluginManifest: Codable, Sendable, Equatable {
    /// Plugin name (required)
    public let name: String

    /// Plugin version using semver (required)
    public let version: String

    /// Human-readable description
    public let description: String?

    /// Plugin author
    public let author: String?

    /// License identifier (e.g., MIT, Apache-2.0)
    public let license: String?

    /// Minimum ARO version required
    public let aroVersion: String?

    /// Source information (populated by `aro add`)
    public let source: SourceInfo?

    /// What this plugin provides
    public let provides: [ProvideEntry]

    /// Dependencies on other plugins
    public let dependencies: [String: DependencySpec]?

    /// Build configuration
    public let build: BuildConfig?

    // MARK: - Coding Keys

    enum CodingKeys: String, CodingKey {
        case name
        case version
        case description
        case author
        case license
        case aroVersion = "aro-version"
        case source
        case provides
        case dependencies
        case build
    }

    // MARK: - Initialization

    public init(
        name: String,
        version: String,
        description: String? = nil,
        author: String? = nil,
        license: String? = nil,
        aroVersion: String? = nil,
        source: SourceInfo? = nil,
        provides: [ProvideEntry] = [],
        dependencies: [String: DependencySpec]? = nil,
        build: BuildConfig? = nil
    ) {
        self.name = name
        self.version = version
        self.description = description
        self.author = author
        self.license = license
        self.aroVersion = aroVersion
        self.source = source
        self.provides = provides
        self.dependencies = dependencies
        self.build = build
    }

    // MARK: - Parsing

    /// Parse a plugin.yaml file
    /// - Parameter url: Path to the plugin.yaml file
    /// - Returns: Parsed manifest
    public static func parse(from url: URL) throws -> PluginManifest {
        let contents = try String(contentsOf: url, encoding: .utf8)
        return try parse(yaml: contents)
    }

    /// Parse plugin.yaml from a string
    /// - Parameter yaml: YAML string
    /// - Returns: Parsed manifest
    public static func parse(yaml: String) throws -> PluginManifest {
        let decoder = YAMLDecoder()
        do {
            let manifest = try decoder.decode(PluginManifest.self, from: yaml)
            try manifest.validate()
            return manifest
        } catch let error as DecodingError {
            throw ManifestError.invalidYAML(error.localizedDescription)
        }
    }

    // MARK: - Validation

    /// Validate the manifest
    public func validate() throws {
        // Name is required and must be valid
        guard !name.isEmpty else {
            throw ManifestError.missingRequiredField("name")
        }

        guard isValidPackageName(name) else {
            throw ManifestError.invalidPackageName(name)
        }

        // Version is required
        guard !version.isEmpty else {
            throw ManifestError.missingRequiredField("version")
        }

        // Provides is required (at least one entry)
        guard !provides.isEmpty else {
            throw ManifestError.missingRequiredField("provides")
        }

        // Validate each provide entry
        for entry in provides {
            try entry.validate()
        }
    }

    /// Check if a package name is valid
    private func isValidPackageName(_ name: String) -> Bool {
        // Package names must be lowercase alphanumeric with hyphens
        let regex = try? NSRegularExpression(pattern: "^[a-z][a-z0-9-]*[a-z0-9]$|^[a-z]$")
        let range = NSRange(name.startIndex..., in: name)
        return regex?.firstMatch(in: name, range: range) != nil
    }

    // MARK: - Serialization

    /// Serialize manifest to YAML
    public func toYAML() throws -> String {
        let encoder = YAMLEncoder()
        return try encoder.encode(self)
    }

    /// Write manifest to file
    public func write(to url: URL) throws {
        let yaml = try toYAML()
        try yaml.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Source Info

/// Information about where a plugin came from
public struct SourceInfo: Codable, Sendable, Equatable {
    /// Git repository URL
    public let git: String?

    /// Git reference (branch, tag, or commit)
    public let ref: String?

    /// Full commit hash
    public let commit: String?

    public init(git: String? = nil, ref: String? = nil, commit: String? = nil) {
        self.git = git
        self.ref = ref
        self.commit = commit
    }
}

// MARK: - Provide Entry

/// Describes what a plugin provides
public struct ProvideEntry: Codable, Sendable, Equatable {
    /// Type of content
    public let type: ProvideType

    /// Path relative to plugin root
    public let path: String

    /// Build configuration for this entry (optional)
    public let build: ProvideEntryBuild?

    /// Python-specific configuration (optional)
    public let python: PythonConfig?

    public init(
        type: ProvideType,
        path: String,
        build: ProvideEntryBuild? = nil,
        python: PythonConfig? = nil
    ) {
        self.type = type
        self.path = path
        self.build = build
        self.python = python
    }

    /// Validate the provide entry
    public func validate() throws {
        guard !path.isEmpty else {
            throw ManifestError.invalidProvideEntry("path cannot be empty")
        }
    }
}

/// Types of content a plugin can provide
public enum ProvideType: String, Codable, Sendable, Equatable {
    case aroFiles = "aro-files"
    case swiftPlugin = "swift-plugin"
    case aroTemplates = "aro-templates"
    case rustPlugin = "rust-plugin"
    case cPlugin = "c-plugin"
    case cppPlugin = "cpp-plugin"
    case pythonPlugin = "python-plugin"
}

/// Build configuration for a provide entry
public struct ProvideEntryBuild: Codable, Sendable, Equatable {
    /// Cargo target for Rust plugins
    public let cargoTarget: String?

    /// Compiler for C/C++ plugins
    public let compiler: String?

    /// Compiler flags
    public let flags: [String]?

    /// Output file name
    public let output: String?

    enum CodingKeys: String, CodingKey {
        case cargoTarget = "cargo-target"
        case compiler
        case flags
        case output
    }

    public init(
        cargoTarget: String? = nil,
        compiler: String? = nil,
        flags: [String]? = nil,
        output: String? = nil
    ) {
        self.cargoTarget = cargoTarget
        self.compiler = compiler
        self.flags = flags
        self.output = output
    }
}

/// Python-specific configuration
public struct PythonConfig: Codable, Sendable, Equatable {
    /// Minimum Python version
    public let minVersion: String?

    /// Path to requirements.txt
    public let requirements: String?

    enum CodingKeys: String, CodingKey {
        case minVersion = "min-version"
        case requirements
    }

    public init(minVersion: String? = nil, requirements: String? = nil) {
        self.minVersion = minVersion
        self.requirements = requirements
    }
}

// MARK: - Dependency Spec

/// Specification for a plugin dependency
public struct DependencySpec: Codable, Sendable, Equatable {
    /// Git repository URL
    public let git: String

    /// Git reference (version, tag, or branch)
    public let ref: String?

    public init(git: String, ref: String? = nil) {
        self.git = git
        self.ref = ref
    }
}

// MARK: - Build Config

/// Build configuration for the plugin
public struct BuildConfig: Codable, Sendable, Equatable {
    /// Swift build settings
    public let swift: SwiftBuildConfig?

    public init(swift: SwiftBuildConfig? = nil) {
        self.swift = swift
    }
}

/// Swift-specific build configuration
public struct SwiftBuildConfig: Codable, Sendable, Equatable {
    /// Minimum Swift version
    public let minimumVersion: String?

    /// Build targets
    public let targets: [SwiftTarget]?

    enum CodingKeys: String, CodingKey {
        case minimumVersion = "minimum-version"
        case targets
    }

    public init(minimumVersion: String? = nil, targets: [SwiftTarget]? = nil) {
        self.minimumVersion = minimumVersion
        self.targets = targets
    }
}

/// Swift build target
public struct SwiftTarget: Codable, Sendable, Equatable {
    /// Target name
    public let name: String

    /// Source path
    public let path: String

    public init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}

// MARK: - Manifest Errors

/// Errors that can occur when parsing or validating manifests
public enum ManifestError: Error, CustomStringConvertible {
    case fileNotFound(String)
    case invalidYAML(String)
    case missingRequiredField(String)
    case invalidPackageName(String)
    case invalidProvideEntry(String)
    case incompatibleAroVersion(required: String, current: String)

    public var description: String {
        switch self {
        case .fileNotFound(let path):
            return "plugin.yaml not found at: \(path)"
        case .invalidYAML(let message):
            return "Invalid YAML in plugin.yaml: \(message)"
        case .missingRequiredField(let field):
            return "Missing required field in plugin.yaml: \(field)"
        case .invalidPackageName(let name):
            return "Invalid package name '\(name)'. Must be lowercase alphanumeric with hyphens."
        case .invalidProvideEntry(let message):
            return "Invalid provides entry: \(message)"
        case .incompatibleAroVersion(let required, let current):
            return "Plugin requires ARO \(required), but current version is \(current)"
        }
    }
}
