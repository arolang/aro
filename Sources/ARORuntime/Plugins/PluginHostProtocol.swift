// ============================================================
// PluginHostProtocol.swift
// ARO Runtime - Shared Plugin Host Abstraction (ARO-0045)
// ============================================================
//
// Extracts duplicated logic from NativePluginHost, PythonPluginHost,
// and PluginLoader into a single protocol with default implementations.
//
// Each host only needs to implement language-specific loading and
// invocation; shared JSON parsing, registry operations, and qualifier
// result decoding live here.

import Foundation

// MARK: - Shared Qualifier Descriptor

/// Unified qualifier descriptor used by all plugin types.
///
/// Replaces the per-host `NativeQualifierDescriptor` and `PythonQualifierDescriptor`.
public struct PluginQualifierDescriptor: Sendable {
    public let name: String
    public let inputTypes: Set<QualifierInputType>
    public let description: String?
    public let acceptsParameters: Bool

    public init(
        name: String,
        inputTypes: Set<QualifierInputType>,
        description: String? = nil,
        acceptsParameters: Bool = false
    ) {
        self.name = name
        self.inputTypes = inputTypes
        self.description = description
        self.acceptsParameters = acceptsParameters
    }
}

// MARK: - Plugin Host Protocol

/// Protocol for plugin hosts that share registration, unload, and parsing logic.
///
/// Extends `PluginQualifierHost` (which requires `pluginName` and `executeQualifier`).
/// Default implementations cover the operations that were duplicated across
/// `NativePluginHost`, `PythonPluginHost`, and `PluginLoader`.
public protocol PluginHostProtocol: AnyObject, PluginQualifierHost {
    /// Qualifier namespace (handler name from plugin.yaml).
    /// Used as the prefix when registering qualifiers and actions.
    var qualifierNamespace: String? { get }

    /// Mutable storage for qualifier registrations owned by this host.
    var qualifierRegistrations: [QualifierRegistration] { get set }
}

// MARK: - Shared Parsing Utilities

/// Shared parsing utilities for plugin info JSON.
///
/// These are standalone so they can be used by any code that parses
/// plugin info, including `PluginLoader` which doesn't conform to
/// `PluginHostProtocol`.
public enum PluginInfoParser {

    /// Parse qualifier descriptors from plugin info JSON dictionary.
    ///
    /// Handles the standard `"qualifiers"` array format returned by
    /// `aro_plugin_info()` across all plugin languages.
    ///
    /// ```json
    /// { "qualifiers": [
    ///     { "name": "reverse", "inputTypes": ["List"], "description": "...", "accepts_parameters": true }
    /// ]}
    /// ```
    public static func parseQualifierDescriptors(from dict: [String: Any]) -> [PluginQualifierDescriptor] {
        guard let qualifierObjects = dict["qualifiers"] as? [[String: Any]] else {
            return []
        }

        return qualifierObjects.compactMap { obj in
            guard let name = obj["name"] as? String else { return nil }

            var inputTypes: Set<QualifierInputType> = []
            if let typeStrings = obj["inputTypes"] as? [String] {
                for typeStr in typeStrings {
                    if let inputType = QualifierInputType(rawValue: typeStr) {
                        inputTypes.insert(inputType)
                    }
                }
            }
            if inputTypes.isEmpty {
                inputTypes = Set(QualifierInputType.allCases)
            }

            return PluginQualifierDescriptor(
                name: name,
                inputTypes: inputTypes,
                description: obj["description"] as? String,
                acceptsParameters: obj["accepts_parameters"] as? Bool ?? false
            )
        }
    }

    /// Parse actions from plugin info JSON dictionary.
    ///
    /// Supports both legacy flat format and structured SDK format:
    /// - Flat: `"actions": ["greet", "farewell"]`
    /// - Structured: `"actions": [{ "name": "Greet", "verbs": ["greet", "hello"] }]`
    ///
    /// - Returns: Tuple of (action names, verbs map from name → verbs)
    public static func parseActionList(from dict: [String: Any]) -> (names: [String], verbsMap: [String: [String]]) {
        var actionNames: [String] = []
        var verbsMap: [String: [String]] = [:]

        if let flatActions = dict["actions"] as? [String] {
            actionNames = flatActions
        } else if let structuredActions = dict["actions"] as? [[String: Any]] {
            for actionObj in structuredActions {
                if let actionName = actionObj["name"] as? String {
                    actionNames.append(actionName)
                    if let verbs = actionObj["verbs"] as? [String] {
                        verbsMap[actionName] = verbs
                    }
                }
            }
        }

        return (names: actionNames, verbsMap: verbsMap)
    }

