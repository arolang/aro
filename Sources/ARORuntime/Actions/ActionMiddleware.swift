// ============================================================
// ActionMiddleware.swift
// ARO Runtime - Action Middleware / Hooks (GitLab #107)
// ============================================================

import Foundation
import AROParser

// MARK: - Invocation

/// The action being invoked, as seen by middleware.
///
/// Carries the canonical verb plus the statement's result and object descriptors,
/// which is everything a hook needs to decide what is happening without reaching
/// back into the AST.
public struct ActionInvocation: Sendable {
    /// The canonical verb (synonyms already resolved — `print` arrives as `log`).
    public let verb: String

    /// The statement's result descriptor (`<user: id>` in `the <user: id>`).
    public let result: ResultDescriptor

    /// The statement's object descriptor, including its preposition.
    public let object: ObjectDescriptor

    public init(verb: String, result: ResultDescriptor, object: ObjectDescriptor) {
        self.verb = verb
        self.result = result
        self.object = object
    }

    /// A source-like rendering, for log and metric labels.
    public var description: String {
        "<\(verb)> the \(result) \(object)"
    }
}

// MARK: - Middleware

/// Continuation handed to middleware: calls the next middleware, or the action.
///
/// Middleware may call it zero times (short-circuit — return a substitute value
/// or throw), once (the normal case), or more than once (retry).
public typealias ActionNext = @Sendable () async throws -> any Sendable

/// A hook wrapping action execution.
///
/// ```swift
/// // Timing
/// ActionRegistry.shared.addMiddleware { invocation, _, next in
///     let start = DispatchTime.now().uptimeNanoseconds
///     defer { record(invocation.verb, DispatchTime.now().uptimeNanoseconds - start) }
///     return try await next()
/// }
///
/// // Authorization — short-circuits by throwing, so `next` is never called
/// ActionRegistry.shared.addMiddleware(for: ["store", "delete", "update"]) { invocation, context, next in
///     guard isAuthorized(context) else { throw ActionError.runtimeError("Unauthorized: \(invocation.verb)") }
///     return try await next()
/// }
///
/// // Retry — calls `next` more than once
/// ActionRegistry.shared.addMiddleware(for: ["request", "send"]) { _, _, next in
///     for attempt in 1...3 {
///         do { return try await next() }
///         catch where attempt < 3 { continue }
///     }
///     return try await next()
/// }
/// ```
public typealias ActionMiddleware = @Sendable (
    _ invocation: ActionInvocation,
    _ context: ExecutionContext,
    _ next: ActionNext
) async throws -> any Sendable

/// Handle for removing a previously registered middleware.
public struct ActionMiddlewareToken: Hashable, Sendable {
    let id: UInt64

    init(id: UInt64) {
        self.id = id
    }
}

/// A registered middleware together with the verbs it applies to.
struct RegisteredMiddleware: Sendable {
    let token: ActionMiddlewareToken
    /// Canonical, lowercased verbs this applies to; nil means every verb.
    let verbs: Set<String>?
    let body: ActionMiddleware

    func applies(to canonicalVerb: String) -> Bool {
        guard let verbs else { return true }
        return verbs.contains(canonicalVerb)
    }
}

// MARK: - Registration

extension ActionRegistry {

    /// Registers a middleware around action execution.
    ///
    /// Middleware runs in registration order, outermost first: the first
    /// registered sees the invocation first and the action's result last. This
    /// matches how the use cases compose — a timing hook registered first
    /// measures everything inside it, including a retry hook's extra attempts.
    ///
    /// - Parameters:
    ///   - verbs: Verbs to apply to. Synonyms are canonicalized, so `["print"]`
    ///     and `["log"]` are equivalent. Omit to apply to every action.
    ///   - middleware: The hook.
    /// - Returns: A token for `removeMiddleware(_:)`.
    ///
    /// - Note: While any middleware is registered, actions bypass the
    ///   synchronous fast path so that every action passes through the chain.
    ///   A hook that could be skipped for some verbs would be useless for
    ///   authorization, so correctness is preferred over that optimization.
    ///   Registering no middleware leaves execution completely unchanged.
    ///
    /// - Important: Middleware wraps **action execution**, and some statements
    ///   never execute an action. The interpreter evaluates a `Create`/`Compute`
    ///   statement whose result carries no qualifier as a plain expression and
    ///   binds the value directly:
    ///   ```aro
    ///   Create the <x> with 21.          (* no action dispatched — not seen *)
    ///   Compute the <y> from <x> * 2.    (* no action dispatched — not seen *)
    ///   Compute the <n: length> from <s>. (* dispatches ComputeAction — seen *)
    ///   Log <y> to the <console>.         (* dispatches LogAction — seen *)
    ///   ```
    ///   So a hook cannot be used to observe *every assignment*. It does see every
    ///   REQUEST, RESPONSE, EXPORT, and server action — including `store`,
    ///   `delete`, `send`, and `log` — which is what the authorization, audit, and
    ///   metrics use cases need.
    @discardableResult
    public func addMiddleware(
        for verbs: Set<String>? = nil,
        _ middleware: @escaping ActionMiddleware
    ) -> ActionMiddlewareToken {
        let canonical = verbs.map { set in
            Set(set.map { ActionRunner.canonicalizeVerb($0) })
        }
        return registerMiddleware(verbs: canonical, body: middleware)
    }

    /// Removes a middleware registered with `addMiddleware`.
    ///
    /// - Returns: true if the token matched a registered middleware.
    @discardableResult
    public func removeMiddleware(_ token: ActionMiddlewareToken) -> Bool {
        removeMiddlewareInternal(token)
    }

    /// Removes every registered middleware.
    ///
    /// Intended for test teardown — the registry is a process-wide singleton, so
    /// a middleware left registered leaks into subsequent tests.
    public func removeAllMiddleware() {
        removeAllMiddlewareInternal()
    }

    /// Whether any middleware is currently registered.
    public var hasMiddleware: Bool {
        hasMiddlewareInternal
    }

    // MARK: - Chain Application

    /// Nests `middleware` around `action`, first-registered outermost.
    static func chain(
        _ middleware: [RegisteredMiddleware],
        around action: @escaping ActionNext,
        invocation: ActionInvocation,
        context: ExecutionContext
    ) -> ActionNext {
        // Built inside-out so index 0 ends up outermost.
        var next = action
        for registered in middleware.reversed() {
            let inner = next
            let body = registered.body
            next = { try await body(invocation, context, inner) }
        }
        return next
    }
}
