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

    /// Create the initial dictionary of built-in actions
    /// This is a static method so it can be called from the nonisolated init.
    private static func createBuiltInActions() -> [String: any ActionImplementation.Type] {
        var actions: [String: any ActionImplementation.Type] = [:]

        func addAction<A: ActionImplementation>(_ action: A.Type) {
            for verb in A.verbs {
                actions[verb.lowercased()] = action
            }
        }

        // REQUEST actions (External → Internal)
        addAction(ExtractAction.self)
        addAction(RetrieveAction.self)
        addAction(ReceiveAction.self)
        addAction(RequestAction.self)
        addAction(ReadAction.self)

        // OWN actions (Internal → Internal)
        addAction(ComputeAction.self)
        addAction(ValidateAction.self)
        addAction(CompareAction.self)
        addAction(TransformAction.self)
        addAction(CreateAction.self)
        addAction(UpdateAction.self)
        // FilterAction is registered below in data pipeline actions
        addAction(SortAction.self)
        addAction(SplitAction.self)
        addAction(MergeAction.self)
        addAction(DeleteAction.self)
        addAction(ParseHtmlAction.self)

        // RESPONSE actions (Internal → External)
        addAction(ReturnAction.self)
        addAction(ThrowAction.self)
        addAction(SendAction.self)
        addAction(LogAction.self)
        addAction(StoreAction.self)
        addAction(WriteAction.self)
        addAction(NotifyAction.self)

        // EXPORT actions
        addAction(PublishAction.self)
        addAction(EmitAction.self)

        // Server actions
        addAction(StartAction.self)
        addAction(StopAction.self)
        addAction(ListenAction.self)

        // Socket actions (ARO-0024)
        addAction(ConnectAction.self)
        addAction(BroadcastAction.self)
        addAction(CloseAction.self)

        // File operations (ARO-0036)
        addAction(ListAction.self)
        addAction(StatAction.self)
        addAction(ExistsAction.self)
        addAction(MakeAction.self)
        addAction(CopyAction.self)
        addAction(MoveAction.self)
        addAction(AppendAction.self)

        // Wait action for long-running applications
        addAction(WaitForEventsAction.self)

        // State transition action
        addAction(AcceptAction.self)

        // Test actions (Given/When/Then/Assert)
        addAction(GivenAction.self)
        addAction(WhenAction.self)
        addAction(ThenAction.self)
        addAction(AssertAction.self)

        // Data pipeline actions (ARO-0018)
        addAction(MapAction.self)
        addAction(ReduceAction.self)
        addAction(FilterAction.self)

        // External service actions (ARO-0016)
        addAction(CallAction.self)

        // System execute action (ARO-0033)
        addAction(ExecuteAction.self)

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
        guard let action = action(for: verb) else {
            throw ActionError.unknownAction(verb)
        }

        return try await action.execute(result: result, object: object, context: context)
    }
}
