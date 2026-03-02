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

    /// The plugin host that can execute this qualifier
    public let pluginHost: any PluginQualifierHost

    public init(
        qualifier: String,
        inputTypes: Set<QualifierInputType>,
        pluginName: String,
        namespace: String? = nil,
        description: String? = nil,
        pluginHost: any PluginQualifierHost
    ) {
        self.qualifier = qualifier.lowercased()
        // Use provided namespace, fall back to plugin name for backward compatibility
        self.namespace = (namespace ?? pluginName).lowercased()
        self.inputTypes = inputTypes
        self.pluginName = pluginName
        self.description = description
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

    private init() {}

    // MARK: - Registration

    /// Register a qualifier from a plugin
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

        // Register only as namespace.qualifier (e.g., "collections.reverse")
        let key = "\(registration.namespace).\(registration.qualifier)".lowercased()
        qualifiers[key] = registration
    }

    /// Register multiple qualifiers from a plugin
    ///
    /// - Parameter registrations: Array of qualifier registrations
    public func registerAll(_ registrations: [QualifierRegistration]) {
        lock.lock()
        defer { lock.unlock() }

        for registration in registrations {
            // Register only as namespace.qualifier (e.g., "collections.reverse")
            let key = "\(registration.namespace).\(registration.qualifier)".lowercased()
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

    /// Resolve a qualifier on a value
    ///
    /// If the qualifier is registered by a plugin, validates the input type
    /// and executes the qualifier via the plugin host.
    ///
    /// - Parameters:
    ///   - qualifier: The qualifier name (e.g., "pick-random")
    ///   - value: The input value to transform
    /// - Returns: The transformed value, or nil if not a plugin qualifier
    /// - Throws: QualifierError if type mismatch or execution fails
    public func resolve(_ qualifier: String, value: any Sendable) throws -> (any Sendable)? {
        lock.lock()
        let registration = qualifiers[qualifier.lowercased()]
        lock.unlock()

        // Not a plugin qualifier - return nil to fall through to built-in handling
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
        // The plugin's aro_plugin_qualifier function expects "reverse", not "collections.reverse"
        do {
            return try registration.pluginHost.executeQualifier(registration.qualifier, input: value)
        } catch let error as QualifierError {
            throw error
        } catch {
            throw QualifierError.executionFailed(
                qualifier: qualifier,
                message: error.localizedDescription
            )
        }
    }

    // MARK: - Testing Support

    /// Clear all registrations (for testing)
    public func clearAll() {
        lock.lock()
        defer { lock.unlock() }

        qualifiers.removeAll()
    }
}
