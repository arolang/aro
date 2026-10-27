// ============================================================
// CollectionOpValidator.swift
// AROParser — collection operations that only look like they work
// ============================================================
//
// GitLab #465. Four spellings passed `aro check` with exit 0 and
// then did the wrong thing:
//
//     Compute the <s: sort> from the <x>.        → unsorted list
//     Compute the <r: reverse> from the <x>.     → unchanged list
//     Compute the <t: first> from the <x> with 3. → whole list
//     Map the <d> from the <x> with <item> * 0.9. → Undefined variable: item
//
// The first three now throw at run time (GitLab #486 closed the
// qualifier namespace), which turned a wrong answer into a crash —
// better, but still only found by running the program. The fourth
// never worked in any mode: MapAction reads `result.specifiers`
// and nothing else, so every `with` value it is handed is
// discarded, and an expression naming a per-element variable dies
// looking that variable up.
//
// Both are decidable from the AST, so they are decided here. The
// bar for erroring is that the statement cannot succeed at run
// time under any binding — anything the analyser merely cannot
// verify (plugin qualifiers, chains that mention one) is left
// alone; see `ComputeQualifierCatalog.isUncheckable`.

import Foundation

/// Rejects collection statements whose written form cannot run.
public struct CollectionOpValidator {

    private let diagnostics: DiagnosticCollector

    public init(diagnostics: DiagnosticCollector) {
        self.diagnostics = diagnostics
    }

    public func validate(_ featureSet: FeatureSet) {
        for aro in collectAROStatements(featureSet.statements) {
            validateComputeQualifier(aro)
            validateMapWithClause(aro)
            validateSplitWithClause(aro)
            validateDeleteWhereCondition(aro)
            validateListModifiers(aro)
        }
    }

    // MARK: - List modifiers

    /// Verbs that read `matching` / `recursively` (ARO-0036 §6).
    private static let listVerbs: Set<String> = ["list"]

    /// Errors when `matching` or `recursively` sits on a verb that never
    /// reads it (GitLab #518).
    ///
    /// Both are directory-listing clauses: `ListAction` is the only action
    /// that binds them. Anywhere else the runtime would bind the framework
    /// variable, the action would ignore it, and the statement would return
    /// the *unfiltered* value — the exact silent-wrong-answer shape this
    /// validator exists to stop.
    private func validateListModifiers(_ statement: AROStatement) {
        let verb = statement.action.verb
        guard !Self.listVerbs.contains(verb.lowercased()) else { return }

        let result = statement.result.base
        let source = statement.object.noun.base

        if statement.queryModifiers.matchingPattern != nil {
            diagnostics.error(
                "'matching' is a List clause — \(verb) ignores it",
                at: statement.span.start,
                hints: [
                    "Filter the listing at the source: List the <\(result)> from the <directory: \(source)> matching \"*.csv\".",
                    "To filter a collection by a field, use where: Filter the <\(result)> from the <\(source)> where <status> is \"open\".",
                ]
            )
        }

        if statement.queryModifiers.recursive {
            diagnostics.error(
                "'recursively' is a List clause — \(verb) ignores it",
                at: statement.span.start,
                hints: [
                    "List the <\(result)> from the <directory: \(source)> recursively. (ARO-0036 §6.3)",
                ]
            )
        }
    }

    // MARK: - Delete where-conditions

    /// Errors when a delete verb carries a compound where condition.
    ///
    /// Repository deletes go through storage's field-equals API, which
    /// takes exactly one field/value pair. A compound condition
    /// (`where <a> is 1 and <b> is 2`, GitLab #498) has no runtime
    /// path there — worse, before this check the runtime treated the
    /// unrecognized shape as "no where clause" and `Delete … from the
    /// <x-repository>` with no where CLEARS THE WHOLE REPOSITORY. So
    /// the shape is rejected here, where it can still name the fix.
    ///
    /// GitLab #721: the verb set is a `static let` because this runs once per
    /// ARO statement and the set was built *before* the guard that rejects
    /// almost every one of them — so a four-element Set was allocated and torn
    /// down per statement to answer "is this a delete?" with "no".
    private static let deleteVerbs: Set<String> = ["delete", "remove", "destroy", "clear"]

