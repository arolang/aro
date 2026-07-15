// ============================================================
// ActionRegistry.swift
// ARO Runtime - Action Registry
// ============================================================

import Foundation

/// Global registry that binds action verbs to their implementations
///
/// The ActionRegistry maintains a mapping from verb strings (e.g., "extract", "compute")
/// to their corresponding ActionImplementation types. Built-in actions are registered
/// automatically, and custom actions can be registered at runtime.
///
/// ## Usage
/// ```swift
/// // Get the shared registry
/// let registry = ActionRegistry.shared
///
/// // Look up an action
/// if let action = registry.action(for: "extract") {
///     let result = try await action.execute(result: desc, object: obj, context: ctx)
/// }
///
/// // Register a custom action
/// registry.register(MyCustomAction.self)
/// ```
///
/// **Concurrency model:** lock-protected `final class`, parallel to `QualifierRegistry`.
/// The previous implementation was an `actor` and required `await` on every call. Plugin
/// loading paths bridged that with `Task { await … }; semaphore.wait()`, which under
/// `swift test --parallel` starved the cooperative thread pool and deadlocked the entire
/// test run. Sync access fixes both: callers get straight-line code, plugin loading is
/// just a series of plain method calls, and existing `await` callers compile (Swift
/// emits a "no async operations occur" warning, not an error).
public final class ActionRegistry: @unchecked Sendable {
    /// Shared singleton instance
    public static let shared = ActionRegistry()

    /// Lock guarding all mutable state below.
    private let lock = NSLock()

    /// Mapping from verb (lowercase) to action type
    private var actions: [String: any ActionImplementation.Type]

    /// Dynamic action handlers for plugin-provided actions
    private var dynamicHandlers: [String: DynamicActionHandler] = [:]

    /// Metadata for dynamic plugin actions, keyed by normalised verb.
    private var dynamicMetadata: [String: PluginActionMetadata] = [:]

    /// Maps plugin name → normalised verb keys it registered (for bulk unregister)
    private var pluginVerbs: [String: Set<String>] = [:]

    /// Cache of raw verb string → normalised form so the string work happens at most once per unique input.
    private var normalizedNameCache: [String: String] = [:]

    /// Private initializer - use shared instance
    private init() {
        self.actions = Self.createBuiltInActions()
    }

    // MARK: - Registration

    /// Create the initial dictionary of built-in actions.
    private static func createBuiltInActions() -> [String: any ActionImplementation.Type] {
        var actions: [String: any ActionImplementation.Type] = [:]

        func register(_ moduleActions: [any ActionImplementation.Type]) {
            for actionType in moduleActions {
                for verb in actionType.verbs {
                    actions[verb.lowercased()] = actionType
                }
            }
        }

        register(RequestActionsModule.actions)
        register(OwnActionsModule.actions)
        register(ResponseActionsModule.actions)
        register(ServerActionsModule.actions)
        register(SocketActionsModule.actions)
        register(FileActionsModule.actions)
        register(DataPipelineActionsModule.actions)
        register(TestActionsModule.actions)
        register(TerminalActionsModule.actions)
        register(SystemActionsModule.actions)
        #if !os(Windows)
        register(GitActionsModule.actions)
        #endif

        return actions
    }

    /// Register a custom action
    public func register<A: ActionImplementation>(_ action: A.Type) {
        lock.lock()
        for verb in A.verbs {
            actions[verb.lowercased()] = action
        }
        lock.unlock()
        // Plugin- or app-registered actions need to flow into the
        // ActionRunner's sync cache so SynchronousAction
        // conformances can still skip the async path (#327).
        ActionRunner.shared.rebuildSyncCache()
    }

    /// Snapshot of every registered action type keyed by
    /// lowercased verb. Used by ActionRunner to overlay
    /// dynamically registered SynchronousAction conformances on
    /// top of the built-in module set (#327).
    public func allRegisteredActionTypes() -> [String: any ActionImplementation.Type] {
        lock.lock(); defer { lock.unlock() }
        return actions
    }

    /// Unregister an action by verb
    public func unregister(verb: String) {
        lock.lock(); defer { lock.unlock() }
        actions.removeValue(forKey: verb.lowercased())
    }

    /// Type alias for dynamic action handler
    public typealias DynamicActionHandler = @Sendable (
        ResultDescriptor,
        ObjectDescriptor,
        ExecutionContext
    ) async throws -> any Sendable

    /// Rich metadata for a plugin-provided action.
    public struct PluginActionMetadata: Sendable {
        public let role: ActionRole
        public let prepositions: [String]
        public let description: String?
        public let handle: String?
        public let since: String?

        public init(
            role: ActionRole = .own,
            prepositions: [String] = [],
            description: String? = nil,
            handle: String? = nil,
            since: String? = nil
        ) {
            self.role = role
            self.prepositions = prepositions
            self.description = description
            self.handle = handle
            self.since = since
        }
    }

    /// Normalize action name by removing hyphens and lowercasing.
    /// Caller must hold `lock`.
    private func normalizeActionNameLocked(_ name: String) -> String {
        if let cached = normalizedNameCache[name] { return cached }
        let normalized = name.replacingOccurrences(of: "-", with: "").lowercased()
        normalizedNameCache[name] = normalized
        return normalized
    }

    /// Register a dynamic action from a plugin
    public func registerDynamic(
        verb: String,
        handler: @escaping DynamicActionHandler,
        pluginName: String? = nil,
        metadata: PluginActionMetadata? = nil
    ) {
        lock.lock(); defer { lock.unlock() }
        let key = normalizeActionNameLocked(verb)
        dynamicHandlers[key] = handler
        if let metadata = metadata {
            dynamicMetadata[key] = metadata
        }
        if let name = pluginName {
            pluginVerbs[name, default: []].insert(key)
        }
    }

