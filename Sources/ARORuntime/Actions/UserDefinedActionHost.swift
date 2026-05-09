// ============================================================
// UserDefinedActionHost.swift
// ARO Runtime - Host for user-defined actions (ARO-0081)
// ============================================================
//
// Registers a dynamic action verb in `ActionRegistry` for every user-defined
// action discovered by `SemanticAnalyzer`. When invoked from an ARO statement,
// the host:
//   1. Builds an `<input>` object from the call site (`with { … }`, sugar
//      `from <value>`, or a variable reference).
//   2. Spawns a fresh `RuntimeContext` parented to the caller (so services and
//      published symbols remain accessible) but with no event/request data.
//   3. Runs the action body via `FeatureSetExecutor`.
//   4. Flattens the response into a `[String: Sendable]` dict that callers
//      pull fields from with `Extract the <field> from the <result: field>.`,
//      mirroring plugin-action semantics.

import Foundation
import AROParser

/// Discovers and registers every user-defined action under `Application.<Name>`.
///
/// Built once per application run from the live `AnalyzedProgram`. The host
/// keeps a strong reference to each `AnalyzedFeatureSet` so the registered
/// dynamic handler can run it without re-resolving by name on every call.
public final class UserDefinedActionHost: @unchecked Sendable {
    /// The name surfaced to `ActionRegistry.unregisterPlugin(_:)` so all
    /// user-defined actions can be cleared together (mirrors the plugin path).
    public static let pluginName = "_user_defined_actions_"

    private let analyzedProgram: AnalyzedProgram
    private let actionsByName: [String: AnalyzedFeatureSet]
    private let globalSymbols: GlobalSymbolStorage
    private let actionRegistryRef: ActionRegistry
    private let eventBusRef: EventBus

    public init(
        analyzedProgram: AnalyzedProgram,
        globalSymbols: GlobalSymbolStorage,
        actionRegistry: ActionRegistry = .shared,
        eventBus: EventBus = .shared
    ) {
        self.analyzedProgram = analyzedProgram
        self.globalSymbols = globalSymbols
        self.actionRegistryRef = actionRegistry
        self.eventBusRef = eventBus

        var byName: [String: AnalyzedFeatureSet] = [:]
        for fs in analyzedProgram.featureSets where fs.featureSet.isUserAction {
            byName[fs.featureSet.name] = fs
        }
        self.actionsByName = byName
    }

    /// Whether any user-defined actions were discovered.
    public var isEmpty: Bool { actionsByName.isEmpty }

    /// Names of registered actions (for diagnostics and tests).
    public var actionNames: [String] { actionsByName.keys.sorted() }

    /// Register every user-defined action under the verb `Application.<Name>`.
    /// Safe to call multiple times — `unregisterPlugin` cleans up previous
    /// registrations under the same plugin name.
    public func register() async {
        for (name, analyzed) in actionsByName {
            let verb = "Application.\(name)"
            let captured = analyzed
            let capturedHost = self
            actionRegistryRef.registerDynamic(
                verb: verb,
                handler: { result, object, context in
                    try await capturedHost.invoke(
                        analyzed: captured,
                        result: result,
                        object: object,
                        context: context
                    )
                },
                pluginName: Self.pluginName
            )
        }
    }

    /// Unregister every user-defined action. Used when reloading a program
    /// (currently only by tests) so a stale handler can't outlive its program.
    public func unregister() async {
        actionRegistryRef.unregisterPlugin(Self.pluginName)
    }

    // MARK: - Invocation