    private func validateDeleteWhereCondition(_ statement: AROStatement) {
        guard Self.deleteVerbs.contains(statement.action.verb.lowercased()) else { return }
        guard let condition = statement.queryModifiers.whereCondition,
              condition.singlePredicate == nil else { return }

        diagnostics.error(
            "Delete supports a single where predicate — and/or chaining is not available for repository deletes",
            at: condition.span.start,
            hints: [
                "Chain deletes: one Delete statement per predicate (AND semantics).",
                "Or Filter what should remain and Store it back.",
            ]
        )
    }

    // MARK: - Compute qualifiers

    /// Errors when an explicit Compute qualifier names nothing.
    ///
    /// Mirrors the run-time resolution order in
    /// `ComputeAction.executeSynchronously` exactly: chain, plugin
    /// registry, date offset, built-in table, throw. Everything the
    /// runtime would accept is accepted here, and the one thing it
    /// throws on is the one thing reported.
    private func validateComputeQualifier(_ statement: AROStatement) {
        // Compute verbs only.
        //
        // Extending this to `Log` looked right — it runs the same qualifier
        // registry — and is wrong: `Log`'s qualifier slot is overloaded.
        // `Log the <metrics: short>` selects a *metrics format* (ARO-0044),
        // `<template: raw>` is an escaping directive (GitLab #476), and
        // neither is in the Compute table. Checking Log against that table
        // rejects `Examples/MetricsDemo`, which is correct ARO.
        //
        // The runtime half of GitLab #648 stands: an unknown qualifier that
        // reaches the registry now throws instead of warning to stderr. Giving
        // `Log` a check-time equivalent needs a catalog of *its* qualifier
        // namespaces first, which is its own piece of work.
        guard ComputeQualifierCatalog.computeVerbs.contains(statement.action.verb.lowercased()) else {
            return
        }

        let result = statement.result

        // A quoted qualifier is a value, not an operation
        // (`<file: "data.json">`), and never reaches the qualifier
        // table.
        guard !result.isLiteralQualifier else { return }

        // No explicit qualifier resolves to `identity`, which is
        // registered — so plain `Compute the <total> from <a> + <b>.`
        // is not this check's business.
        guard let qualifier = result.typeAnnotation, !qualifier.isEmpty else { return }

        // A chain (`a|b`, ARO-0019 §3.3) is judged stage by stage
        // (GitLab #492): each stage follows the same rules as a lone
        // qualifier, so `trim|bogus` is rejected here naming `bogus`,
        // while `stats.sort|take` stays accepted — the namespaced
        // stage is unknowable without loading plugins, and `take` is
        // a built-in.
        if let stages = ComputeQualifierCatalog.chainStages(qualifier) {
            if stages.contains("") {
                diagnostics.error(
                    "Empty stage in Compute qualifier chain '\(qualifier)'",
                    at: result.span.start,
                    hints: ["Every '|' needs a qualifier on both sides, "
                          + "e.g. <\(result.base): trim|uppercase>"]
                )
                return
            }
            for stage in stages {
                guard !ComputeQualifierCatalog.isUncheckable(stage),
                      !ComputeQualifierCatalog.isBuiltIn(stage) else { continue }
                reportUnknownQualifier(stage, chain: qualifier, statement: statement)
            }
            return
        }

        guard !ComputeQualifierCatalog.isUncheckable(qualifier) else { return }
        guard !ComputeQualifierCatalog.isBuiltIn(qualifier) else { return }

        reportUnknownQualifier(qualifier, chain: nil, statement: statement)
    }

