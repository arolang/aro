// ============================================================
// AROFilePlugin.swift
// ARO Runtime - ARO File Plugin Support (ARO-0045)
// ============================================================

import Foundation
import AROParser

// MARK: - ARO File Plugin

/// Loads .aro files from plugins as additional feature sets
///
/// ARO files in plugins can provide:
/// - Additional feature sets that can be used by the application
/// - Reusable actions and patterns
/// - Templates for common operations
/// - Event handlers that respond to domain events
///
/// ## Example plugin .aro file
/// ```aro
/// (* helpers.aro — Provided by my-plugin *)
///
/// (FormatCSV: Data Processing) {
///     <Extract> the <raw-data> from the <input: data>.
///     <Parse> the <raw-data> as <CSV: format>.
///     <Return> the <formatted-output> as <CSV: string>.
/// }
/// ```
public final class AROFilePlugin: @unchecked Sendable {
    /// Plugin name
    public let pluginName: String

    /// Path to the ARO file
    public let filePath: URL

    /// Parsed program
    public let program: Program

    /// Feature sets from this file
    public let featureSets: [FeatureSet]

    /// Analyzed feature sets (with symbol tables for execution)
    public let analyzedFeatureSets: [AnalyzedFeatureSet]

    /// Initialize with an ARO file
    /// - Parameters:
    ///   - file: Path to the .aro file
    ///   - pluginName: Name of the containing plugin
    public init(file: URL, pluginName: String) throws {
        self.filePath = file
        self.pluginName = pluginName

        // Read and parse the file
        let source = try String(contentsOf: file, encoding: .utf8)
        let compiler = Compiler()
        let result = compiler.compile(source)
        guard result.isSuccess else {
            let errors = result.diagnostics.filter { $0.severity == .error }
                .map { $0.message }.joined(separator: "; ")
            throw AROFilePluginError.compilationFailed(file.lastPathComponent, message: errors)
        }
        self.program = result.program
        self.featureSets = program.featureSets

        // Perform semantic analysis on feature sets for event handler execution
        // Create a temporary Program and analyze it to get AnalyzedFeatureSets
        let analyzer = SemanticAnalyzer()
        let analyzedProgram = analyzer.analyze(program)
        self.analyzedFeatureSets = analyzedProgram.featureSets
    }

    // MARK: - Registration

    /// Register feature sets with the global registry
    public func registerFeatureSets() {
        // Feature sets from plugins are registered with a plugin prefix
        // to avoid name collisions
        for analyzedFS in analyzedFeatureSets {
            let qualifiedName = "\(pluginName):\(analyzedFS.featureSet.name)"
            PluginFeatureSetRegistry.shared.register(
                analyzedFeatureSet: analyzedFS,
                qualifiedName: qualifiedName,
                pluginName: pluginName
            )
        }
    }

    /// Get a feature set by name
    public func getFeatureSet(named name: String) -> FeatureSet? {
        featureSets.first { $0.name == name }
    }
}

// MARK: - Plugin Feature Set Registry

/// Global registry for feature sets provided by plugins
public final class PluginFeatureSetRegistry: @unchecked Sendable {
    /// Shared instance
    public static let shared = PluginFeatureSetRegistry()

    /// Registered feature sets
    private var featureSets: [String: RegisteredFeatureSet] = [:]

    /// Lock for thread safety
    private let lock = NSLock()

    private init() {}

    /// Register an analyzed feature set
    public func register(analyzedFeatureSet: AnalyzedFeatureSet, qualifiedName: String, pluginName: String) {
        lock.lock()
        defer { lock.unlock() }

        featureSets[qualifiedName] = RegisteredFeatureSet(
            analyzedFeatureSet: analyzedFeatureSet,
            qualifiedName: qualifiedName,
            pluginName: pluginName
        )

        // Also register with short name if not already taken
        let shortName = analyzedFeatureSet.featureSet.name
        if featureSets[shortName] == nil {
            featureSets[shortName] = RegisteredFeatureSet(
                analyzedFeatureSet: analyzedFeatureSet,
                qualifiedName: qualifiedName,
                pluginName: pluginName
            )
        }
    }

    /// Get a feature set by name (qualified or short)
    public func get(name: String) -> FeatureSet? {
        lock.lock()
        defer { lock.unlock() }
        return featureSets[name]?.analyzedFeatureSet.featureSet
    }

    /// Get an analyzed feature set by name (qualified or short)
    public func getAnalyzed(name: String) -> AnalyzedFeatureSet? {
        lock.lock()
        defer { lock.unlock() }
        return featureSets[name]?.analyzedFeatureSet
    }

    /// Get all registered feature sets
    public func getAll() -> [RegisteredFeatureSet] {
        lock.lock()
        defer { lock.unlock() }
        return Array(Set(featureSets.values))
    }

    /// Get feature sets from a specific plugin
    public func getFromPlugin(name: String) -> [FeatureSet] {
        lock.lock()
        defer { lock.unlock() }
        return featureSets.values
            .filter { $0.pluginName == name }
            .map { $0.analyzedFeatureSet.featureSet }
    }

    /// Clear all registered feature sets
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        featureSets.removeAll()
    }
}

// MARK: - Registered Feature Set

/// A feature set registered from a plugin
public struct RegisteredFeatureSet: Hashable, Sendable {
    /// The analyzed feature set (includes symbol table for execution)
    public let analyzedFeatureSet: AnalyzedFeatureSet

    /// Fully qualified name (plugin:name)
    public let qualifiedName: String

    /// Plugin that provided this feature set
    public let pluginName: String

    public func hash(into hasher: inout Hasher) {
        hasher.combine(qualifiedName)
    }

    public static func == (lhs: RegisteredFeatureSet, rhs: RegisteredFeatureSet) -> Bool {
        lhs.qualifiedName == rhs.qualifiedName
    }
}

// MARK: - ARO File Plugin Error

/// Errors for ARO file plugin operations
public enum AROFilePluginError: Error, CustomStringConvertible {
    case compilationFailed(String, message: String)
    case fileNotFound(String)

    public var description: String {
        switch self {
        case .compilationFailed(let file, let message):
            return "Failed to compile ARO plugin file '\(file)': \(message)"
        case .fileNotFound(let file):
            return "ARO plugin file not found: \(file)"
        }
    }
}
