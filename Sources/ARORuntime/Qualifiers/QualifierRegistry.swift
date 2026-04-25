//
// QualifierRegistry.swift
// ARO Runtime - Plugin Qualifier Registration
//
// Manages qualifiers provided by plugins for type transformations.
// Example: <my-list: pick-random> where pick-random is from a plugin.
//

import Foundation

// MARK: - Qualifier Input Types

/// Types that plugin qualifiers can accept as input
public enum QualifierInputType: String, Sendable, CaseIterable, Hashable {
    case string = "String"
    case int = "Int"
    case double = "Double"
    case bool = "Bool"
    case list = "List"
    case object = "Object"

    /// Detect the type of a runtime value
    public static func detect(from value: any Sendable) -> QualifierInputType {
        switch value {
        case is String:
            return .string
        case is Int:
            return .int
        case is Double:
            return .double
        case is Bool:
            return .bool
        case is [any Sendable]:
            return .list
        case is [String: any Sendable]:
            return .object
        default:
            // Fallback to object for unknown types
            return .object
        }
    }
}

// MARK: - Qualifier Errors

/// Errors that can occur during qualifier resolution
public enum QualifierError: Error, CustomStringConvertible {
    /// Type mismatch: qualifier doesn't accept this input type
    case typeMismatch(qualifier: String, expected: Set<QualifierInputType>, actual: QualifierInputType)

    /// Qualifier execution failed with an error message
    case executionFailed(qualifier: String, message: String)

    /// Plugin that provides the qualifier is not loaded
    case pluginNotLoaded(plugin: String)

    public var description: String {
        switch self {
        case .typeMismatch(let qualifier, let expected, let actual):
            let expectedStr = expected.map { $0.rawValue }.sorted().joined(separator: ", ")
            return "Qualifier '\(qualifier)' expects [\(expectedStr)] but received \(actual.rawValue)"
        case .executionFailed(let qualifier, let message):
            return "Qualifier '\(qualifier)' failed: \(message)"
        case .pluginNotLoaded(let plugin):
            return "Plugin '\(plugin)' providing qualifier is not loaded"
        }
    }
}

// MARK: - Qualifier Registration

/// Registration entry for a plugin-provided qualifier
public struct QualifierRegistration: Sendable {
    /// The plain qualifier name (e.g., "pick-random", "shuffle")
    public let qualifier: String

    /// The handler namespace used to access this qualifier (e.g., "collections")
    ///
    /// Qualifiers are accessed as `handler.qualifier` in ARO code:
    /// `<list: collections.reverse>` where "collections" is the handler.
    /// Set via the `handler:` field in the `provides:` entry of `plugin.yaml`.
    public let namespace: String

    /// Accepted input types for this qualifier
    public let inputTypes: Set<QualifierInputType>

    /// Name of the plugin providing this qualifier (used for unregistration)
    public let pluginName: String

    /// Description of what the qualifier does (optional)
    public let description: String?

    /// Whether this qualifier accepts parameters via the `with` clause (ARO-0073)
    public let acceptsParameters: Bool

    /// The plugin host that can execute this qualifier
    public let pluginHost: any PluginQualifierHost

    public init(
        qualifier: String,
        inputTypes: Set<QualifierInputType>,
        pluginName: String,
        namespace: String? = nil,
        description: String? = nil,
        acceptsParameters: Bool = false,
        pluginHost: any PluginQualifierHost
    ) {
        self.qualifier = qualifier.lowercased()
        // Use provided namespace, fall back to plugin name for backward compatibility
        self.namespace = (namespace ?? pluginName).lowercased()
        self.inputTypes = inputTypes
        self.pluginName = pluginName
        self.description = description
        self.acceptsParameters = acceptsParameters
        self.pluginHost = pluginHost
    }
}

// MARK: - Qualifier Registry

/// Central registry for plugin-provided qualifiers
///
/// Plugins register qualifiers during loading. When ARO encounters a qualifier
/// like `<list: pick-random>`, the runtime checks this registry to see if
/// a plugin provides that qualifier.
public final class QualifierRegistry: @unchecked Sendable {
    /// Shared singleton instance
    public static let shared = QualifierRegistry()

    /// Registered qualifiers: name -> registration
    private var qualifiers: [String: QualifierRegistration] = [:]

    /// Thread safety lock
    private let lock = NSLock()

