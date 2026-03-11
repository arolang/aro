// ============================================================
// UnifiedPluginLoader.swift
// ARO Runtime - Unified Plugin Loader (ARO-0045)
// ============================================================

import Foundation
import AROParser
import Yams

/// Write debug message to stderr (only when ARO_DEBUG is set)
private func debugPrint(_ message: String) {
    guard ProcessInfo.processInfo.environment["ARO_DEBUG"] != nil else { return }
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

// MARK: - Unified Plugin Loader

/// Unified plugin loader that supports dual-mode plugins
///
/// This loader scans the `Plugins/` directory for plugins that have a `plugin.yaml`
/// manifest file. It supports:
/// - ARO files (.aro) for declarative feature sets
/// - Swift plugins (existing behavior)
/// - Native plugins (C/C++, Rust) via FFI
/// - Python plugins via embedding
///
/// ## Plugin Discovery
/// ```
/// Plugins/
/// └── my-plugin/
///     ├── plugin.yaml          ← Required manifest
///     ├── features/            ← ARO feature sets
///     │   └── helpers.aro
///     └── Sources/             ← Swift plugin sources
///         └── MyPlugin.swift
/// ```
public final class UnifiedPluginLoader: @unchecked Sendable {
    /// Shared instance
    public static let shared = UnifiedPluginLoader()

    /// The legacy plugin loader for Swift plugins
    private let legacyLoader = PluginLoader.shared

    /// Loaded ARO file plugins
    private var aroPlugins: [String: AROFilePlugin] = [:]

    /// Loaded native plugins (C/Rust)
    private var nativePlugins: [String: NativePluginHost] = [:]

    /// Loaded Python plugins
    private var pythonPlugins: [String: PythonPluginHost] = [:]

    /// Plugin manifests
    private var manifests: [String: UnifiedPluginManifest] = [:]

    /// Registered handles: maps handle (lowercased) → plugin name that claimed it.
    /// Used to enforce handle uniqueness across plugins.
    private var registeredHandles: [String: String] = [:]

    /// Lock for thread safety
    private let lock = NSLock()

    private init() {}

    // MARK: - Plugin Loading

    /// Load all plugins from the Plugins/ directory
    /// - Parameter directory: Base directory containing the `Plugins/` folder
    public func loadPlugins(from directory: URL) throws {
        let pluginsDir = directory.appendingPathComponent("Plugins")

        // Check if Plugins directory exists
        guard FileManager.default.fileExists(atPath: pluginsDir.path) else {
            // Fall back to legacy plugins/ directory
            try legacyLoader.loadPlugins(from: directory)
            return
        }

        // Scan for plugins with plugin.yaml
        let contents = try FileManager.default.contentsOfDirectory(
            at: pluginsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        debugPrint("[UnifiedPluginLoader] Found \(contents.count) items in Plugins/: \(contents.map { $0.lastPathComponent })")

        for item in contents {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: item.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                continue
            }

            // Check for plugin.yaml
            let manifestPath = item.appendingPathComponent("plugin.yaml")
            if FileManager.default.fileExists(atPath: manifestPath.path) {
                do {
                    debugPrint("[UnifiedPluginLoader] Loading plugin: \(item.lastPathComponent)")
                    try loadPlugin(at: item, manifestPath: manifestPath)
                    debugPrint("[UnifiedPluginLoader] Successfully loaded plugin: \(item.lastPathComponent)")
                } catch {
                    print("[UnifiedPluginLoader] Warning: Failed to load \(item.lastPathComponent): \(error)")
                }
            } else {
                debugPrint("[UnifiedPluginLoader] Warning: \(item.lastPathComponent) missing plugin.yaml, skipping")
            }
        }

        // Also load legacy plugins from plugins/ directory
        try legacyLoader.loadPlugins(from: directory)
    }

    /// Load a single plugin
    private func loadPlugin(at pluginDir: URL, manifestPath: URL) throws {
        // Parse manifest
        let manifestYAML = try String(contentsOf: manifestPath, encoding: .utf8)
        let manifest = try parseManifest(yaml: manifestYAML)

        // Warn (don't fail) if the plugin declares an aro-version constraint that
        // isn't satisfied by the running binary. The plugin is still loaded so that
        // development and testing of newer plugins against older runtimes works.
        if let constraint = manifest.aroVersion {
            let currentVersion = currentAROVersion()
            if !semverSatisfies(version: currentVersion, constraint: constraint) {
                fputs("[Plugin] Warning: '\(manifest.name)' requires ARO \(constraint), current version is \(currentVersion). Plugin may not work correctly.\n", stderr)
            }
        }

        lock.lock()
        manifests[manifest.name] = manifest
        lock.unlock()

        // Resolve and validate the effective namespace handle
        let effectiveHandle: String?
        if let handle = resolveEffectiveHandle(manifest: manifest) {
            if registerHandle(handle, pluginName: manifest.name) {
                effectiveHandle = handle
            } else {
                effectiveHandle = nil
            }
        } else {
            effectiveHandle = nil
        }

        // Load each provided component
        for provide in manifest.provides {
            let providePath = pluginDir.appendingPathComponent(provide.path)

            switch provide.type {
            case "aro-files":
                debugPrint("[UnifiedPluginLoader] Loading ARO files from: \(providePath.path)")
                try loadAROFiles(at: providePath, pluginName: manifest.name)

            case "swift-plugin":
                // Swift plugins with @_cdecl are binary-compatible with C ABI
                // Route through NativePluginHost for unified qualifier support
                try loadNativePlugin(
                    at: providePath,
                    pluginName: manifest.name,
                    config: provide,
                    qualifierNamespace: effectiveHandle
                )

            case "rust-plugin", "c-plugin", "cpp-plugin":
                try loadNativePlugin(
                    at: providePath,
                    pluginName: manifest.name,
                    config: provide,
                    qualifierNamespace: effectiveHandle
                )

            case "python-plugin":
                try loadPythonPlugin(
                    at: providePath,
                    pluginName: manifest.name,
                    config: provide,
                    qualifierNamespace: effectiveHandle
                )

            default:
                print("[UnifiedPluginLoader] Warning: Unknown provide type '\(provide.type)'")
            }
        }
    }

    // MARK: - ARO File Loading

    /// Load ARO files as plugin feature sets
    private func loadAROFiles(at path: URL, pluginName: String) throws {
        // Find all .aro files
        let aroFiles: [URL]

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            aroFiles = try FileManager.default.contentsOfDirectory(
                at: path,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension == "aro" }
        } else if path.pathExtension == "aro" {
            aroFiles = [path]
        } else {
            aroFiles = []
        }

        debugPrint("[UnifiedPluginLoader] Found \(aroFiles.count) ARO files: \(aroFiles.map { $0.lastPathComponent })")

        for aroFile in aroFiles {
            debugPrint("[UnifiedPluginLoader] Loading ARO file: \(aroFile.lastPathComponent)")
            let aroPlugin = try AROFilePlugin(file: aroFile, pluginName: pluginName)

            lock.lock()
            aroPlugins[aroFile.lastPathComponent] = aroPlugin
            lock.unlock()

            // Register feature sets
            debugPrint("[UnifiedPluginLoader] Registering \(aroPlugin.featureSets.count) feature sets from \(aroFile.lastPathComponent)")
            aroPlugin.registerFeatureSets()
        }
    }

    // MARK: - Swift Plugin Loading

    /// Load Swift plugins using legacy loader
    private func loadSwiftPlugin(at path: URL, pluginName: String) throws {
        // Check for Package.swift (Swift package)
        let packageSwift = path.appendingPathComponent("Package.swift")
        if FileManager.default.fileExists(atPath: packageSwift.path) {
            // Load Swift package plugin
            try legacyLoader.loadPackagePlugin(from: path, name: pluginName)
        } else {
            // Find .swift files in the path
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    // Directory of Swift files - find and load them
                    let contents = try FileManager.default.contentsOfDirectory(
                        at: path,
                        includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles]
                    )
                    let swiftFiles = contents.filter { $0.pathExtension == "swift" }
                    for swiftFile in swiftFiles {
                        do {
                            try legacyLoader.loadPlugin(from: swiftFile)
                        } catch {
                            print("[UnifiedPluginLoader] Warning: Failed to load Swift plugin \(swiftFile.lastPathComponent): \(error)")
                        }
                    }
                } else if path.pathExtension == "swift" {
                    // Single Swift file
                    try legacyLoader.loadPlugin(from: path)
                }
            }
        }
    }

    // MARK: - Native Plugin Loading

    /// Load native (C/C++/Rust) plugins
    private func loadNativePlugin(
        at path: URL,
        pluginName: String,
        config: UnifiedProvideEntry,
        qualifierNamespace: String?
    ) throws {
        let host = try NativePluginHost(
            pluginPath: path,
            pluginName: pluginName,
            config: config,
            qualifierNamespace: qualifierNamespace
        )

        lock.lock()
        nativePlugins[pluginName] = host
        lock.unlock()

        // Register actions from native plugin
        host.registerActions()

        // Register as an external service for Call action support
        let wrapper = NativePluginServiceWrapper(name: pluginName, host: host)
        try ExternalServiceRegistry.shared.register(wrapper, withName: pluginName)
    }

    // MARK: - Python Plugin Loading

    /// Load Python plugins
    private func loadPythonPlugin(
        at path: URL,
        pluginName: String,
        config: UnifiedProvideEntry,
        qualifierNamespace: String?
    ) throws {
        let host = try PythonPluginHost(
            pluginPath: path,
            pluginName: pluginName,
            config: config,
            qualifierNamespace: qualifierNamespace
        )

        lock.lock()
        pythonPlugins[pluginName] = host
        lock.unlock()

        // Register actions from Python plugin
        host.registerActions()

        // Register as an external service for Call action support
        let wrapper = PythonPluginServiceWrapper(name: pluginName, host: host)
        try ExternalServiceRegistry.shared.register(wrapper, withName: pluginName)
    }

    // MARK: - Manifest Parsing

    private func parseManifest(yaml: String) throws -> UnifiedPluginManifest {
        let decoder = YAMLDecoder()
        return try decoder.decode(UnifiedPluginManifest.self, from: yaml)
    }

    // MARK: - Plugin Info

    /// Get all loaded plugins
    public func getLoadedPlugins() -> [String: UnifiedPluginManifest] {
        lock.lock()
        defer { lock.unlock() }
        return manifests
    }

    /// Get a specific plugin
    public func getPlugin(name: String) -> UnifiedPluginManifest? {
        lock.lock()
        defer { lock.unlock() }
        return manifests[name]
    }

    // MARK: - Unload

    /// Unload all plugins
    public func unloadAll() {
        lock.lock()
        aroPlugins.removeAll()
        nativePlugins.values.forEach { $0.unload() }
        nativePlugins.removeAll()
        pythonPlugins.values.forEach { $0.unload() }
        pythonPlugins.removeAll()
        manifests.removeAll()
        registeredHandles.removeAll()
        lock.unlock()

        legacyLoader.unloadAll()
    }

    // MARK: - Handle Resolution

    /// Resolve the effective namespace handle for a plugin.
    ///
    /// Priority order:
    /// 1. Root-level `handle:` from plugin.yaml (canonical, PascalCase)
    /// 2. `handler:` from the first `provides:` entry (legacy, emits deprecation warning)
    ///
    /// Returns nil only for plugins that have no native/Python actions (e.g., pure aro-files plugins).
    private func resolveEffectiveHandle(manifest: UnifiedPluginManifest) -> String? {
        // 1. Root-level handle (preferred)
        if let handle = manifest.handle {
            validateHandleFormat(handle, pluginName: manifest.name)
            return handle
        }

        // 2. Legacy: handler inside provides entries
        let legacyHandler = manifest.provides.compactMap { $0.handler }.first
        if let handler = legacyHandler {
            print("[Plugin] Warning: plugin '\(manifest.name)' uses deprecated 'handler:' inside 'provides:'. " +
                  "Move it to a root-level 'handle:' field in plugin.yaml (e.g., handle: \(toPascalCase(handler))).")
            return handler
        }

        return nil
    }

    /// Validate that a handle follows PascalCase convention.
    private func validateHandleFormat(_ handle: String, pluginName: String) {
        guard !handle.isEmpty else {
            print("[Plugin] Warning: plugin '\(pluginName)' has an empty handle.")
            return
        }
        guard handle.first?.isUppercase == true else {
            print("[Plugin] Warning: plugin '\(pluginName)' handle '\(handle)' should be PascalCase " +
                  "(e.g., '\(toPascalCase(handle))'). Handles must start with an uppercase letter.")
            return
        }
        if handle.contains("-") || handle.contains("_") {
            print("[Plugin] Warning: plugin '\(pluginName)' handle '\(handle)' should be PascalCase " +
                  "without hyphens or underscores.")
        }
    }

    /// Register a handle and check for uniqueness conflicts.
    /// - Returns: false if the handle is already claimed by another plugin.
    private func registerHandle(_ handle: String, pluginName: String) -> Bool {
        let key = handle.lowercased()
        if let existing = registeredHandles[key], existing != pluginName {
            print("[Plugin] Error: plugin '\(pluginName)' handle '\(handle)' conflicts with " +
                  "already-loaded plugin '\(existing)'. Plugin will be loaded without namespace.")
            return false
        }
        registeredHandles[key] = pluginName
        return true
    }

    /// Convert a lowercase/kebab-case string to PascalCase (for suggestions).
    private func toPascalCase(_ s: String) -> String {
        s.split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined()
    }
}

