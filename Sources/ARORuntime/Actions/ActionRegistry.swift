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

        return actions
    }

    /// Register a custom action
    /// - Parameter action: The action type to register
    public func register<A: ActionImplementation>(_ action: A.Type) {
        for verb in A.verbs {
            actions[verb.lowercased()] = action
        }
    }

    /// Unregister an action by verb
    /// - Parameter verb: The verb to unregister
    public func unregister(verb: String) {
        actions.removeValue(forKey: verb.lowercased())
    }

    /// Dynamic action handlers for plugin-provided actions
    private var dynamicHandlers: [String: DynamicActionHandler] = [:]

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
    public func registerDynamic(
        verb: String,
        handler: @escaping DynamicActionHandler,
        pluginName: String? = nil
    ) {
        let key = normalizeActionName(verb)
        dynamicHandlers[key] = handler
        if let name = pluginName {
            pluginVerbs[name, default: []].insert(key)
        }
    }

    /// Unregister all dynamic actions registered by a specific plugin.
    /// - Parameter pluginName: The plugin name passed to `registerDynamic(pluginName:)`
    public func unregisterPlugin(_ pluginName: String) {
        guard let verbs = pluginVerbs.removeValue(forKey: pluginName) else { return }
        for verb in verbs {
            dynamicHandlers.removeValue(forKey: verb)
        }
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

    /// Check if a verb is registered
    /// - Parameter verb: The verb to check
    /// - Returns: true if the verb has a registered implementation
    public func isRegistered(_ verb: String) -> Bool {
        return actions[verb.lowercased()] != nil
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
