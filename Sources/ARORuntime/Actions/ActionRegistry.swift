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
/// if let action = await registry.action(for: "extract") {
///     let result = try await action.execute(result: desc, object: obj, context: ctx)
/// }
///
/// // Register a custom action
/// await registry.register(MyCustomAction.self)
/// ```
///
/// Converted to actor for Swift 6.2 concurrency safety (Issue #2).
public actor ActionRegistry {
    /// Shared singleton instance
    public static let shared = ActionRegistry()

    /// Mapping from verb (lowercase) to action type
    private var actions: [String: any ActionImplementation.Type]

    /// Private initializer - use shared instance
    private init() {
        // Initialize with built-in actions (must be done in init for actor isolation)
        self.actions = Self.createBuiltInActions()
        // Bootstrap the nonisolated read mirror so sync callers see built-ins
        // before any async caller has had a chance to mutate the registry.
        Self.publishMirror(
            actions: actions,
            dynamicHandlers: [:],
            dynamicMetadata: [:],
            pluginVerbs: [:]
        )
    }

    // MARK: - Registration

    /// Create the initial dictionary of built-in actions.
    /// This is a static method so it can be called from the nonisolated init.
    ///
    /// Actions are organised into `ActionModule` groups. To add a new built-in
    /// action, add it to the appropriate module (or create a new one) rather
    /// than extending this method directly.
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
    /// - Parameter action: The action type to register
    public func register<A: ActionImplementation>(_ action: A.Type) {
        for verb in A.verbs {
            actions[verb.lowercased()] = action
        }
        refreshMirror()
    }

    /// Unregister an action by verb
    /// - Parameter verb: The verb to unregister
    public func unregister(verb: String) {
        actions.removeValue(forKey: verb.lowercased())
        refreshMirror()
    }

    /// Dynamic action handlers for plugin-provided actions
    private var dynamicHandlers: [String: DynamicActionHandler] = [:]

    /// Metadata for dynamic plugin actions, keyed by normalised verb.
    /// Populated when a plugin supplies it via `registerDynamic(verb:handler:pluginName:metadata:)`.
    private var dynamicMetadata: [String: PluginActionMetadata] = [:]

    /// Maps plugin name → normalised verb keys it registered (for bulk unregister)
    private var pluginVerbs: [String: Set<String>] = [:]

    /// Cache of raw verb string → normalised form so the string work happens at most once per unique input.
    private var normalizedNameCache: [String: String] = [:]

    /// Type alias for dynamic action handler
    public typealias DynamicActionHandler = @Sendable (
        ResultDescriptor,
        ObjectDescriptor,
        ExecutionContext
    ) async throws -> any Sendable

    /// Rich metadata for a plugin-provided action.
    /// Carries the same shape as a built-in `BuiltInActionInfo` plus plugin origin.
    public struct PluginActionMetadata: Sendable {
        /// Semantic role of the action
        public let role: ActionRole
        /// Valid prepositions (e.g. ["from", "with"])
        public let prepositions: [String]
        /// Human-readable description
        public let description: String?
        /// PascalCase namespace handle (from `handle:` in plugin.yaml)
        public let handle: String?
        /// Version when this action was introduced
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
    /// Results are cached so repeated lookups of the same raw name are O(1).
    private func normalizeActionName(_ name: String) -> String {
        if let cached = normalizedNameCache[name] { return cached }
        let normalized = name.replacingOccurrences(of: "-", with: "").lowercased()
        normalizedNameCache[name] = normalized
        return normalized
    }

    /// Register a dynamic action from a plugin
    /// - Parameters:
    ///   - verb: The action verb
    ///   - handler: The handler function
    ///   - pluginName: Optional plugin name for bulk unregistration via `unregisterPlugin(_:)`
    ///   - metadata: Optional rich metadata (role, prepositions, description, …) used by
    ///     LSP/MCP completion and discovery layers. When omitted the action is still
    ///     registered but appears with default metadata.
    public func registerDynamic(
        verb: String,
        handler: @escaping DynamicActionHandler,
        pluginName: String? = nil,
        metadata: PluginActionMetadata? = nil
    ) {
        let key = normalizeActionName(verb)
        dynamicHandlers[key] = handler
        if let metadata = metadata {
            dynamicMetadata[key] = metadata
        }
        if let name = pluginName {
            pluginVerbs[name, default: []].insert(key)
        }
        refreshMirror()
    }

    /// Unregister all dynamic actions registered by a specific plugin.
    /// - Parameter pluginName: The plugin name passed to `registerDynamic(pluginName:)`
    public func unregisterPlugin(_ pluginName: String) {
        guard let verbs = pluginVerbs.removeValue(forKey: pluginName) else { return }
        for verb in verbs {
            dynamicHandlers.removeValue(forKey: verb)
            dynamicMetadata.removeValue(forKey: verb)
        }
        refreshMirror()
    }

    /// Get a dynamic action handler
    /// - Parameter verb: The action verb
    /// - Returns: The handler if registered
    public func dynamicHandler(for verb: String) -> DynamicActionHandler? {
        dynamicHandlers[normalizeActionName(verb)]
    }

    // MARK: - Lookup

    /// Get an action implementation for a verb
    /// - Parameter verb: The action verb
    /// - Returns: A new instance of the action implementation, or nil if not found
    public func action(for verb: String) -> (any ActionImplementation)? {
        guard let actionType = actions[verb.lowercased()] else {
            return nil
        }

        return actionType.init()
    }

    /// Check if a verb is registered.
    ///
    /// Returns true for both built-in actions and dynamically-registered plugin
    /// actions. The plugin lookup uses the same normalisation
    /// (`replacingOccurrences(of: "-", with: "")` + lowercase) as `dynamicHandler(for:)`.
    /// - Parameter verb: The verb to check
    /// - Returns: true if a built-in or dynamic plugin handler exists for this verb
    public func isRegistered(_ verb: String) -> Bool {
        if actions[verb.lowercased()] != nil { return true }
        return dynamicHandlers[normalizeActionName(verb)] != nil
    }

    /// Get all registered verbs
    public var registeredVerbs: Set<String> {
        return Set(actions.keys)
    }

    /// Get all registered actions grouped by role
    public var actionsByRole: [ActionRole: [String]] {
        var result: [ActionRole: [String]] = [:]
        for (verb, actionType) in actions {
            let role = actionType.role
            result[role, default: []].append(verb)
        }
        return result
    }

    // MARK: - Inspection Helpers

    /// Summary of a built-in action for display/documentation purposes
    public struct BuiltInActionInfo: Sendable {
        /// The canonical display name (e.g. "Extract", "Compute")
        public let name: String
        /// Semantic role
        public let role: ActionRole
        /// All verbs that invoke this action
        public let verbs: [String]
        /// Valid prepositions
        public let prepositions: [String]
    }

    /// Returns one `BuiltInActionInfo` per unique built-in action type, deduplicated
    /// so that actions with multiple verbs appear only once.
    public var allBuiltInActionInfos: [BuiltInActionInfo] {
        Self.buildBuiltInActionInfos(actions: actions)
    }

    /// Summary of a plugin (dynamic) action for display/documentation purposes
    public struct PluginActionInfo: Sendable {
        /// The registered verb
        public let verb: String
        /// Name of the plugin that registered this verb (nil for anonymous)
        public let pluginName: String?
        /// Optional rich metadata (role, prepositions, description, handle, since).
        /// `nil` when the plugin registered without supplying metadata.
        public let metadata: PluginActionMetadata?

        public init(verb: String, pluginName: String?, metadata: PluginActionMetadata? = nil) {
            self.verb = verb
            self.pluginName = pluginName
            self.metadata = metadata
        }
    }

    /// Returns one entry per registered dynamic (plugin) verb.
    /// Each entry includes the plugin name if the verb was registered with `pluginName:`.
    public var allPluginActionInfos: [PluginActionInfo] {
        Self.buildPluginActionInfos(
            dynamicHandlers: dynamicHandlers,
            dynamicMetadata: dynamicMetadata,
            pluginVerbs: pluginVerbs
        )
    }

    // MARK: - Nonisolated Read Mirror
    //
    // Synchronous, lock-protected mirror of the inspection data above. Lets
    // sync callers (LSP handlers, AROCatalog snapshots) read action metadata
    // without going through `await`, which is what previously triggered the
    // `Task { … }; semaphore.wait()` deadlock that starved the cooperative
    // thread pool under `swift test --parallel`.
    //
    // The mirror is refreshed inside every mutating actor method, so async
    // writers and sync readers stay consistent.

    private static let _mirrorLock = NSLock()
    nonisolated(unsafe) private static var _mirrorBuiltIns: [BuiltInActionInfo] = []
    nonisolated(unsafe) private static var _mirrorPlugins: [PluginActionInfo] = []

    /// Push the actor's current state into the read mirror.
    /// Called from inside actor-isolated mutators.
    private func refreshMirror() {
        Self.publishMirror(
            actions: actions,
            dynamicHandlers: dynamicHandlers,
            dynamicMetadata: dynamicMetadata,
            pluginVerbs: pluginVerbs
        )
    }

    private static func publishMirror(
        actions: [String: any ActionImplementation.Type],
        dynamicHandlers: [String: DynamicActionHandler],
        dynamicMetadata: [String: PluginActionMetadata],
        pluginVerbs: [String: Set<String>]
    ) {
        let builtIns = buildBuiltInActionInfos(actions: actions)
        let plugins = buildPluginActionInfos(
            dynamicHandlers: dynamicHandlers,
            dynamicMetadata: dynamicMetadata,
            pluginVerbs: pluginVerbs
        )
        _mirrorLock.lock()
        _mirrorBuiltIns = builtIns
        _mirrorPlugins = plugins
        _mirrorLock.unlock()
    }

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

    /// Synchronous, nonisolated snapshot of `allBuiltInActionInfos`.
    /// Safe to call from any context including the cooperative thread pool —
    /// reads are lock-protected, no actor hop required.
    public nonisolated static var snapshotBuiltInActionInfos: [BuiltInActionInfo] {
        // Force the singleton's lazy init so the mirror is populated even when
        // a sync caller is the very first to touch the registry.
        _ = ActionRegistry.shared
        _mirrorLock.lock()
        defer { _mirrorLock.unlock() }
        return _mirrorBuiltIns
    }

    /// Synchronous, nonisolated snapshot of `allPluginActionInfos`.
    public nonisolated static var snapshotPluginActionInfos: [PluginActionInfo] {
        _ = ActionRegistry.shared
        _mirrorLock.lock()
        defer { _mirrorLock.unlock() }
        return _mirrorPlugins
    }
}

// MARK: - Action Execution Helper

extension ActionRegistry {
    /// Execute an action for a given verb
    /// - Parameters:
    ///   - verb: The action verb
    ///   - result: The result descriptor
    ///   - object: The object descriptor
    ///   - context: The execution context
    /// - Returns: The result of the action
    /// - Throws: ActionError.unknownAction if verb not registered, or any error from the action
    public func execute(
        verb: String,
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        // Try built-in action first
        if let action = action(for: verb) {
            return try await action.execute(result: result, object: object, context: context)
        }

        // Try dynamic plugin action
        if let handler = dynamicHandler(for: verb) {
            return try await handler(result, object, context)
        }

        throw ActionError.unknownAction(verb)
    }
}