// MARK: - Version Helpers (inline; AROPackageManager not imported here)

/// Returns the running ARO version via `git describe`, or `"0.0.0"` as fallback.
private func currentAROVersion() -> String {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/sh")
    task.arguments = ["-c", "git describe --tags --always --dirty 2>/dev/null || echo '0.0.0'"]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()
    do {
        try task.run()
        task.waitUntilExit()
        if let data = try? pipe.fileHandleForReading.readToEnd(),
           let output = String(data: data, encoding: .utf8) {
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    } catch {}
    return "0.0.0"
}

/// Minimal semver constraint checker for aro-version warnings.
/// Supports `>=`, `<=`, `>`, `<`, `^`, `~`, space-separated compound constraints,
/// and exact matches. Mirrors the logic in `AROVersionChecker`.
private func semverSatisfies(version: String, constraint: String) -> Bool {
    // Non-semver versions (e.g. git SHAs from `git describe --always`) are
    // treated as development builds and always satisfy any constraint.
    func isSemver(_ v: String) -> Bool {
        let s = v.hasPrefix("v") ? String(v.dropFirst()) : v
        let base = s.components(separatedBy: CharacterSet(charactersIn: "-+"))[0]
        return base.split(separator: ".").allSatisfy { Int($0) != nil }
    }
    if !isSemver(version) { return true }

    func strip(_ v: String) -> String {
        var s = v.hasPrefix("v") ? String(v.dropFirst()) : v
        if let i = s.firstIndex(of: "-") { s = String(s[..<i]) }
        if let i = s.firstIndex(of: "+") { s = String(s[..<i]) }
        return s
    }
    func parts(_ v: String) -> [Int] {
        strip(v).split(separator: ".").prefix(3).compactMap { Int($0) }
    }
    func cmp(_ a: String, _ b: String) -> Int {
        let pa = parts(a), pb = parts(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x - y }
        }
        return 0
    }
    func satisfiesClause(_ v: String, _ clause: String) -> Bool {
        let clean = strip(v)
        if clause.hasPrefix(">=") { return cmp(clean, String(clause.dropFirst(2))) >= 0 }
        if clause.hasPrefix("<=") { return cmp(clean, String(clause.dropFirst(2))) <= 0 }
        if clause.hasPrefix(">")  { return cmp(clean, String(clause.dropFirst(1))) > 0 }
        if clause.hasPrefix("<")  { return cmp(clean, String(clause.dropFirst(1))) < 0 }
        if clause.hasPrefix("^") {
            let req = parts(String(clause.dropFirst()))
            let ins = parts(clean)
            guard !ins.isEmpty, !req.isEmpty else { return false }
            return ins[0] == req[0] && cmp(clean, String(clause.dropFirst())) >= 0
        }
        if clause.hasPrefix("~") {
            let req = parts(String(clause.dropFirst()))
            let ins = parts(clean)
            guard ins.count >= 2, req.count >= 2 else { return false }
            return ins[0] == req[0] && ins[1] == req[1] && cmp(clean, String(clause.dropFirst())) >= 0
        }
        let norm = clause.hasPrefix("v") ? String(clause.dropFirst()) : clause
        return clean == norm
    }
    let clauses = constraint.split(separator: " ").map { String($0).trimmingCharacters(in: .whitespaces) }
    return clauses.allSatisfy { satisfiesClause(version, $0) }
}

