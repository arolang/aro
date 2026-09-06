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
        }
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
        diagnostics.error(
            "Unknown Compute qualifier '\(qualifier)'\(context)",
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

    /// Flattens the statement tree, descending into match cases and loop
    /// bodies. Mirrors `CodeQualityValidator.collectAROStatements`.
    private func collectAROStatements(_ statements: [Statement]) -> [AROStatement] {
        var result: [AROStatement] = []
        for statement in statements {
            if let aro = statement as? AROStatement {
                result.append(aro)
            } else if let match = statement as? MatchStatement {
                for matchCase in match.cases {
                    result.append(contentsOf: collectAROStatements(matchCase.body))
                }
                result.append(contentsOf: collectAROStatements(match.otherwise ?? []))
            } else if let loop = statement as? ForEachLoop {
                result.append(contentsOf: collectAROStatements(loop.body))
            }
        }
        return result
    }
}
