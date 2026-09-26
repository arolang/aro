// ============================================================
// EventHandlerDependencies.swift
// ARO Runtime - Shared plumbing for event-handler subscriptions
// ============================================================

import Foundation
import AROParser

// MARK: - Handler Dependencies

/// The four collaborators every event-handler subscription needs.
///
/// Each `register*Handlers` method in `ExecutionEngine` used to copy the same
/// four values out of the actor into local `captured*` constants before
/// subscribing, because the closure must not call back into the actor: the
/// actor may itself be blocked waiting for handlers to finish (see
/// `publishAndTrack`), so a re-entrant hop would deadlock. Bundling them in one
/// `Sendable` value keeps that property — nothing here touches the actor — and
/// says once what was said eleven times.
struct HandlerDependencies: Sendable {
    let actionRegistry: ActionRegistry
    let eventBus: EventBus
    let globalSymbols: GlobalSymbolStorage
    let services: ServiceRegistry

    /// A fresh executor for one handler invocation.
    func makeExecutor() -> FeatureSetExecutor {
        FeatureSetExecutor(
            actionRegistry: actionRegistry,
            eventBus: eventBus,
            globalSymbols: globalSymbols
        )
    }

    /// The child context a handler runs in: its own feature set name and
    /// business activity, parented to the context the application started in.
    func makeContext(
        for analyzedFS: AnalyzedFeatureSet,
        parent: RuntimeContext,
        caller: CallerIdentity? = nil
    ) -> RuntimeContext {
        RuntimeContext(
            featureSetName: analyzedFS.featureSet.name,
            businessActivity: analyzedFS.featureSet.businessActivity,
            eventBus: eventBus,
            parent: parent,
            caller: caller
        )
    }

    /// Run a handler feature set, turning a thrown error into a recoverable
    /// `ErrorOccurredEvent` rather than propagating it into the event bus.
    func runReportingErrors(
        _ analyzedFS: AnalyzedFeatureSet,
        context: RuntimeContext
    ) async {
        do {
            _ = try await makeExecutor().execute(analyzedFS, context: context)
        } catch {
            eventBus.publish(ErrorOccurredEvent(
                error: String(describing: error),
                context: analyzedFS.featureSet.name,
                recoverable: true
            ))
        }
    }

    /// Generic event-handler entry point (ARO-0054).
    ///
    /// Deliberately free of actor isolation: it is called from event
    /// subscriptions, and requiring the engine actor here would deadlock
    /// whenever the actor is blocked waiting for those very handlers.
    func run<E: RuntimeEvent>(
        _ analyzedFS: AnalyzedFeatureSet,
        baseContext: RuntimeContext,
        event: E,
        bindEventData: @Sendable (RuntimeContext, E) -> Void
    ) async {
        let handlerContext = makeContext(for: analyzedFS, parent: baseContext)

        // Bind event-specific data using the provided closure
        bindEventData(handlerContext, event)

        // Copy services from base context
        await services.registerAll(in: handlerContext)

        // Evaluate optional when-guard on the feature set declaration
        // e.g., `(Handler Name: Event Handler) when <trigger> = "startup" { ... }`
        if let whenCondition = analyzedFS.featureSet.whenCondition {
            let evaluator = ExpressionEvaluator()
            do {
                let condResult = try await evaluator.evaluate(whenCondition, context: handlerContext)
                let passes: Bool
                if let b = condResult as? Bool { passes = b }
                else if let i = condResult as? Int { passes = i != 0 }
                else { passes = !String(describing: condResult).isEmpty }
                guard passes else { return }
            } catch {
                // Guard evaluation error: skip this handler (don't crash)
                return
            }
        }

        do {
            AROLogger.debug("About to execute handler: \(analyzedFS.featureSet.name)")
            _ = try await makeExecutor().execute(analyzedFS, context: handlerContext)
            AROLogger.debug("Handler executed successfully: \(analyzedFS.featureSet.name)")
        } catch {
            AROLogger.error("Handler error: \(error)")
            eventBus.publish(ErrorOccurredEvent(
                error: String(describing: error),
                context: analyzedFS.featureSet.name,
                recoverable: true
            ))
        }
    }
}

// MARK: - Business Activity Guards

/// Parsing of the angle-bracket suffix on a business activity.
///
/// Three registration sites used to cut the brackets out of the activity string
/// by hand — `StateTransition Handler<toState:approved>`,
/// `KeyPress Handler<key:enter>` and the legacy
/// `status StateObserver<draft_to_placed>` — with three copies of the same
/// index arithmetic. `StateGuardSet.parse` covers the `<field:value>` form used
/// by domain handlers and repository observers; this covers the two shapes that
/// are not state guards.
enum ActivityGuard {
    /// The activity split into the part before the bracket suffix and the
    /// suffix's contents. An activity without a complete `<…>` is all head.
    static func split(_ activity: String) -> (head: String, brackets: String?) {
        guard let angleStart = activity.firstIndex(of: "<"),
              let angleEnd = activity.firstIndex(of: ">") else {
            return (activity, nil)
        }
        return (
            String(activity[..<angleStart]),
            String(activity[activity.index(after: angleStart)..<angleEnd])
        )
    }

    /// The text between the first `<` and the first `>`, if the activity has a
    /// bracket suffix at all.
    static func bracketContents(of activity: String) -> String? {
        split(activity).brackets
    }

    /// A single `key:value` pair from the bracket suffix, trimmed.
    /// `nil` when there is no suffix or it holds no colon.
    static func keyValue(of activity: String) -> (key: String, value: String)? {
        guard let contents = bracketContents(of: activity) else { return nil }
        let parts = contents.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return (
            key: parts[0].trimmingCharacters(in: .whitespaces),
            value: parts[1].trimmingCharacters(in: .whitespaces)
        )
    }
}
