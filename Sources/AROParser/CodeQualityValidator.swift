// ============================================================
// CodeQualityValidator.swift
// ARO Parser - Code Quality Checks
// ============================================================

import Foundation

// MARK: - Code Quality Validator

/// Checks for code quality issues: empty feature sets, unreachable code, missing returns
public struct CodeQualityValidator {

    private let diagnostics: DiagnosticCollector

    public init(diagnostics: DiagnosticCollector) {
        self.diagnostics = diagnostics
    }

    /// Checks for code quality issues in a feature set
    public func validate(_ featureSet: FeatureSet) {
        let statements = featureSet.statements

        // GitLab #479: prepositions are part of an action's contract, and the
        // constraint is decidable from the AST. Checked over the whole statement
        // tree so guarded statements, match cases and loop bodies are covered too.
        validatePrepositions(in: statements)

        // Check for empty feature set
        if statements.isEmpty {
            diagnostics.warning(
                "Feature set '\(featureSet.name)' has no statements",
                at: featureSet.span.start,
                hints: ["Add statements or remove this empty feature set"]
            )
            return
        }

        // Check for unreachable code after Return/Throw (ARO-0062)
        var foundTerminator = false
        var terminatorLocation: SourceLocation?

        for statement in statements {
            if foundTerminator {
                diagnostics.warning(
                    "Unreachable code after Return/Throw statement",
                    at: statement.span.start,
                    hints: [
                        "This code will never execute",
                        "The Return/Throw at line \(terminatorLocation?.line ?? 0) exits the feature set"
                    ]
                )
                break  // Only report once
            }

            if let aro = statement.asAROStatement {
                let verb = aro.action.verb.lowercased()
                // Only terminal if unconditional (no when guard) - ARO-0062
                let isTerminal = (verb == "return" || verb == "throw") &&
                                 !aro.statementGuard.isPresent
                if isTerminal {
                    foundTerminator = true
                    terminatorLocation = aro.span.start
                }
            }
        }

        // Check for missing Return statement (excluding Application-End handlers)
        let activity = featureSet.businessActivity
        let isLifecycleHandler = activity.hasPrefix("Application-End")

        if !isLifecycleHandler && !foundTerminator {
            let hasAnyReturn = statements.contains { stmt in
                if let aro = stmt.asAROStatement {
                    let verb = aro.action.verb.lowercased()
                    return verb == "return" || verb == "throw"
                }
                return false
            }

            if !hasAnyReturn {
                diagnostics.warning(
                    "Feature set '\(featureSet.name)' has no Return or Throw statement",
                    at: featureSet.span.end,
                    hints: [
                        "Feature sets should end with a Return statement",
                        "Add: <Return> an <OK: status> for the <result>."
                    ]
                )
            }
        }
    }
    // MARK: - Preposition Validation (GitLab #479)

    /// Reports statements whose preposition the action does not accept.
    ///
    /// Silent before this check: a one-word mistake compiled clean and failed at
    /// run time with a message that never mentioned the preposition, so the user
    /// went looking at the wrong thing entirely.
    ///
    /// Only built-in verbs are checked. `PrepositionCatalog` returns nil for
    /// plugin and `Application.<Name>` actions, whose prepositions are known only
    /// at run time, and nil is treated as "cannot check" rather than "invalid".
    private func validatePrepositions(in statements: [Statement]) {
        for aro in collectAROStatements(statements) {
            let verb = aro.action.verb
            guard let accepted = PrepositionCatalog.prepositions(forVerb: verb) else { continue }

            let preposition = aro.object.preposition
            guard !accepted.contains(preposition) else { continue }

            var hints = ["Valid prepositions for \(verb): \(PrepositionCatalog.hintList(forVerb: verb))"]
            if let closest = accepted.sorted(by: { $0.rawValue < $1.rawValue }).first {
                hints.append(
                    "Did you mean: \(verb) the <\(aro.result.base)> \(closest.rawValue) the <\(aro.object.noun.base)>."
                )
            }

            // Reported as a warning, not an error, though #479 asked for an error.
            //
            // Some statements never dispatch their action: FeatureSetExecutor's
            // `!needsExecution` fast path binds the expression value directly, so
            // the action's `validatePreposition` never runs. `Make the <value>
            // with "first".` therefore *works today* even though MakeAction
            // accepts only to/for/at — it works by accident, but it works, and it
            // appears in the existing test suite. Erroring would break running
            // programs for a spelling the runtime currently tolerates.
            //
            // Whether the fast path should honour the contract is a separate
            // question; once it does, or once such spellings are cleaned up, this
            // can be promoted to an error.
            diagnostics.warning(
                "Action '\(verb)' does not accept the preposition '\(preposition.rawValue)'",
                at: aro.object.noun.span.start,
                hints: hints
            )
        }
    }

    /// Flattens the statement tree, descending into match cases and loop bodies.
    /// Mirrors `DataFlowAnalyzer.collectAROStatements`.
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
