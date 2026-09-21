// ============================================================
// StatementModifiers.swift
// ARO Runtime - Statement modifiers as framework variables
// ============================================================
//
// A statement carries more than an action, a result and an object: a literal,
// a `where` predicate, a `by` clause, `matching`, `to`, `with`, `against`, a
// default, a sink expression. Actions read these through `_`-prefixed
// framework variables in the statement's own scope (ARO-0088 §2), and binding
// them was a dozen consecutive blocks in the middle of `executeAROStatement`.
//
// Collected here so that method is about executing a statement, and so the
// set of names an action may read is in one readable place. The names
// themselves are swept by `FrameworkVariables.transientKeys`, which the
// compiled path shares.

import Foundation
import AROParser

enum StatementModifiers {
    /// Bind every modifier the statement carries into its statement scope.
    ///
    /// Value expressions are evaluated here rather than by the action, so a
    /// `where`, `by` or `matching` clause can read local variables.
    static func bind(
        _ statement: AROStatement,
        into context: ExecutionContext,
        evaluator: ExpressionEvaluator
    ) async throws {
        // Bind literal value if present (e.g., "Hello, World!" in the statement)
        if case .literal(let literal) = statement.valueSource {
            context.bind("_literal_", value: value(of: literal))
        }

        // ARO-0018: Bind aggregation clause if present
        if let aggregation = statement.queryModifiers.aggregation {
            context.bind("_aggregation_type_", value: aggregation.type.rawValue)
            if let field = aggregation.field {
                context.bind("_aggregation_field_", value: field)
            }
        }

        // ARO-0018: Bind where clause if present
        if let whereCondition = statement.queryModifiers.whereCondition {
            if let single = whereCondition.singlePredicate {
                // Single predicate keeps the historical triple, which every
                // consumer (Filter, Retrieve, Delete, plugins) understands.
                context.bind("_where_field_", value: single.field)
                context.bind("_where_op_", value: single.op.rawValue)
                // Evaluate the where value expression
                let whereValue = try await evaluator.evaluate(single.value, context: context)
                context.bind("_where_value_", value: whereValue)
            } else {
                // Compound condition (GitLab #498): numbered triples plus a
                // structure skeleton like "and(0,or(1,2))". The runtime's
                // ResolvedWhereCondition reassembles the tree from these.
                // Value expressions are evaluated here, in statement scope,
                // so predicates can reference local variables.
                for (index, predicate) in whereCondition.predicates.enumerated() {
                    context.bind("_where_field_\(index)_", value: predicate.field)
                    context.bind("_where_op_\(index)_", value: predicate.op.rawValue)
                    let value = try await evaluator.evaluate(predicate.value, context: context)
                    context.bind("_where_value_\(index)_", value: value)
                }
                context.bind("_where_tree_", value: whereCondition.treeSkeleton)
            }
        }

        // ARO-0037: Bind by clause if present (for Split and Group actions)
        if let byClause = statement.queryModifiers.byClause {
            // `by <var>` form — resolve the variable now; whatever string
            // it holds becomes the pattern. Falls back to the literal in
            // byClause.pattern if the variable is missing or non-string.
            if let varName = byClause.variableName,
               let resolved = context.resolveAny(varName) as? String {
                context.bind("_by_pattern_", value: resolved)
            } else {
                context.bind("_by_pattern_", value: byClause.pattern)
            }
            context.bind("_by_flags_", value: byClause.flags)
            if byClause.isFieldName {
                context.bind("_by_field_", value: byClause.pattern)
            }
            // `by <var>` — hand the action the NAME too (GitLab #491):
            // Sort treats an unresolvable name as the field itself, so
            // `Sort … by <score>` (ARO-0002 §Ordering) means the score
            // field, while a bound string variable still drives it.
            if let varName = byClause.variableName {
                context.bind("_by_var_", value: varName)
            }
            if let order = byClause.order {
                context.bind("_by_order_", value: order)
            }
        }

        // ARO-0072: Bind default value if present (for optional retrieve)
        if let defaultExpr = statement.queryModifiers.defaultValue {
            let defaultVal = try await evaluator.evaluate(defaultExpr, context: context)
            context.bind("_default_value_", value: defaultVal)
        }

        // ARO-0036: Bind the listing glob and recursion flag (GitLab #518).
        // The pattern is an expression so `matching <pattern>` can read the
        // glob out of a variable; it is evaluated here, in statement scope.
        if let matchingExpr = statement.queryModifiers.matchingPattern {
            let pattern = try await evaluator.evaluate(matchingExpr, context: context)
            context.bind("_matching_", value: String(describing: pattern))
        }
        if statement.queryModifiers.recursive {
            // A string, not a Bool: the compiled path binds framework
            // variables through variableBindString, and one representation
            // means one check in ListAction.
            context.bind("_recursive_", value: "true")
        }

        // ARO-0041: Bind to clause if present (for date ranges)
        if let toClause = statement.rangeModifiers.toClause {
            let toValue = try await evaluator.evaluate(toClause, context: context)
            context.bind("_to_", value: toValue)
        }

        // ARO-0042: Bind with clause if present (for set operations)
        if let withClause = statement.rangeModifiers.withClause {
            let withValue = try await evaluator.evaluate(withClause, context: context)
            context.bind("_with_", value: withValue)
        }

        // GitLab #469: Compare's right-hand operand.
        if let againstClause = statement.rangeModifiers.againstClause {
            let againstValue = try await evaluator.evaluate(againstClause, context: context)
            context.bind("_against_", value: againstValue)
        }

        // ARO-0043: Evaluate result expression if present (for sink syntax)
        // Sink syntax: <Log> "message" to the <console>.
        if case .sinkExpression(let resultExpression) = statement.valueSource {
            let resultValue = try await evaluator.evaluate(resultExpression, context: context)
            context.bind("_result_expression_", value: resultValue)
        }
    }

    /// A parsed literal as the runtime value actions see.
    static func value(of literal: LiteralValue) -> any Sendable {
        switch literal {
        case .string(let s): return s
        case .integer(let i): return i
        case .float(let f): return f
        case .boolean(let b): return b
        case .null: return ""
        case .array(let elements): return array(of: elements)
        case .object(let fields): return object(of: fields)
        case .regex(let pattern, let flags): return ["pattern": pattern, "flags": flags]
        }
    }

    /// Convert an array of LiteralValues to a runtime array
    static func array(of elements: [LiteralValue]) -> [any Sendable] {
        elements.map { value(of: $0) }
    }

    /// Convert object fields to a runtime dictionary
    static func object(of fields: [(String, LiteralValue)]) -> [String: any Sendable] {
        var dict: [String: any Sendable] = [:]
        for (key, field) in fields {
            dict[key] = value(of: field)
        }
        return dict
    }
}
