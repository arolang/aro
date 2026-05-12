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
    /// - Structured: `"actions": [{ "name": "Greet", "verbs": ["greet", "hello"], "role": "own", "prepositions": ["from"], "description": "...", "since": "1.0.0" }]`
    ///
    /// - Returns: Tuple of (action names, verbs map from name → verbs)
    public static func parseActionList(from dict: [String: Any]) -> (names: [String], verbsMap: [String: [String]]) {
        let parsed = parseActionListWithMetadata(from: dict)
        return (names: parsed.names, verbsMap: parsed.verbsMap)
    }

    /// Like `parseActionList` but also extracts the metadata (role, prepositions,
    /// description, since) declared per-action in the structured format. The
    /// returned `metadataMap` is keyed by action name; flat-format actions get
    /// no entries (callers should fall back to `.own` / no description).
    public static func parseActionListWithMetadata(from dict: [String: Any]) -> (
        names: [String],
        verbsMap: [String: [String]],
        metadataMap: [String: ActionRegistry.PluginActionMetadata]
    ) {
        var actionNames: [String] = []
        var verbsMap: [String: [String]] = [:]
        var metadataMap: [String: ActionRegistry.PluginActionMetadata] = [:]

        if let flatActions = dict["actions"] as? [String] {
            actionNames = flatActions
        } else if let structuredActions = dict["actions"] as? [[String: Any]] {
            for actionObj in structuredActions {
                guard let actionName = actionObj["name"] as? String else { continue }
                actionNames.append(actionName)
                if let verbs = actionObj["verbs"] as? [String] {
                    verbsMap[actionName] = verbs
                }

                let roleString = (actionObj["role"] as? String)?.lowercased() ?? "own"
                let role = ActionRole(rawValue: roleString) ?? .own
                let prepositions = actionObj["prepositions"] as? [String] ?? []
                let description = actionObj["description"] as? String
                let since = actionObj["since"] as? String

                metadataMap[actionName] = ActionRegistry.PluginActionMetadata(
                    role: role,
                    prepositions: prepositions,
                    description: description,
                    handle: nil, // host fills this in from qualifierNamespace
                    since: since
                )
            }
        }

        return (names: actionNames, verbsMap: verbsMap, metadataMap: metadataMap)
    }

    /// Register action verbs with the global `ActionRegistry`.
    ///
    /// `ActionRegistry` is now a lock-protected `final class`, so registration is a
    /// straight sync call — no `Task { await … }; semaphore.wait()` bridge required.
    /// (The previous bridge starved the cooperative thread pool under
    /// `swift test --parallel`.)
    public static func syncRegisterActions(
        _ entries: [(verb: String, pluginName: String?, handler: @Sendable (ResultDescriptor, ObjectDescriptor, any ExecutionContext) async throws -> any Sendable)]
    ) {
        syncRegisterActionsWithMetadata(entries.map { (verb: $0.verb, pluginName: $0.pluginName, metadata: nil, handler: $0.handler) })
    }

    /// Metadata-aware variant of `syncRegisterActions`. Use this when the host
    /// has parsed `aro_plugin_info()` and can supply role/prepositions so the
    /// catalog (and LSP/MCP layers reading it) gets a proper hover card.
    public static func syncRegisterActionsWithMetadata(
        _ entries: [(
            verb: String,
            pluginName: String?,
            metadata: ActionRegistry.PluginActionMetadata?,
            handler: @Sendable (ResultDescriptor, ObjectDescriptor, any ExecutionContext) async throws -> any Sendable
        )]
    ) {
        for entry in entries {
            ActionRegistry.shared.registerDynamic(
                verb: entry.verb,
                handler: entry.handler,
                pluginName: entry.pluginName,
                metadata: entry.metadata
            )
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

    /// Metadata-aware variant for hosts that know per-action metadata.
    public func syncRegisterActionsWithMetadata(
        _ entries: [(
            verb: String,
            pluginName: String,
            metadata: ActionRegistry.PluginActionMetadata?,
            handler: @Sendable (ResultDescriptor, ObjectDescriptor, any ExecutionContext) async throws -> any Sendable
        )]
    ) {
        PluginInfoParser.syncRegisterActionsWithMetadata(entries.map {
            (verb: $0.verb, pluginName: $0.pluginName, metadata: $0.metadata, handler: $0.handler)
        })
    }

    // MARK: Unload

    /// Unregister this plugin from `ActionRegistry` and `QualifierRegistry`,
    /// then clear local qualifier registrations.
    public func unloadFromRegistries() {
        ActionRegistry.shared.unregisterPlugin(pluginName)
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
