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

        guard !ComputeQualifierCatalog.isUncheckable(qualifier) else { return }
        guard !ComputeQualifierCatalog.isBuiltIn(qualifier) else { return }

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

        diagnostics.error(
            "Unknown Compute qualifier '\(qualifier)'",
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