    /// Unregister all dynamic actions registered by a specific plugin.
    public func unregisterPlugin(_ pluginName: String) {
        lock.lock(); defer { lock.unlock() }
        guard let verbs = pluginVerbs.removeValue(forKey: pluginName) else { return }
        for verb in verbs {
            dynamicHandlers.removeValue(forKey: verb)
            dynamicMetadata.removeValue(forKey: verb)
        }
    }

    /// Get a dynamic action handler
    public func dynamicHandler(for verb: String) -> DynamicActionHandler? {
        lock.lock(); defer { lock.unlock() }
        return dynamicHandlers[normalizeActionNameLocked(verb)]
    }

    // MARK: - Lookup

    /// Get an action implementation for a verb
    public func action(for verb: String) -> (any ActionImplementation)? {
        lock.lock(); defer { lock.unlock() }
        guard let actionType = actions[verb.lowercased()] else { return nil }
        return actionType.init()
    }

    /// Check if a verb is registered.
    public func isRegistered(_ verb: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if actions[verb.lowercased()] != nil { return true }
        return dynamicHandlers[normalizeActionNameLocked(verb)] != nil
    }

    /// Get all registered verbs
    public var registeredVerbs: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(actions.keys)
    }

    /// Get all registered actions grouped by role
    public var actionsByRole: [ActionRole: [String]] {
        lock.lock(); defer { lock.unlock() }
        var result: [ActionRole: [String]] = [:]
        for (verb, actionType) in actions {
            result[actionType.role, default: []].append(verb)
        }
        return result
    }

    // MARK: - Inspection Helpers

    /// Summary of a built-in action for display/documentation purposes
    public struct BuiltInActionInfo: Sendable {
        public let name: String
        public let role: ActionRole
        public let verbs: [String]
        public let prepositions: [String]
    }

    /// Returns one `BuiltInActionInfo` per unique built-in action type, deduplicated
    /// so that actions with multiple verbs appear only once.
    public var allBuiltInActionInfos: [BuiltInActionInfo] {
        lock.lock(); defer { lock.unlock() }
        return Self.buildBuiltInActionInfos(actions: actions)
    }

    /// Summary of a plugin (dynamic) action for display/documentation purposes
    public struct PluginActionInfo: Sendable {
        public let verb: String
        public let pluginName: String?
        public let metadata: PluginActionMetadata?

        public init(verb: String, pluginName: String?, metadata: PluginActionMetadata? = nil) {
            self.verb = verb
            self.pluginName = pluginName
            self.metadata = metadata
        }
    }

    /// Returns one entry per registered dynamic (plugin) verb.
    public var allPluginActionInfos: [PluginActionInfo] {
        lock.lock(); defer { lock.unlock() }
        return Self.buildPluginActionInfos(
            dynamicHandlers: dynamicHandlers,
            dynamicMetadata: dynamicMetadata,
            pluginVerbs: pluginVerbs
        )
    }

    // MARK: - Static Read Snapshots
    //
    // Kept for source-compat with code that called `ActionRegistry.snapshotXxx` after
    // the previous mirror-based fix. They now reduce to direct sync reads through the
    // singleton.

    public static var snapshotBuiltInActionInfos: [BuiltInActionInfo] {
        shared.allBuiltInActionInfos
    }

    public static var snapshotPluginActionInfos: [PluginActionInfo] {
        shared.allPluginActionInfos
    }

    // MARK: - Pure Builders

    private static func buildBuiltInActionInfos(
        actions: [String: any ActionImplementation.Type]
    ) -> [BuiltInActionInfo] {
        var seen: Set<ObjectIdentifier> = []
        var result: [BuiltInActionInfo] = []
        for actionType in actions.values {
            let id = ObjectIdentifier(actionType)
            guard seen.insert(id).inserted else { continue }
            let name = String(describing: actionType)
                .replacingOccurrences(of: "Action", with: "")
            let preps = actionType.validPrepositions.map { $0.rawValue }.sorted()
            result.append(BuiltInActionInfo(
                name: name,
                role: actionType.role,
                verbs: actionType.verbs.sorted(),
                prepositions: preps
            ))
        }
        return result.sorted { $0.name < $1.name }
    }

    private static func buildPluginActionInfos(
        dynamicHandlers: [String: DynamicActionHandler],
        dynamicMetadata: [String: PluginActionMetadata],
        pluginVerbs: [String: Set<String>]
    ) -> [PluginActionInfo] {
        var verbToPlugin: [String: String] = [:]
        for (plugin, verbs) in pluginVerbs {
            for verb in verbs {
                verbToPlugin[verb] = plugin
            }
        }
        return dynamicHandlers.keys.sorted().map { verb in
            PluginActionInfo(
                verb: verb,
                pluginName: verbToPlugin[verb],
                metadata: dynamicMetadata[verb]
            )
        }
    }
}

// MARK: - Action Execution Helper

extension ActionRegistry {
    /// Execute an action for a given verb
    public func execute(
        verb: String,
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        // Resolve under lock, execute outside lock so the async action body
        // doesn't block other registry readers.
        let resolved: (action: (any ActionImplementation)?, handler: DynamicActionHandler?) = {
            lock.lock(); defer { lock.unlock() }
            let action = actions[verb.lowercased()].map { $0.init() }
            let handler = dynamicHandlers[normalizeActionNameLocked(verb)]
            return (action, handler)
        }()

        if let action = resolved.action {
            return try await action.execute(result: result, object: object, context: context)
        }
        if let handler = resolved.handler {
            return try await handler(result, object, context)
        }
        throw ActionError.unknownAction(verb)
    }
}