// MARK: - Unified Plugin Manifest (Simplified)

/// Simplified manifest for internal use
public struct UnifiedPluginManifest: Codable, Sendable {
    let name: String
    let version: String
    let description: String?
    let author: String?
    let license: String?
    let aroVersion: String?
    let source: UnifiedSourceInfo?
    let provides: [UnifiedProvideEntry]
    let dependencies: [String: UnifiedDependencySpec]?

    /// Root-level namespace handle (PascalCase, e.g. `Markdown`, `Hash`, `Collections`).
    ///
    /// This is the canonical way to declare a plugin namespace. When set, all plugin-provided
    /// actions and qualifiers are accessed with this prefix in ARO code:
    /// - Actions:    `Markdown.ToHTML the <result> from the <input>.`
    /// - Qualifiers: `Compute the <item: Collections.pick-random> from the <list>.`
    ///
    /// Takes priority over the legacy `handler:` field inside `provides:` entries.
    let handle: String?

    enum CodingKeys: String, CodingKey {
        case name, version, description, author, license, handle
        case aroVersion = "aro-version"
        case source, provides, dependencies
    }
}

public struct UnifiedSourceInfo: Codable, Sendable {
    let git: String?
    let ref: String?
    let commit: String?
}

public struct UnifiedProvideEntry: Codable, Sendable {
    let type: String
    let path: String
    /// The qualifier namespace (handler) for this plugin component.
    ///
    /// When set, qualifiers from this plugin are accessed as `handler.qualifier`
    /// in ARO code (e.g., `<list: collections.reverse>` where `handler: collections`).
    /// Falls back to the plugin name if not specified.
    let handler: String?
    let build: UnifiedBuildConfig?
    let python: UnifiedPythonConfig?
}

