// ============================================================
// OpenAPICallbackDispatcher.swift
// ARO Runtime - OpenAPI Outbound Callback Dispatch (GitLab #187)
// ============================================================

import Foundation

/// Fires the out-of-band HTTP requests described by an operation's OpenAPI
/// Callback Objects (server-initiated / outgoing webhooks, GitLab #187).
///
/// An `Operation.callbacks` map associates a *callback name* with a Callback
/// Object, which is itself a map from an OpenAPI *runtime expression*
/// (e.g. `{$request.body#/callbackUrl}`) to a Path Item describing the request
/// the server makes back to the caller. Dispatch is a two-step process:
///
/// 1. **Plan** — resolve every callback's URL and HTTP method(s) against the
///    triggering request context using ``OpenAPIRuntimeExpression``. This is a
///    pure function with no I/O, so the URL-resolution behaviour is unit-tested
///    in isolation. A callback whose expression cannot be resolved yields a
///    plan entry carrying a diagnostic rather than aborting the whole batch —
///    consistent with ARO's "happy case" philosophy where one bad callback URL
///    must not sink the others.
/// 2. **Dispatch** — send each planned request through a ``CallbackHTTPInvoker``
///    seam. The production seam is ``AROHTTPClient`` (see the adapter in
///    `HTTPClient+Callback.swift`); tests inject a recording mock so the firing
///    logic is verified without a live network.
public enum OpenAPICallbackDispatcher {

    // MARK: - Plan

    /// A single outbound callback request resolved against a request context.
    ///
    /// When resolution succeeds, ``resolvedURL`` is non-nil and
    /// ``resolutionError`` is nil; when the runtime expression cannot be
    /// resolved, the reverse holds. ``method`` is always populated from the
    /// Path Item so diagnostics can name the request that was skipped.
    public struct CallbackPlan: Sendable, Equatable {
        /// The callback name from the `Operation.callbacks` map (e.g. `onEvent`).
        public let callbackName: String
        /// The raw runtime-expression key from the Callback Object.
        public let expression: String
        /// The HTTP method for this out-of-band request (upper-cased).
        public let method: String
        /// The resolved absolute callback URL, or nil when resolution failed.
        public let resolvedURL: String?
        /// A human-readable diagnostic when resolution failed, else nil.
        public let resolutionError: String?

        public init(
            callbackName: String,
            expression: String,
            method: String,
            resolvedURL: String?,
            resolutionError: String?
        ) {
            self.callbackName = callbackName
            self.expression = expression
            self.method = method
            self.resolvedURL = resolvedURL
            self.resolutionError = resolutionError
        }

        /// True when this plan resolved to a callable URL.
        public var isResolved: Bool { resolvedURL != nil }
    }

    /// Resolve every callback declared on `operation` into a flat list of
    /// planned requests, evaluating each Callback Object's runtime-expression
    /// key against `context`.
    ///
    /// The result is ordered deterministically by callback name, then
    /// expression, then method, so callers (and tests) see a stable sequence
    /// regardless of dictionary iteration order.
    public static func plan(
        operation: Operation,
        context: OpenAPIRuntimeExpression.Context
    ) -> [CallbackPlan] {
        guard let callbacks = operation.callbacks else { return [] }

        var plans: [CallbackPlan] = []
        for callbackName in callbacks.keys.sorted() {
            guard let callback = callbacks[callbackName] else { continue }
            for expression in callback.expressions.keys.sorted() {
                guard let pathItem = callback.expressions[expression] else { continue }

                // Resolve the URL once per expression; every method on the
                // Path Item shares it.
                let resolved: String?
                let error: String?
                do {
                    resolved = try OpenAPIRuntimeExpression.resolveTemplate(expression, context: context)
                    error = nil
                } catch let resolveError {
                    resolved = nil
                    error = String(describing: resolveError)
                }

                for (method, _) in pathItem.allOperations.sorted(by: { $0.method < $1.method }) {
                    plans.append(CallbackPlan(
                        callbackName: callbackName,
                        expression: expression,
                        method: method.uppercased(),
                        resolvedURL: resolved,
                        resolutionError: error
                    ))
                }
            }
        }
        return plans
    }

    // MARK: - Dispatch

    /// The outcome of firing one planned callback request.
    public struct CallbackDispatchResult: Sendable, Equatable {
        /// The plan this result corresponds to.
        public let plan: CallbackPlan
        /// The HTTP status code returned by the callback receiver, or nil when
        /// the request was never sent (unresolved URL) or the send threw.
        public let statusCode: Int?
        /// A diagnostic when the callback could not be delivered, else nil.
        public let error: String?

        public init(plan: CallbackPlan, statusCode: Int?, error: String?) {
            self.plan = plan
            self.statusCode = statusCode
            self.error = error
        }

        /// True when the callback was delivered and acknowledged with a 2xx.
        public var isDelivered: Bool {
            guard let code = statusCode else { return false }
            return (200..<300).contains(code)
        }
    }

    /// Resolve and fire every callback declared on `operation` against
    /// `context`, sending each through `invoker`.
    ///
    /// - Parameters:
    ///   - operation: The operation whose `callbacks` should be triggered.
    ///   - context: The triggering request context used to resolve callback URLs.
    ///   - invoker: The HTTP seam used to send each out-of-band request.
    ///   - payload: The body to send with each callback request. Defaults to the
    ///     triggering request body — the common "forward the event" pattern.
    ///   - headers: Extra headers to attach to every callback request.
    /// - Returns: One result per planned callback request, in plan order.
    ///   Unresolved plans and failed sends are reported as non-delivered
    ///   results rather than thrown, so one failure never blocks the rest.
    @discardableResult
    public static func dispatch(
        operation: Operation,
        context: OpenAPIRuntimeExpression.Context,
        invoker: CallbackHTTPInvoker,
        payload: Data? = nil,
        headers: [String: String] = [:]
    ) async -> [CallbackDispatchResult] {
        let body = payload ?? context.body
        var results: [CallbackDispatchResult] = []

        for plan in plan(operation: operation, context: context) {
            guard let url = plan.resolvedURL else {
                results.append(CallbackDispatchResult(
                    plan: plan,
                    statusCode: nil,
                    error: plan.resolutionError ?? "callback URL could not be resolved"
                ))
                continue
            }

            do {
                let status = try await invoker.send(
                    method: plan.method,
                    url: url,
                    body: body,
                    headers: headers
                )
                results.append(CallbackDispatchResult(plan: plan, statusCode: status, error: nil))
            } catch {
                results.append(CallbackDispatchResult(
                    plan: plan,
                    statusCode: nil,
                    error: String(describing: error)
                ))
            }
        }
        return results
    }
}

// MARK: - Invoker Seam

/// The HTTP seam used by ``OpenAPICallbackDispatcher`` to send out-of-band
/// callback requests.
///
/// Keeping the network behind this protocol lets the dispatch logic be
/// exercised with a recording mock in tests, and lets the runtime swap in the
/// production ``AROHTTPClient`` adapter (or disable outbound callbacks entirely
/// by leaving the seam unset).
public protocol CallbackHTTPInvoker: Sendable {
    /// Send one out-of-band callback request.
    /// - Returns: The HTTP status code reported by the receiver.
    func send(
        method: String,
        url: String,
        body: Data?,
        headers: [String: String]
    ) async throws -> Int
}
