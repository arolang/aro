// ============================================================
// ActionRegistry.swift
// ARO Runtime - Action Registry
// ============================================================

import Foundation
import AROParser

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

    /// Every action type that claims a verb, in registration order.
    ///
    /// `actions` keeps one winner per verb, and that used to be the whole
    /// story: registration is `actions[verb] = type`, so a second claimant
    /// silently replaced the first. `DeleteAction` claims `clear` and documents
    /// `Clear the <all> from the <message-repository>.`; `TerminalActions`'
    /// `ClearAction` claims it too and is registered later, so every `Clear`
    /// reached the terminal action and the repository form failed at run time
    /// (GitLab #562).
    ///
    /// The two are not actually ambiguous — `ClearAction` accepts only `for`,
    /// `DeleteAction` accepts `from`/`in`/`of` — so `execute` picks the
    /// claimant whose declared `validPrepositions` fits the statement.
    /// `validPrepositions` is already the contract each action states and
    /// `validatePreposition` already enforces, so this reads the existing
    /// declaration rather than adding a new concept.
    private var overloads: [String: [any ActionImplementation.Type]] = [:]

    /// Dynamic action handlers for plugin-provided actions
    private var dynamicHandlers: [String: DynamicActionHandler] = [:]

    /// Dynamic handlers whose work is synchronous and may run on the calling
    /// thread. See `registerDynamicSynchronous(verb:handler:pluginName:)`.
    private var synchronousDynamicHandlers: [String: SynchronousDynamicActionHandler] = [:]

    /// Metadata for dynamic plugin actions, keyed by normalised verb.
    private var dynamicMetadata: [String: PluginActionMetadata] = [:]

    /// Maps plugin name → normalised verb keys it registered (for bulk unregister)
    private var pluginVerbs: [String: Set<String>] = [:]

    /// Cache of raw verb string → normalised form so the string work happens at most once per unique input.
    private var normalizedNameCache: [String: String] = [:]

    /// Registered action middleware, in registration order (GitLab #107).
    private var middleware: [RegisteredMiddleware] = []

    /// Monotonic source of middleware token IDs.
    private var nextMiddlewareID: UInt64 = 0

    /// Private initializer - use shared instance
    private init() {
        let builtIns = Self.createBuiltInActions()
        self.actions = builtIns.actions
        self.overloads = builtIns.overloads
    }

    // MARK: - Middleware Storage (GitLab #107)

    func registerMiddleware(verbs: Set<String>?, body: @escaping ActionMiddleware) -> ActionMiddlewareToken {
        lock.lock(); defer { lock.unlock() }
        nextMiddlewareID += 1
        let token = ActionMiddlewareToken(id: nextMiddlewareID)
        middleware.append(RegisteredMiddleware(token: token, verbs: verbs, body: body))
        return token
    }

    func removeMiddlewareInternal(_ token: ActionMiddlewareToken) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let before = middleware.count
        middleware.removeAll { $0.token == token }
        return middleware.count != before
    }

    func removeAllMiddlewareInternal() {
        lock.lock(); defer { lock.unlock() }
        middleware.removeAll()
    }

    var hasMiddlewareInternal: Bool {
        lock.lock(); defer { lock.unlock() }
        return !middleware.isEmpty
    }

    /// Snapshot of the middleware applicable to `canonicalVerb`, in registration order.
    ///
    /// Must be called with `lock` held — `execute` folds this into the same lock
    /// acquisition it already makes to resolve the action, so enabling middleware
    /// costs no extra locking on the execution path.
    func middlewareSnapshotLocked(for canonicalVerb: String) -> [RegisteredMiddleware] {
        guard !middleware.isEmpty else { return [] }
        return middleware.filter { $0.applies(to: canonicalVerb) }
    }

    // MARK: - Registration

    /// The built-in action modules, in registration order.
    ///
    /// Order matters: registration is last-writer-wins per verb, and
    /// `resolveLocked` breaks a tie by preferring the latest claimant whose
    /// declared prepositions fit. Exposed so a test can check the same list the
    /// registry builds from, rather than a copy that can drift (GitLab #562).
    public static let builtInModules: [[any ActionImplementation.Type]] = {
        var modules: [[any ActionImplementation.Type]] = [
            RequestActionsModule.actions,
            OwnActionsModule.actions,
            ResponseActionsModule.actions,
            ServerActionsModule.actions,
            SocketActionsModule.actions,
            FileActionsModule.actions,
            DataPipelineActionsModule.actions,
            TestActionsModule.actions,
            TerminalActionsModule.actions,
            SystemActionsModule.actions,
        ]
        #if !os(Windows)
        modules.append(GitActionsModule.actions)
        #endif
        return modules
    }()

    /// Create the initial dictionary of built-in actions.
    private static func createBuiltInActions() -> (
        actions: [String: any ActionImplementation.Type],
        overloads: [String: [any ActionImplementation.Type]]
    ) {
        var actions: [String: any ActionImplementation.Type] = [:]
        var overloads: [String: [any ActionImplementation.Type]] = [:]

        func register(_ moduleActions: [any ActionImplementation.Type]) {
            for actionType in moduleActions {
                for verb in actionType.verbs {
                    let key = verb.lowercased()
                    // The same type listed by two modules is a duplicate, not a
                    // conflict — it resolves to identical behaviour either way.
                    let alreadyClaimed = overloads[key]?.contains {
                        String(describing: $0) == String(describing: actionType)
                    } ?? false
                    if !alreadyClaimed { overloads[key, default: []].append(actionType) }
                    actions[key] = actionType
                }
            }
        }

        for module in Self.builtInModules { register(module) }

        reportShadowedClaimants(overloads)
        return (actions, overloads)
    }

    /// Warn about an action that no statement can reach.
    ///
    /// Registration is last-writer-wins per verb, and `resolveLocked` breaks a
    /// tie by preposition, preferring the *latest* claimant that fits. So a
    /// claimant is unreachable exactly when every preposition it declares is
    /// also declared by a later claimant of the same verb — that is the shape
    /// that hid GitLab #562, where `DeleteAction`'s documented
    /// `Clear the <all> from the <m-repository>.` was replaced wholesale by
    /// `TerminalActions.ClearAction`.
    ///
    /// Overlapping-but-not-covering is fine and common: `DeleteAction`
    /// (`from`, `for`) and `ClearAction` (`for`) share `for`, and both stay
    /// reachable because `from` is Delete's alone.
    private static func reportShadowedClaimants(
        _ overloads: [String: [any ActionImplementation.Type]]
    ) {
        for (verb, claimants) in overloads.sorted(by: { $0.key < $1.key }) where claimants.count > 1 {
            for (index, claimant) in claimants.enumerated() {
                let later = claimants.dropFirst(index + 1)
                guard !later.isEmpty else { continue }
                let covered = later.reduce(into: Set<Preposition>()) {
                    $0.formUnion($1.validPrepositions)
                }
                if claimant.validPrepositions.isSubset(of: covered) {
                    let shadows = later
                        .filter { !$0.validPrepositions.isDisjoint(with: claimant.validPrepositions) }
                        .map { String(describing: $0) }
                        .joined(separator: ", ")
                    let preps = claimant.validPrepositions
                        .map(\.rawValue).sorted().joined(separator: ", ")
                    let message = "[ActionRegistry] Warning: '\(verb)' on \(claimant) is "
                        + "unreachable — \(shadows) claims the same verb for every "
                        + "preposition it accepts (\(preps)).\n"
                    FileHandle.standardError.write(Data(message.utf8))
                }
            }
        }
    }

    /// Register a custom action
    public func register<A: ActionImplementation>(_ action: A.Type) {
        lock.lock()
        for verb in A.verbs {
            let key = verb.lowercased()
            let alreadyClaimed = overloads[key]?.contains {
                String(describing: $0) == String(describing: action)
            } ?? false
            if !alreadyClaimed { overloads[key, default: []].append(action) }
            actions[key] = action
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

    /// A dynamic handler that does its work synchronously.
    public typealias SynchronousDynamicActionHandler = @Sendable (
        ResultDescriptor,
        ObjectDescriptor,
        ExecutionContext
    ) throws -> any Sendable

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

    /// Register a dynamic action whose handler is synchronous.
    ///
    /// The async form runs its handler as an `AROFuture` on `ActionTaskExecutor`
    /// while the caller blocks in `force()`, which costs one blocked thread per
    /// nesting level. That is fine for a plugin call and fatal for recursion: a
    /// compiled binary calling a user-defined action 200 deep exhausted GCD's
    /// worker pool and every level waited forever (GitLab #473). A handler
    /// registered here runs inline on the calling thread instead, so nesting
    /// costs stack rather than threads.
    ///
    /// The verb is registered in both tables: middleware and any async caller
    /// still see a normal dynamic handler.
    public func registerDynamicSynchronous(
        verb: String,
        handler: @escaping SynchronousDynamicActionHandler,
        pluginName: String? = nil,
        metadata: PluginActionMetadata? = nil
    ) {
        lock.lock(); defer { lock.unlock() }
        let key = normalizeActionNameLocked(verb)
        synchronousDynamicHandlers[key] = handler
        dynamicHandlers[key] = { result, object, context in
            try handler(result, object, context)
        }
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
            synchronousDynamicHandlers.removeValue(forKey: verb)
            dynamicMetadata.removeValue(forKey: verb)
        }
    }

    /// Unregister specific dynamic verbs.
    ///
    /// Narrower than `unregisterPlugin(_:)`, which clears everything registered
    /// under one plugin name. All user-defined actions share a single plugin
    /// name, so tearing down by plugin removes actions belonging to whatever
    /// else is running — which is exactly what happened between two test suites
    /// sharing this process-wide registry.
    public func unregisterDynamic(verbs: [String]) {
        lock.lock(); defer { lock.unlock() }
        for verb in verbs {
            let key = normalizeActionNameLocked(verb)
            dynamicHandlers.removeValue(forKey: key)
            synchronousDynamicHandlers.removeValue(forKey: key)
            dynamicMetadata.removeValue(forKey: key)
            for (plugin, keys) in pluginVerbs where keys.contains(key) {
                var remaining = keys
                remaining.remove(key)
                pluginVerbs[plugin] = remaining.isEmpty ? nil : remaining
            }
        }
    }

    /// Get a dynamic action handler
    public func dynamicHandler(for verb: String) -> DynamicActionHandler? {
        lock.lock(); defer { lock.unlock() }
        return dynamicHandlers[normalizeActionNameLocked(verb)]
    }

    /// Get a synchronous dynamic action handler, if the verb has one.
    public func synchronousDynamicHandler(for verb: String) -> SynchronousDynamicActionHandler? {
        lock.lock(); defer { lock.unlock() }
        return synchronousDynamicHandlers[normalizeActionNameLocked(verb)]
    }


    /// The action type to run for `verb` with this statement's preposition.
    ///
    /// One claimant is the overwhelmingly common case and resolves exactly as
    /// before. When a verb has several, the one whose `validPrepositions`
    /// contains the statement's preposition wins — which is what lets
    /// `Clear the <screen> for the <terminal>.` and
    /// `Clear the <all> from the <m-repository>.` both work (GitLab #562).
    /// With no match the last registration stands, so the error the caller
    /// gets is the same `validatePreposition` error as before rather than a
    /// confusing "unknown action".
    ///
    /// Must be called with `lock` held.
    private func resolveLocked(
        verb: String,
        preposition: Preposition
    ) -> (any ActionImplementation.Type)? {
        let key = verb.lowercased()
        guard let candidates = overloads[key], candidates.count > 1 else {
            return actions[key]
        }
        if let fitting = candidates.last(where: { $0.validPrepositions.contains(preposition) }) {
            return fitting
        }
        return actions[key]
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
        // doesn't block other registry readers. The middleware snapshot is taken
        // in the same acquisition, so hooks add no extra locking here (#107).
        // Verbs arrive as written in source ("Log", "Compute"). Middleware filters
        // and `ActionInvocation.verb` use the canonical lowercase form, so a hook
        // registered for ["log"] matches a statement written `Log …` or `Print …`.
        let canonicalVerb = ActionRunner.canonicalizeVerb(verb)

        let resolved: (
            action: (any ActionImplementation)?,
            handler: DynamicActionHandler?,
            middleware: [RegisteredMiddleware]
        ) = {
            lock.lock(); defer { lock.unlock() }
            let action = resolveLocked(verb: verb, preposition: object.preposition).map { $0.init() }
            let handler = dynamicHandlers[normalizeActionNameLocked(verb)]
            return (action, handler, middlewareSnapshotLocked(for: canonicalVerb))
        }()

        // Resolve the target before running any middleware, so an unknown verb
        // still reports `unknownAction` rather than surfacing from inside a hook.
        let invoke: ActionNext
        if let action = resolved.action {
            invoke = { try await action.execute(result: result, object: object, context: context) }
        } else if let handler = resolved.handler {
            invoke = { try await handler(result, object, context) }
        } else {
            throw ActionError.unknownAction(verb)
        }

        guard !resolved.middleware.isEmpty else {
            return try await invoke()
        }
        return try await Self.chain(
            resolved.middleware,
            around: invoke,
            invocation: ActionInvocation(verb: canonicalVerb, result: result, object: object),
            context: context
        )()
    }
}