public struct UnifiedBuildConfig: Codable, Sendable {
    let cargoTarget: String?
    let compiler: String?
    let flags: [String]?
    let output: String?

    enum CodingKeys: String, CodingKey {
        case cargoTarget = "cargo-target"
        case compiler, flags, output
    }
}

public struct UnifiedPythonConfig: Codable, Sendable {
    let minVersion: String?
    let requirements: String?

    enum CodingKeys: String, CodingKey {
        case minVersion = "min-version"
        case requirements
    }
}

public struct UnifiedDependencySpec: Codable, Sendable {
    let git: String
    let ref: String?
}

// MARK: - Native Plugin Service Wrapper

/// Wraps a native (C/C++/Rust) plugin as an AROService for Call action support
struct NativePluginServiceWrapper: AROService {
    static let name: String = "_native_plugin_"

    private let serviceName: String
    private let host: NativePluginHost

    init(name: String, host: NativePluginHost) {
        self.serviceName = name
        self.host = host
    }

    init() throws {
        fatalError("NativePluginServiceWrapper requires name and host")
    }

    func call(_ method: String, args: [String: any Sendable]) async throws -> any Sendable {
        return try host.execute(action: method, input: args)
    }
}

// MARK: - Python Plugin Service Wrapper

/// Wraps a Python plugin as an AROService for Call action support
struct PythonPluginServiceWrapper: AROService {
    static let name: String = "_python_plugin_"

    private let serviceName: String
    private let host: PythonPluginHost

    init(name: String, host: PythonPluginHost) {
        self.serviceName = name
        self.host = host
    }

    init() throws {
        fatalError("PythonPluginServiceWrapper requires name and host")
    }

    func call(_ method: String, args: [String: any Sendable]) async throws -> any Sendable {
        return try host.execute(action: method, input: args)
    }
}
