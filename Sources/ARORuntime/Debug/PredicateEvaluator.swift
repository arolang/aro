// ============================================================
// PredicateEvaluator.swift
// ARO Runtime - Conditional breakpoint predicate evaluator (#230)
// ============================================================
//
// Issue #230 — replaces the hand-rolled `==` / `!=` / `&&` / `||` string
// matcher that shipped with #229 Phase 3. Conditional breakpoint
// predicates now go through the same `Lexer → Parser → ExpressionEvaluator`
// pipeline that ARO statements use, so any valid ARO expression works:
//
//   b 5 if <user: id> == 530
//   b 7 if <count> > 100 && <user: role> == "admin"
//   b 9 if <users-repository: count> > <limit>
//
// The fallback evaluator (snapshot-string matching) is preserved for the
// rare path where checkpoint() is called without a live `ExecutionContext`
// — that path stays bug-compatible with the original #229 release.

import Foundation
import AROParser

enum PredicateEvaluator {

    /// Parse `source` as an ARO expression and evaluate it against
    /// `context`. Returns `false` on parse error or evaluation failure
    /// — debugger predicates should never crash the program.
    static func evaluate(_ source: String, context: ExecutionContext) async -> Bool {
        guard let value = await self.value(source, context: context) else { return false }
        return asBool(value)
    }

    /// Parse `source` as an ARO expression and evaluate it against `context`,
    /// returning the **value**.
    ///
    /// `evaluate` answers a conditional breakpoint, which only needs
    /// truthiness. A *watch* needs the value itself, and resolving one by
    /// exact-matching `<name>` against the pause snapshot could never handle a
    /// qualifier: a snapshot entry's `name` is the bare binding, so
    /// `<user: id>` and `<users-repository: count>` printed `(unresolved)`
    /// forever, with no diagnostic (GitLab #567). Sharing this pipeline means
    /// a watch accepts exactly what a conditional breakpoint already does.
    ///
    /// `nil` on parse or evaluation failure — a debugger expression must never
    /// crash the program it is observing.
    static func value(_ source: String, context: ExecutionContext) async -> (any Sendable)? {
        // Parse once per call. A future optimization caches the AST on
        // the `.conditionalLocation` enum case, but caching across actor
        // calls needs a stable identity for the breakpoint and is a
        // separate optimization.
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let tokens: [Token]
        do {
            let lexer = Lexer(source: trimmed)
            tokens = try lexer.tokenize()
        } catch {
            return nil
        }

        let expression: any AROParser.Expression
        do {
            let parser = Parser(tokens: tokens)
            expression = try parser.parseExpression()
        } catch {
            return nil
        }

        do {
            return try await ExpressionEvaluator().evaluate(expression, context: context)
        } catch {
            return nil
        }
    }

    /// Match the truthy semantics used elsewhere in the runtime
    /// (`FeatureSetExecutor.asBool`). Kept local so this file does not
    /// reach into the executor.
    private static func asBool(_ value: any Sendable) -> Bool {
        if let b = value as? Bool { return b }
        if let i = value as? Int { return i != 0 }
        if let d = value as? Double { return d != 0 }
        if let s = value as? String { return !s.isEmpty && s.lowercased() != "false" && s != "0" }
        if let arr = value as? [Any] { return !arr.isEmpty }
        if let dict = value as? [String: Any] { return !dict.isEmpty }
        return false
    }
}
