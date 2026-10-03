// ============================================================
// ReturnAction.swift
// ARO Runtime - Return: the response a feature set answers with
// ============================================================

import Foundation
import AROParser

/// Returns a response from a feature set
///
/// The Return action is a RESPONSE action that sets the output of the
/// current feature set execution. It terminates the execution flow.
///
/// ## Example
/// ```
/// <Return> an <OK: status> for a <valid: authentication>.
/// ```
public struct ReturnAction: SynchronousAction {
    public static let role: ActionRole = .response
    public static let verbs: Set<String> = ["return", "respond"]
    public static let validPrepositions: Set<Preposition> = [.for, .to, .with]

    public init() {}

    public func executeSynchronously(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) throws -> any Sendable {
        try validatePreposition(object.preposition)

        let statusName = result.base
        let reason = object.base

        // The payload, in the shape the program produced it.
        //
        // This used to be built twice: once here, flattened for transport
        // (nested records spread into dot-notation keys, collections replaced
        // by their JSON text), and once as a structured copy for in-process
        // callers (GitLab #504). Every response paid for the flattening, and
        // the HTTP renderer then parsed the collections it had just serialised
        // back out again (GitLab #711). The payload is recorded once;
        // `Response.data` renders the flat form for the boundaries that still
        // want it.
        var payload: [String: any Sendable] = [:]

        // Check for expression from "with" clause (e.g., with { user: <user>, ... } or with <variable>)
        // Note: When with clause contains variable references, it's parsed as expression
        if let expr = context.resolveAny("_expression_") {
            if let dict = expr as? [String: any Sendable] {
                // Map literal: { key: value, ... } - preserve nested structure
                for (key, value) in dict {
                    payload[key] = value
                }
            } else if let array = expr as? [any Sendable] {
                // A returned collection is carried as a collection. It used to
                // become JSON text here, under the key the flat form gives it.
                payload["data"] = array
            } else if let str = expr as? String {
                // A string is a string (GitLab #637).
                //
                // This used to hand every returned string to
                // `JSONSerialization` and, if it happened to parse as an
                // object, spread its keys across the top level of the
                // response. So returning a user-supplied text field that
                // contained `{"a":1}` changed the response *shape* — the type
                // of the response depended on the content of a value, which no
                // contract can describe and no client can rely on. Every plain
                // string also paid for a parse attempt on the way out.
                //
                // A program that means to return structured data has ways to
                // say so: an object literal, or `Parse` the string first.
                payload["value"] = str
            } else if let body = expr as? RequestBodyValue {  // live body: streams back out
                // Returning an unread request body writes it straight back to
                // the client, chunk by chunk (GitLab #477). Carried through the
                // response as itself; `Application.convertToHTTPResponse` turns
                // it into a chunked body without ever holding the whole.
                payload["value"] = body
            } else if let anchored = expr as? AnchoredBody {
                // Same for a body that has been anchored: the response is
                // written from the file rather than from memory.
                payload["value"] = anchored
            } else if let int = expr as? Int {
                payload["value"] = int
            } else if let double = expr as? Double {
                payload["value"] = double
            } else if let bool = expr as? Bool {
                payload["value"] = bool
            }
        }

        // Check for object literal from "with" clause (for simple literals without var refs)
        if let literal = context.resolveAny("_literal_") {
            if let dict = literal as? [String: any Sendable] {
                for (key, value) in dict {
                    payload[key] = value
                }
            }
        }

        // Include object.base value if resolvable (skip internal names already handled above)
        let internalNames: Set<String> = ["_expression_", "_literal_", "status", "response", "application"]
        // ARO-0044: Special handling for metrics magic variable with format qualifier
        // Return an <OK: status> with <metrics: prometheus/plain/short/table>
        if object.base == "metrics",
           let metricsSnapshot = context.resolveAny("metrics") as? MetricsSnapshot {
            let format = object.specifiers.first ?? "plain"
            let formatted = MetricsFormatter.format(metricsSnapshot, as: format, context: context.outputContext)
            payload["value"] = formatted
        } else if !internalNames.contains(object.base), let value = context.resolveAny(object.base) {
            payload[object.base] = value
        }

        // Include object specifiers as data references (skip internal names)
        for specifier in object.specifiers where !internalNames.contains(specifier) {
            if let value = context.resolveAny(specifier) {
                payload[specifier] = value
            }
        }

        // A `Return` with nothing to return returns nothing (GitLab #636).
        //
        // There used to be a fallback here: if `data` came out empty, it
        // searched the context for `greeting`, `message`, `result`, `data`,
        // `output` or `value` and put the first one it found in the response.
        // `resolveAny` walks parent scopes, so
        // `Return an <OK: status> for the <health-check>.` in a handler that
        // happened to have — or inherit — a local called `<message>` shipped
        // that value in the HTTP body. The response shape depended on which
        // unrelated names existed in scope, which is not a shape anyone can
        // write a contract against.
        //
        // The comment justifying it said this "matches compiled binary
        // behavior". It did, for a circular reason: a compiled binary calls
        // this same action through `aro_action_return`, so both modes leaked
        // identically and parity tests could not see it. Removing it here
        // removes it from both.

        let response = Response(
            status: statusName,
            reason: reason,
            payload: payload
        )

        context.setResponse(response)
        return response
    }
}