    private init() {
        registerBuiltIns()
    }

    // MARK: - Built-in Qualifier Registration (ARO-0073)

    /// Register built-in qualifiers so the registry is the single source of truth
    ///
    /// Built-in qualifiers are still executed inline by ComputeAction (they need
    /// execution context), but they are registered here for discovery/listing.
    private func registerBuiltIns() {
        let host = BuiltInQualifierHost()
        let builtIns: [(String, Set<QualifierInputType>, Bool, String?)] = [
            ("hash", Set(QualifierInputType.allCases), false, "Compute SHA-256 hash"),
            ("length", [.string, .list, .object], false, "Count elements or characters"),
            ("count", [.string, .list, .object], false, "Count elements or characters"),
            ("uppercase", [.string], false, "Convert to UPPERCASE"),
            ("lowercase", [.string], false, "Convert to lowercase"),
            ("identity", Set(QualifierInputType.allCases), false, "Pass-through (no-op)"),
            ("clip", [.string], true, "Truncate string to width"),
            ("take", [.string, .list], true, "First N elements"),
            ("date", [.string], false, "Parse ISO 8601 string to date"),
            ("format", [.string], true, "Format date with pattern"),
            ("distance", [.string], true, "Date distance between two dates"),
            ("intersect", [.list, .object], true, "Set intersection"),
            ("difference", [.list, .object], true, "Set difference"),
            ("union", [.list, .object], true, "Set union"),
        ]

        for (name, types, acceptsParams, description) in builtIns {
            let reg = QualifierRegistration(
                qualifier: name,
                inputTypes: types,
                pluginName: "_builtin",
                namespace: "_builtin",
                description: description,
                acceptsParameters: acceptsParams,
                pluginHost: host
            )
            // Register only under _builtin.name -- the actual execution still happens
            // inline in ComputeAction. This registration is for discovery/listing only.
            qualifiers["\(reg.namespace).\(reg.qualifier)"] = reg
        }
    }

    // MARK: - Registration

    /// Register a qualifier from a plugin (ARO-0073: with conflict detection)
    ///
    /// Qualifiers are registered exclusively under the namespaced form
    /// `handler.qualifier` (e.g., "collections.reverse"). This prevents
    /// name collisions between plugins and requires ARO code to use
    /// the explicit `<value: handler.qualifier>` syntax.
    ///
    /// - Parameter registration: The qualifier registration
    public func register(_ registration: QualifierRegistration) {
        lock.lock()
        defer { lock.unlock() }

        let key = "\(registration.namespace).\(registration.qualifier)".lowercased()

        // Conflict detection: warn if overwriting a qualifier from a different plugin
        if let existing = qualifiers[key], existing.pluginName != registration.pluginName {
            debugPrint("[QualifierRegistry] ⚠ Conflict: qualifier '\(key)' from '\(registration.pluginName)' overwrites '\(existing.pluginName)'. Use plugin handle aliasing to resolve.")
        }

        qualifiers[key] = registration
    }

    /// Register multiple qualifiers from a plugin
    ///
    /// - Parameter registrations: Array of qualifier registrations
    public func registerAll(_ registrations: [QualifierRegistration]) {
        lock.lock()
        defer { lock.unlock() }

        for registration in registrations {
            let key = "\(registration.namespace).\(registration.qualifier)".lowercased()

            if let existing = qualifiers[key], existing.pluginName != registration.pluginName {
                debugPrint("[QualifierRegistry] ⚠ Conflict: qualifier '\(key)' from '\(registration.pluginName)' overwrites '\(existing.pluginName)'")
            }

            qualifiers[key] = registration
        }
    }

    /// Unregister all qualifiers from a specific plugin
    ///
    /// - Parameter pluginName: Name of the plugin
    public func unregisterPlugin(_ pluginName: String) {
        lock.lock()
        defer { lock.unlock() }

        qualifiers = qualifiers.filter { $0.value.pluginName != pluginName }
    }

    // MARK: - Lookup

    /// Check if a qualifier is registered
    ///
    /// - Parameter qualifier: The qualifier name
    /// - Returns: True if the qualifier is registered
    public func isRegistered(_ qualifier: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        return qualifiers[qualifier.lowercased()] != nil
    }

