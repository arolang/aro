// ============================================================
// JoinAction.swift
// ARO Runtime - Join Action Implementation (ARO-0072)
// ============================================================

import Foundation
import AROParser

/// Joins a collection of values into a single string with a separator.
/// Syntax: Join the <result> from <collection> with "separator".
/// Uses expression-mode object (no article): object is resolved via _expression_,
/// and the 'with' clause binds the separator to _with_.
public struct JoinAction: ActionImplementation {
    public static let role: ActionRole = .own
    public static let verbs: Set<String> = ["join"]
    public static let validPrepositions: Set<Preposition> = [.from]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        // Resolve the collection — either from named variable or _expression_
        let raw: any Sendable
        if object.base == "_expression_" {
            guard let val = context.resolveAny("_expression_") else {
                throw ActionError.undefinedVariable("collection")
            }
            raw = val
        } else {
            guard let val = context.resolveAny(object.base) else {
                throw ActionError.undefinedVariable(object.base)
            }
            raw = val
        }

        // Get separator from _with_ (set by rangeModifiers.withClause when expression-mode)
        // or from the standard expression binding when named-object mode
        let separator: String
        if let sep = context.resolveAny("_with_") as? String {
            separator = sep
        } else if let sep = context.resolveAny("_expression_") as? String, object.base != "_expression_" {
            // named object mode: _expression_ holds the 'with' value
            separator = sep
        } else {
            separator = ""
        }

        // Convert collection to array of strings
        let strings: [String]
        if let arr = raw as? [any Sendable] {
            strings = arr.map { "\($0)" }
        } else if let arr = raw as? [[String: any Sendable]] {
            strings = arr.map { dict in
                if let val = dict.values.first { return "\(val)" }
                return ""
            }
        } else {
            // Single value — just return it as-is
            let joined = "\(raw)"
            context.bind(result.base, value: joined)
            return joined
        }

        let joined = strings.joined(separator: separator)
        context.bind(result.base, value: joined)
        return joined
    }
}
