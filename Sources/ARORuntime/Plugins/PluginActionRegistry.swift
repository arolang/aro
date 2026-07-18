// ============================================================
// PluginActionRegistry.swift
// ARO Runtime - Shared Plugin Action Registry (#324)
// ============================================================
//
// Single value type shared by every plugin host (Native/Rust/C/Swift via
// NativePluginHost, and Python via PythonPluginHost) to track the actions,
// verb→action mapping, per-action metadata, and qualifier registrations a
// plugin advertises through `aro_plugin_info()`.
//
// Before this type each host maintained its own bespoke collections:
//   - PythonPluginHost: `actions` (Set), `verbToActionName` (dict),
//     `actionMetadataByName` (dict), `qualifierRegistrations` (array)
//   - NativePluginHost:  `actions` (dict), `actionVerbs` (dict),
//     `qualifierRegistrations` (array)
// Each host then had to keep those in sync by hand — a class of bug that
// only had to be fixed once per host. Consolidating the storage here means
// every host populates and reads the SAME structure.

import Foundation

/// Shared, in-host storage for the actions, verb mappings, metadata, and
/// qualifier registrations declared by a single plugin.
///
/// This is a value type. Hosts hold it as a mutable property and drive it
/// through the `register*` methods; because the hosts are `@unchecked
/// Sendable` and serialise their own access, no additional locking is needed
/// here (the struct simply moves the invariant into one place).
///
/// ## Two population shapes
///
/// Hosts differ in how `aro_plugin_info()` exposes verbs, and the registry
/// supports both without either host reaching into the other's convention:
///
/// - **NativePluginHost** keeps a canonical action *name* keyed dictionary of
///   descriptors plus a name→verbs map. It calls ``registerAction(name:verbs:metadata:)``.
/// - **PythonPluginHost** flattens verbs into a set and maps each verb back to
///   its canonical name. It calls ``registerFlattenedVerbs(name:verbs:metadata:)``.
///
/// Both converge on the same stored fields (`verbToActionName`,
/// `metadataByName`), so lookups (``canonicalName(forVerb:)``,
/// ``metadata(forName:)``) behave identically regardless of which host filled
/// the registry.
public struct PluginActionRegistry: Sendable {

    // MARK: - Stored State

    /// Canonical action names in declaration order (deduplicated).
    ///
    /// For Native hosts these are the `name:` values from the manifest
    /// (e.g. `ParseCSV`). For Python hosts, where the manifest is flattened to
    /// a verb list, these are the flattened verbs themselves — preserving the
    /// exact contents the pre-refactor `actions` set held.
    public private(set) var actionNames: [String] = []

    /// The set of dispatchable verbs this plugin exposes.
    ///
    /// - Native: every verb in every action's `verbs:` list (falling back to
    ///   the action name when no verbs are declared).
    /// - Python: the flattened verb set (each verb also mapped back to its
    ///   canonical action name via `verbToActionName`).
    public private(set) var verbs: Set<String> = []

    /// Maps a dispatch verb to its canonical action name.
    ///
    /// Used when the runtime hands a host a verb and the host must recover the
    /// action name (e.g. to look up metadata, or to derive the Python function
    /// name / Rust snake_case fallback).
    public private(set) var verbToActionName: [String: String] = [:]

    /// Maps a canonical action name to the verbs it dispatches (Native).
    ///
    /// Empty for hosts that only track a flattened verb set (Python). Native
    /// uses this both for `registerActions()` (register every verb) and for the
    /// snake_case dispatch fallback in `execute`.
    public private(set) var verbsByName: [String: [String]] = [:]

    /// Per-action metadata parsed from `aro_plugin_info()`, keyed by canonical
    /// action name. Surfaced to `ActionRegistry` for catalog hover/completion.
    public private(set) var metadataByName: [String: ActionRegistry.PluginActionMetadata] = [:]

    /// Qualifier registrations owned by this plugin. Mirrors what is registered
    /// with the global `QualifierRegistry`, so `unload` can drop them.
    public var qualifierRegistrations: [QualifierRegistration] = []