    /// Register action verbs with the global `ActionRegistry` using
    /// synchronised dispatch (semaphore pattern).
    ///
    /// Usable by any code that needs synchronous action registration,
    /// including `PluginLoader`.
    public static func syncRegisterActions(
        _ entries: [(verb: String, pluginName: String?, handler: @Sendable (ResultDescriptor, ObjectDescriptor, any ExecutionContext) async throws -> any Sendable)]
    ) {
        guard !entries.isEmpty else { return }

        let semaphore = DispatchSemaphore(value: 0)
        var count = 0

        for entry in entries {
            count += 1
            Task {
                await ActionRegistry.shared.registerDynamic(
                    verb: entry.verb,
                    handler: entry.handler,
                    pluginName: entry.pluginName
                )
                semaphore.signal()
            }
        }

        for _ in 0..<count {
            semaphore.wait()
        }
    }

    /// Decode a `QualifierOutput` from raw JSON data, returning the result
    /// value or throwing `QualifierError`.
    ///
    /// This is the shared post-processing logic after a qualifier call returns
    /// JSON, regardless of how the plugin was invoked (C ABI, subprocess, etc.).
    public static func decodeQualifierResult(
        from data: Data,
        qualifier: String,
        decoder: JSONDecoder
    ) throws -> any Sendable {
        let output = try decoder.decode(QualifierOutput.self, from: data)

        if let error = output.error {
            throw QualifierError.executionFailed(qualifier: qualifier, message: error)
        }

        guard let result = output.result else {
            throw QualifierError.executionFailed(
                qualifier: qualifier,
                message: "Plugin returned neither result nor error"
            )
        }

        return result.value
    }
}

// MARK: - Default Implementations

extension PluginHostProtocol {

    // MARK: JSON Parsing (forwarded to PluginInfoParser)

    /// Parse qualifier descriptors from plugin info JSON dictionary.
    public static func parseQualifierDescriptors(from dict: [String: Any]) -> [PluginQualifierDescriptor] {
        PluginInfoParser.parseQualifierDescriptors(from: dict)
    }

    /// Parse actions from plugin info JSON dictionary.
    public static func parseActionList(from dict: [String: Any]) -> (names: [String], verbsMap: [String: [String]]) {
        PluginInfoParser.parseActionList(from: dict)
    }

    // MARK: Qualifier Registration

    /// Register qualifier descriptors with the global `QualifierRegistry`.
    ///
    /// Appends registrations to `qualifierRegistrations` and registers each
    /// with `QualifierRegistry.shared`.
    public func registerQualifiers(_ descriptors: [PluginQualifierDescriptor]) {
        for descriptor in descriptors {
            let registration = QualifierRegistration(
                qualifier: descriptor.name,
                inputTypes: descriptor.inputTypes,
                pluginName: pluginName,
                namespace: qualifierNamespace,
                description: descriptor.description,
                acceptsParameters: descriptor.acceptsParameters,
                pluginHost: self
            )
            qualifierRegistrations.append(registration)
            QualifierRegistry.shared.register(registration)
        }
    }

    // MARK: Action Registration

    /// Register action verbs with the global `ActionRegistry` using
    /// synchronised dispatch (semaphore pattern).
    public func syncRegisterActions(
        _ entries: [(verb: String, pluginName: String, handler: @Sendable (ResultDescriptor, ObjectDescriptor, any ExecutionContext) async throws -> any Sendable)]
    ) {
        PluginInfoParser.syncRegisterActions(entries.map { ($0.verb, $0.pluginName, $0.handler) })
    }

    // MARK: Unload

    /// Unregister this plugin from `ActionRegistry` and `QualifierRegistry`,
    /// then clear local qualifier registrations.
    public func unloadFromRegistries() {
        let semaphore = DispatchSemaphore(value: 0)
        let name = pluginName
        Task {
            await ActionRegistry.shared.unregisterPlugin(name)
            semaphore.signal()
        }
        semaphore.wait()

        QualifierRegistry.shared.unregisterPlugin(pluginName)
        qualifierRegistrations.removeAll()
    }

    // MARK: Qualifier Result Decoding

    /// Decode a `QualifierOutput` from raw JSON data.
    public func decodeQualifierResult(
        from data: Data,
        qualifier: String,
        decoder: JSONDecoder
    ) throws -> any Sendable {
        try PluginInfoParser.decodeQualifierResult(from: data, qualifier: qualifier, decoder: decoder)
    }
}