    /// Emits the unknown-qualifier diagnostic, for a lone qualifier or
    /// for one stage of a chain.
    private func reportUnknownQualifier(
        _ qualifier: String,
        chain: String?,
        statement: AROStatement
    ) {
        let result = statement.result

        var hints: [String] = []
        if let redirect = ComputeQualifierCatalog.redirect(
            for: qualifier,
            result: result.base,
            object: statement.object.noun.base)
        {
            hints.append(redirect)
        }
        let near = ComputeQualifierCatalog.closestBuiltIns(to: qualifier)
        if !near.isEmpty {
            hints.append("Closest built-ins: \(near.joined(separator: ", "))")
        }
        hints.append("Plugin qualifiers are namespaced: <\(result.base): handle.\(qualifier)>")
        hints.append("Run `aro actions --qualifiers` for the full set")

        let context = chain.map { " (stage of the chain '\($0)')" } ?? ""
        // Named for the verb that wrote it rather than always "Compute":
        // `Calculate` and `Derive` dispatch to the same action, and a
        // diagnostic that names a verb the source does not contain reads as
        // being about a different statement.
        let verb = statement.action.verb.prefix(1).uppercased()
                 + statement.action.verb.dropFirst().lowercased()
        diagnostics.error(
            "Unknown \(verb) qualifier '\(qualifier)'\(context)",
            at: result.span.start,
            hints: hints
        )
    }

    // MARK: - Map with-clauses

    /// Errors when `Map … with <expression>` carries a value.
    ///
    /// `MapAction` has exactly two inputs: the source collection and an
    /// optional field name taken from the result specifier. It never
    /// reads `_with_`. So `with 3`, `with <config>` and
    /// `with <item> * 0.9` are all discarded — the first two silently,
    /// the third after the expression evaluator fails to find `item`.
    ///
    /// The field-projection spelling `with name` is not affected: the
    /// parser rewrites it into `<result: name>` before this runs
    /// (GitLab #465, commit 6085f362), so its with-clause is already
    /// gone by the time the AST reaches the analyser.
    private func validateMapWithClause(_ statement: AROStatement) {
        guard statement.action.verb.lowercased() == "map" else { return }
        guard statement.rangeModifiers.withClause != nil else { return }

        let result = statement.result.base
        let source = statement.object.noun.base

        diagnostics.error(
            "Map ignores its 'with' value — there is no per-element binding",
            at: statement.span.start,
            hints: [
                "Project a field: Map the <\(result)> from the <\(source)> with fieldName.",
                "Or on the result: Map the <\(result): fieldName> from the <\(source)>.",
                "To compute per element, iterate: for each <item> in <\(source)> { … }",
            ]
        )
    }

    /// Errors when Split is handed its delimiter through `with`
    /// (GitLab #513).
    ///
    /// The delimiter goes after `by` (ARO-0037): a string, a variable,
    /// or a /regex/. But `with` is the payload preposition everywhere
    /// else in the language, so it is the first thing people try — and
    /// it used to parse, run, and fail at runtime with "Cannot split",
    /// long after the mistake was made. Reject it where the mistake
    /// is, naming the spelling that works.
    private func validateSplitWithClause(_ statement: AROStatement) {
        guard statement.action.verb.lowercased() == "split" else { return }
        guard statement.rangeModifiers.withClause != nil else { return }
        guard statement.queryModifiers.byClause == nil else { return }

        let result = statement.result.base

        diagnostics.error(
            "Split takes its delimiter after 'by', not 'with'",
            at: statement.span.start,
            hints: [
                "Split the <\(result)> from <text> by \",\".",
                "A variable or /regex/ works too: by <delimiter>, by /,\\s*/ (ARO-0037).",
            ]
        )
    }

    // MARK: - Traversal

    /// The shared walk (GitLab #660). This used to be a private copy that
    /// descended into `match` and `for each` only — so an unknown Compute
    /// qualifier inside a `while` body or a `when { }` block passed
    /// `aro check` green, and the promise that a green check means the
    /// qualifier exists held only at the top level of a feature set.
    private func collectAROStatements(_ statements: [Statement]) -> [AROStatement] {
        AROStatementWalk.flatten(statements)
    }
}