    public init() {}

    // MARK: - Action Registration

    /// Register a canonical action with its declared verbs (Native/Rust/C/Swift shape).
    ///
    /// Populates `actionNames`, `verbsByName`, `verbs`, `verbToActionName`, and
    /// `metadataByName` in one place. If `verbs` is empty the action name itself
    /// is used as the sole verb (matching the historical fallback).
    ///
    /// - Parameters:
    ///   - name: The canonical action name (manifest `name:`).
    ///   - verbs: The verbs that dispatch to this action. Empty ⇒ `[name]`.
    ///   - metadata: Optional metadata (role/prepositions/description/since).
    public mutating func registerAction(
        name: String,
        verbs actionVerbs: [String],
        metadata: ActionRegistry.PluginActionMetadata? = nil
    ) {
        let effectiveVerbs = actionVerbs.isEmpty ? [name] : actionVerbs

        if !actionNames.contains(name) {
            actionNames.append(name)
        }
        verbsByName[name] = effectiveVerbs
        for verb in effectiveVerbs {
            verbs.insert(verb)
            verbToActionName[verb] = name
        }
        if let metadata {
            metadataByName[name] = metadata
        }
    }

    /// Register a canonical action as a flattened verb list (Python shape).
    ///
    /// Python's `aro_plugin_info()` is consumed as a flat verb set with a
    /// reverse map back to the canonical name. When `verbs` is non-empty each
    /// verb is added to the dispatch set, appended to `actionNames`, and mapped
    /// to `name`; when empty the `name` itself is treated as its own verb.
    /// `metadata` is keyed by canonical name.
    ///
    /// This differs from ``registerAction(name:verbs:metadata:)`` in that it does
    /// NOT populate `verbsByName` (Python never needs the name→verbs map) and it
    /// appends the verbs — not the name — to `actionNames`, matching the
    /// pre-refactor `actions` set contents that `registerActions()` iterated.
    public mutating func registerFlattenedVerbs(
        name: String,
        verbs actionVerbs: [String],
        metadata: ActionRegistry.PluginActionMetadata? = nil
    ) {
        if let metadata {
            metadataByName[name] = metadata
        }

        if actionVerbs.isEmpty {
            if !actionNames.contains(name) {
                actionNames.append(name)
            }
            verbs.insert(name)
            // A bare name maps to itself so `canonicalName(forVerb:)` is total.
            if verbToActionName[name] == nil {
                verbToActionName[name] = name
            }
        } else {
            for verb in actionVerbs {
                if !actionNames.contains(verb) {
                    actionNames.append(verb)
                }
                verbs.insert(verb)
                verbToActionName[verb] = name
            }
        }
    }

    // MARK: - Qualifier Registration

    /// Record a qualifier registration owned by this plugin.
    ///
    /// The caller is responsible for also registering with the global
    /// `QualifierRegistry`; this method only tracks it locally so `unload` can
    /// drop the plugin's registrations.
    public mutating func registerQualifier(_ registration: QualifierRegistration) {
        qualifierRegistrations.append(registration)
    }

    // MARK: - Lookups

    /// The canonical action name for a dispatch verb, or `nil` if unknown.
    public func canonicalName(forVerb verb: String) -> String? {
        verbToActionName[verb]
    }

    /// The declared verbs for a canonical action name (Native), or `nil`.
    public func verbs(forName name: String) -> [String]? {
        verbsByName[name]
    }

    /// Metadata for a canonical action name, or `nil` if none was declared.
    public func metadata(forName name: String) -> ActionRegistry.PluginActionMetadata? {
        metadataByName[name]
    }

    // MARK: - Teardown

    /// Clear all action/verb/metadata/qualifier state. Called from host `unload`.
    public mutating func removeAll() {
        actionNames.removeAll()
        verbs.removeAll()
        verbToActionName.removeAll()
        verbsByName.removeAll()
        metadataByName.removeAll()
        qualifierRegistrations.removeAll()
    }
}