    /// Run a user-defined action. Public so tests can drive it directly.
    public func invoke(
        analyzed: AnalyzedFeatureSet,
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        let input = buildInput(
            featureSet: analyzed.featureSet,
            object: object,
            context: context
        )

        // Spawn a child context for the callee. Parenting to the caller keeps
        // services and published globals accessible. We deliberately do NOT
        // copy framework variables (event/request/pathParameters) — actions
        // are synchronous transformations with no event/request context.
        let childContext = RuntimeContext(
            featureSetName: analyzed.featureSet.name,
            businessActivity: analyzed.featureSet.businessActivity,
            parent: context
        )

        // Bind the input object so the action body can `Extract the <field>
        // from the <input: field>` exactly like a plugin/event handler.
        childContext.bind("input", value: input)

        // Run the action body. Reuse the same actionRegistry/eventBus/globalSymbols
        // the host was constructed with so `Publish` and event emission stay
        // visible application-wide.
        let executor = FeatureSetExecutor(
            actionRegistry: actionRegistryRef,
            eventBus: eventBusRef,
            globalSymbols: globalSymbols
        )
        let response = try await executor.execute(analyzed, context: childContext)

        // Flatten the response so callers extract fields from the result
        // variable directly (same shape plugin actions return).
        return flatten(response: response)
    }

    // MARK: - Input Construction

    /// Build the `<input>` object from the call site, mirroring plugin actions
    /// but tightening the contract to what user-defined actions support.
    ///
    /// Resolution order (first match wins):
    /// 1. `_with_` is bound LOCALLY and is an object: pass it through unchanged.
    /// 2. Sugar form: `_expression_` / `_literal_` is bound locally AND the
    ///    action declares `takes <field>` — wrap as `{ field: value }`.
    /// 3. Object base resolves to an existing object/dict — pass through.
    /// 4. Otherwise return an empty dict; downstream `Extract` calls will
    ///    surface a clear "field not found" error.
    ///
    /// **Local-only lookup is critical** for nested calls: per-statement
    /// transients (`_with_`, `_expression_`, `_literal_`) stay bound on the
    /// caller's context for the duration of the statement, so the parent-walk
    /// in `resolveAny` would otherwise leak the outer call's input into the
    /// nested call.
    func buildInput(
        featureSet: FeatureSet,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) -> [String: any Sendable] {
        // 1. `with { ... }` — already evaluated by the executor and bound to _with_.
        if let withDict = resolveLocal(context, "_with_") as? [String: any Sendable] {
            return withDict
        }

        // 2. Sugar form: `from <value>` against an action that declared `takes`.
        //    The parser routes literals to `_literal_` and expression results to
        //    `_expression_`, with object.base set accordingly.
        if let takesField = featureSet.userActionTakesField {
            if let exprValue = resolveLocal(context, "_expression_") {
                return [takesField: exprValue]
            }
            if let literal = resolveLocal(context, "_literal_") {
                return [takesField: literal]
            }
            // Fallback: caller passed a bare variable like `from <count>` and
            // the parser kept the object base as the variable name.
            if let value = context.resolveAny(object.base) {
                return [takesField: value]
            }
        }

        // 3. Caller passed `with <args>` where <args> is an existing object.
        if let resolved = context.resolveAny(object.base) as? [String: any Sendable] {
            return resolved
        }

        // 4. Empty input. The action body's `Extract` calls will fail with a
        //    descriptive error if it actually needs anything.
        return [:]
    }

    /// Look up `name` in the current context only, ignoring parents.
    /// Used for the per-statement transients (`_with_`, `_expression_`,
    /// `_literal_`) so a nested call doesn't accidentally pick up the
    /// outer caller's bindings.
    private func resolveLocal(_ context: ExecutionContext, _ name: String) -> (any Sendable)? {
        guard let runtimeCtx = context as? RuntimeContext else {
            // Non-RuntimeContext: fall back to the regular lookup. This path
            // exists only for synthetic test contexts.
            return context.resolveAny(name)
        }
        guard runtimeCtx.existsLocally(name) else { return nil }
        return runtimeCtx.resolveAny(name)
    }

    // MARK: - Output Flattening

    /// Convert a `Response` into the flat dict shape callers see at the call site.
    /// Matches the plugin convention: `status` and `reason` become top-level
    /// keys alongside whatever fields `Return ... with <data>.` produced.
    private func flatten(response: Response) -> [String: any Sendable] {
        var dict: [String: any Sendable] = [
            "status": response.status,
        ]
        if !response.reason.isEmpty {
            dict["reason"] = response.reason
        }
        for (key, anySendable) in response.data {
            if let value: any Sendable = anySendable.get() {
                dict[key] = value
            }
        }
        return dict
    }
}