    /// Get registration info for a qualifier
    ///
    /// - Parameter qualifier: The qualifier name
    /// - Returns: The registration if found
    public func registration(for qualifier: String) -> QualifierRegistration? {
        lock.lock()
        defer { lock.unlock() }

        return qualifiers[qualifier.lowercased()]
    }

    /// Get all registered qualifiers
    ///
    /// - Returns: Array of all registrations
    public func allRegistrations() -> [QualifierRegistration] {
        lock.lock()
        defer { lock.unlock() }

        return Array(qualifiers.values)
    }

    // MARK: - Resolution

    /// Resolve a qualifier on a value (ARO-0073: with optional parameters)
    ///
    /// If the qualifier is registered by a plugin, validates the input type
    /// and executes the qualifier via the plugin host.
    ///
    /// - Parameters:
    ///   - qualifier: The qualifier name (e.g., "collections.reverse")
    ///   - value: The input value to transform
    ///   - withParams: Optional parameters from the `with` clause
    /// - Returns: The transformed value, or nil if not a registered qualifier
    /// - Throws: QualifierError if type mismatch or execution fails
    public func resolve(_ qualifier: String, value: any Sendable, withParams: [String: any Sendable]? = nil) throws -> (any Sendable)? {
        lock.lock()
        let registration = qualifiers[qualifier.lowercased()]
        lock.unlock()

        // Not a registered qualifier - return nil to fall through
        guard let registration = registration else {
            return nil
        }

        // Validate input type
        let actualType = QualifierInputType.detect(from: value)
        guard registration.inputTypes.contains(actualType) else {
            throw QualifierError.typeMismatch(
                qualifier: qualifier,
                expected: registration.inputTypes,
                actual: actualType
            )
        }

        // Execute via plugin host using the plain qualifier name (not the namespaced key)
        do {
            return try registration.pluginHost.executeQualifier(
                registration.qualifier,
                input: value,
                withParams: withParams
            )
        } catch let error as QualifierError {
            throw error
        } catch {
            throw QualifierError.executionFailed(
                qualifier: qualifier,
                message: error.localizedDescription
            )
        }
    }

    /// Resolve a chain of qualifiers on a value (ARO-0073: qualifier chaining)
    ///
    /// Applies qualifiers left-to-right. Each qualifier's output becomes
    /// the next qualifier's input.
    ///
    /// - Parameters:
    ///   - qualifiers: Ordered list of qualifier names to apply
    ///   - value: The initial input value
    ///   - withParams: Optional parameters from the `with` clause (shared across chain)
    /// - Returns: The final transformed value, or nil if the first qualifier is not registered
    /// - Throws: QualifierError if any qualifier in the chain fails
    public func resolveChain(_ qualifierNames: [String], value: any Sendable, withParams: [String: any Sendable]? = nil) throws -> (any Sendable)? {
        guard !qualifierNames.isEmpty else { return nil }

        var current: any Sendable = value
        for (index, qualifierName) in qualifierNames.enumerated() {
            guard let result = try resolve(qualifierName, value: current, withParams: withParams) else {
                // First qualifier not found -> return nil (not a plugin qualifier chain)
                if index == 0 { return nil }
                // Later qualifier not found -> error
                throw QualifierError.executionFailed(
                    qualifier: qualifierName,
                    message: "Qualifier '\(qualifierName)' not found in chain"
                )
            }
            current = result
        }
        return current
    }

    // MARK: - Testing Support

    /// Clear all registrations and re-register built-ins (for testing)
    public func clearAll() {
        lock.lock()
        defer { lock.unlock() }

        qualifiers.removeAll()
    }
}

// MARK: - Built-in Qualifier Host (ARO-0073)

/// Stub host for built-in qualifiers registered in QualifierRegistry
///
/// Built-in qualifiers are still executed inline by ComputeAction (they need
/// execution context for `_with_`, `_to_`, DateService, etc.). This host exists
/// so the registry can serve as the single source of truth for listing all
/// available qualifiers. If called, it returns the input unchanged.
final class BuiltInQualifierHost: PluginQualifierHost, @unchecked Sendable {
    let pluginName: String = "_builtin"

    func executeQualifier(_ qualifier: String, input: any Sendable, withParams: [String: any Sendable]? = nil) throws -> any Sendable {
        // Built-in qualifiers are executed by ComputeAction, not through this host.
        // This is a fallback that returns input unchanged.
        return input
    }
}
