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
public final class ActionRegistry: @unchecked Sendable {
    /// Shared singleton instance
    public static let shared = ActionRegistry()

    /// Lock for thread-safe access
    private let lock = NSLock()

    /// Mapping from verb (lowercase) to action type
    private var actions: [String: any ActionImplementation.Type] = [:]

    /// Private initializer - use shared instance
    private init() {
        registerBuiltIns()
    }

    // MARK: - Registration

    /// Register built-in actions
    private func registerBuiltIns() {
        // REQUEST actions (External → Internal)
        register(ExtractAction.self)
        register(RetrieveAction.self)
        register(ReceiveAction.self)
        register(FetchAction.self)
        register(RequestAction.self)
        register(ReadAction.self)

        // OWN actions (Internal → Internal)
        register(ComputeAction.self)
        register(ValidateAction.self)
        register(CompareAction.self)
        register(TransformAction.self)
        register(CreateAction.self)
        register(UpdateAction.self)
        register(FilterAction.self)
        register(SortAction.self)
        register(MergeAction.self)
        register(DeleteAction.self)

        // RESPONSE actions (Internal → External)
        register(ReturnAction.self)
        register(ThrowAction.self)
        register(SendAction.self)
        register(LogAction.self)
        register(StoreAction.self)
        register(WriteAction.self)
        register(NotifyAction.self)

        // EXPORT actions
        register(PublishAction.self)

        // Server actions
        register(StartAction.self)
        register(ListenAction.self)
        register(RouteAction.self)

        // Socket actions (ARO-0024)
        register(ConnectAction.self)
        register(BroadcastAction.self)
        register(CloseAction.self)

        // File actions
        register(WatchAction.self)

        // Wait action for long-running applications
        register(WaitForEventsAction.self)

        // State transition action
        register(AcceptAction.self)

        // Test actions (Given/When/Then/Assert)
        register(GivenAction.self)
        register(WhenAction.self)
        register(ThenAction.self)
        register(AssertAction.self)

        // Data pipeline actions (ARO-0018)
        register(MapAction.self)
        register(ReduceAction.self)
        register(PredicateFilterAction.self)

        // External service actions (ARO-0016)
        register(CallAction.self)
    }

    /// Register a custom action
    /// - Parameter action: The action type to register
    public func register<A: ActionImplementation>(_ action: A.Type) {
        lock.lock()
        defer { lock.unlock() }

        for verb in A.verbs {
            actions[verb.lowercased()] = action
        }
    }

    /// Unregister an action by verb
    /// - Parameter verb: The verb to unregister
    public func unregister(verb: String) {
        lock.lock()
        defer { lock.unlock() }
        actions.removeValue(forKey: verb.lowercased())
    }

    // MARK: - Lookup

    /// Get an action implementation for a verb
    /// - Parameter verb: The action verb
    /// - Returns: A new instance of the action implementation, or nil if not found
    public func action(for verb: String) -> (any ActionImplementation)? {
        lock.lock()
        defer { lock.unlock() }

        guard let actionType = actions[verb.lowercased()] else {
            return nil
        }

        return actionType.init()
    }

    /// Check if a verb is registered
    /// - Parameter verb: The verb to check
    /// - Returns: true if the verb has a registered implementation
    public func isRegistered(_ verb: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return actions[verb.lowercased()] != nil
    }

    /// Get all registered verbs
    public var registeredVerbs: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(actions.keys)
    }

    /// Get all registered actions grouped by role
    public var actionsByRole: [ActionRole: [String]] {
        lock.lock()
        defer { lock.unlock() }

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
        guard let action = action(for: verb) else {
            throw ActionError.unknownAction(verb)
        }

        return try await action.execute(result: result, object: object, context: context)
    }
}
