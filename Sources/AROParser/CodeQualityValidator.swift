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

            if let aro = statement as? AROStatement {
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
                if let aro = stmt as? AROStatement {
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
}
