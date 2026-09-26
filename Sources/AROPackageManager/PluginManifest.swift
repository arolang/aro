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

    /// Namespace handle (PascalCase, e.g. `Stats`) — how plugin
    /// actions (`Stats.Sort`) and qualifiers (`<x: Stats.sort>`) are
    /// addressed. Optional in the schema, but it MUST survive the
    /// installer's manifest rewrite: dropping it silently renames
    /// every qualifier the plugin ships.
    public let handle: String?

    /// Human-readable description
    public let description: String?

    /// Plugin author
    public let author: String?

    /// License identifier (e.g., MIT, Apache-2.0)
    public let license: String?

    /// Minimum ARO version required (semver constraint, e.g. `">=1.0.0 <2.0.0"`)
    public let aroVersion: String?

    /// Source information (populated by `aro add`)
    public let source: SourceInfo?

    /// What this plugin provides
    public let provides: [ProvideEntry]

    /// Dependencies on other plugins
    public let dependencies: [String: DependencySpec]?

    /// Required system libraries (e.g. `["libsqlite3"]`)
    public let system: [String]?

    /// Build configuration
    public let build: BuildConfig?

    // MARK: - Coding Keys

    enum CodingKeys: String, CodingKey {
        case name
        case version
        case handle
        case description
        case author
        case license
        case aroVersion = "aro-version"
        case source
        case provides
        case dependencies
        case system
        case build
    }

    // MARK: - Initialization

    public init(
        name: String,
        version: String,
        handle: String? = nil,
        description: String? = nil,
        author: String? = nil,
        license: String? = nil,
        aroVersion: String? = nil,
        source: SourceInfo? = nil,
        provides: [ProvideEntry] = [],
        dependencies: [String: DependencySpec]? = nil,
        system: [String]? = nil,
        build: BuildConfig? = nil
    ) {
        self.name = name
        self.version = version
        self.handle = handle
        self.description = description
        self.author = author
        self.license = license
        self.aroVersion = aroVersion
        self.source = source
        self.provides = provides
        self.dependencies = dependencies
        self.system = system
        self.build = build
    }

    // MARK: - Copying

    /// A copy of this manifest with different source information.
    ///
    /// This is the *only* thing the installer changes about a plugin's
    /// `plugin.yaml`: it stamps in where the plugin came from. Every call site
    /// used to do that by rebuilding `PluginManifest(name:version:…)` by hand,
    /// and `update` left `handle:` off the list — silently renaming every
    /// qualifier and action the plugin ships, so `Collections.pick-random`
    /// stopped resolving the moment the user ran `aro plugins update`
    /// (GitLab #661).
    ///
    /// Enumerating the fields once, here, is what keeps that from happening
    /// again the next time the manifest grows a field.
    public func with(source newSource: SourceInfo?) -> PluginManifest {
        PluginManifest(
            name: name,
            version: version,
            handle: handle,
            description: description,
            author: author,
            license: license,
            aroVersion: aroVersion,
            source: newSource,
            provides: provides,
            dependencies: dependencies,
            system: system,
            build: build
        )
    }

    // MARK: - Declared languages

    /// Whether the manifest declares a Python plugin, which runs through an
    /// interpreter rather than being compiled and statically linked.
    public var declaresPythonPlugin: Bool {
        provides.contains { $0.type == .pythonPlugin }
    }

    /// Whether the manifest declares compiled code (Swift/C/C++/Rust). A
    /// manifest with none of those ships only feature sets or templates and has
    /// nothing to statically link.
    public var declaresNativePlugin: Bool {
        nativeLanguage != nil
    }

    /// The language a native plugin is built as.
    ///
    /// Read off the decoded `provides` entries rather than by looking for the
    /// type name somewhere in the manifest text (GitLab #734): a *comment*
    /// mentioning `rust-plugin`, or a description that happens to contain it,
    /// used to decide how a plugin was compiled.
    ///
    /// The order reproduces the old first-match-wins chain for the (unusual)
    /// manifest that declares more than one native language.
    public var nativeLanguage: NativePluginLanguage? {
        let declared = Set(provides.map(\.type))
        for language in NativePluginLanguage.allCases where declared.contains(language.provideType) {
            return language
        }
        return nil
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
        let manifest = try decode(yaml: yaml)
        try manifest.validate()
        return manifest
    }

    /// Decode a manifest **without** validating it.
    ///
    /// Reading a manifest and approving one are different questions, and only
    /// `aro add` / install need the second. Asking "which language is this
    /// plugin written in?" must not depend on whether the name passes the
    /// package-name rule: `Examples/ZipService` declares `name: ZipPlugin`,
    /// which `validate()` rejects as not-lowercase, and routing it through the
    /// validating parser made the compiler treat a perfectly good Swift plugin
    /// as declaring no code to link (GitLab #734, found by ZipService failing
    /// in compiled mode).
    public static func decode(yaml: String) throws -> PluginManifest {
        let decoder = YAMLDecoder()
        do {
            return try decoder.decode(PluginManifest.self, from: yaml)
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

// MARK: - Action Declaration

/// Metadata for a single action declared in a plugin's `provides` entry.
///
/// The `since` field enables per-action API versioning: the action is only
/// available when the running ARO version satisfies `>= since`.
public struct ActionDeclaration: Codable, Sendable, Equatable {
    /// Action name (e.g. "ParseCSV")
    public let name: String

    /// Minimum ARO version this action requires (e.g. `"1.1.0"`)
    public let since: String?

    /// Human-readable description
    public let description: String?

    public init(name: String, since: String? = nil, description: String? = nil) {
        self.name = name
        self.since = since
        self.description = description
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

    /// Actions declared in this provide entry (used for per-action `since` versioning)
    public let actions: [ActionDeclaration]?

    public init(
        type: ProvideType,
        path: String,
        build: ProvideEntryBuild? = nil,
        python: PythonConfig? = nil,
        actions: [ActionDeclaration]? = nil
    ) {
        self.type = type
        self.path = path
        self.build = build
        self.python = python
        self.actions = actions
    }

    /// Validate the provide entry
    public func validate() throws {
        guard !path.isEmpty else {
            throw ManifestError.invalidProvideEntry("path cannot be empty")
        }
    }
}

/// A compiled language a plugin can be written in.
///
/// Declaration order is the precedence used when a manifest declares several
/// (`nativeLanguage`).
public enum NativePluginLanguage: String, Sendable, Equatable, CaseIterable {
    case rust
    case cpp
    case c
    case swift

    /// The `provides:` entry type that declares this language.
    public var provideType: ProvideType {
        switch self {
        case .rust: return .rustPlugin
        case .cpp: return .cppPlugin
        case .c: return .cPlugin
        case .swift: return .swiftPlugin
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
        }
    }
}
