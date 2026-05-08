// ============================================================
// UserActionAnalyzer.swift
// AROParser - Validation passes for user-defined actions (ARO-0081)
// ============================================================
//
// This validator runs alongside the data-flow analyzer to:
//   1. Discover every `Action` feature set and build a UserActionRegistry.
//   2. Detect duplicate action names across the application.
//   3. Detect `Application.<Name>` calls that do not resolve to a known action.
//   4. Detect `from <value>` sugar against an action without a `takes` clause.
//   5. Detect framework-variable access (`<request>`, `<event>`, …) inside an
//      Action body, which is not allowed because actions are synchronous and
//      have no event/request context.

import Foundation

public final class UserActionAnalyzer {
    private let diagnostics: DiagnosticCollector

    public init(diagnostics: DiagnosticCollector) {
        self.diagnostics = diagnostics
    }

    // MARK: - Registry Construction

    /// Walk the program and build a `UserActionRegistry` keyed by action name.
    /// Emits a duplicate-name diagnostic when two `Action` feature sets share
    /// the same name; the first declaration wins (later ones are skipped).
    public func buildRegistry(_ featureSets: [FeatureSet]) -> UserActionRegistry {
        var actions: [String: UserActionInfo] = [:]

        for fs in featureSets where fs.isUserAction {
            if let existing = actions[fs.name] {
                diagnostics.error(
                    "Duplicate user-defined action 'Application.\(fs.name)'",
                    at: fs.span.start,
                    hints: [
                        "An action with this name was already declared at line \(existing.span.start.line)",
                        "User-defined action names are unique application-wide",
                    ]
                )
                continue
            }

            actions[fs.name] = UserActionInfo(
                name: fs.name,
                takesField: fs.userActionTakesField,
                takesType: fs.userActionTakesType,
                span: fs.span
            )
        }

        return UserActionRegistry(actions: actions)
    }

    // MARK: - Call-Site Validation

    /// Walk every statement in every feature set and check `Application.<Name>`
    /// calls against the registry. Also enforces the body restrictions for
    /// Action feature sets (no framework variables).
    public func validateCalls(in featureSets: [FeatureSet], registry: UserActionRegistry) {
        for fs in featureSets {
            let isInsideAction = fs.isUserAction
            visit(fs.statements, isInsideAction: isInsideAction, registry: registry)
        }
    }

    private func visit(_ statements: [Statement], isInsideAction: Bool, registry: UserActionRegistry) {
        for statement in statements {
            switch statement {
            case let aro as AROStatement:
                validateApplicationCall(aro, registry: registry)
                if isInsideAction {
                    validateNoFrameworkVariables(aro)
                }
            case let pipeline as PipelineStatement:
                for stage in pipeline.stages {
                    validateApplicationCall(stage, registry: registry)
                    if isInsideAction {
                        validateNoFrameworkVariables(stage)
                    }
                }
            case let forEach as ForEachLoop:
                visit(forEach.body, isInsideAction: isInsideAction, registry: registry)
            case let rangeLoop as RangeLoop:
                visit(rangeLoop.body, isInsideAction: isInsideAction, registry: registry)
            case let whileLoop as WhileLoop:
                visit(whileLoop.body, isInsideAction: isInsideAction, registry: registry)
            case let match as MatchStatement:
                for clause in match.cases {
                    visit(clause.body, isInsideAction: isInsideAction, registry: registry)
                }
            default:
                break
            }
        }
    }

    /// Validate an `Application.<Name>` call. Non-Application calls fall through.
    private func validateApplicationCall(_ statement: AROStatement, registry: UserActionRegistry) {
        let verb = statement.action.verb
        guard let actionName = UserActionRegistry.actionName(fromCallVerb: verb) else { return }

        guard let info = registry.info(for: actionName) else {
            let known = registry.allNames
            var hints: [String] = []
            if !known.isEmpty {
                hints.append("Known user-defined actions: " + known.map { "Application.\($0)" }.joined(separator: ", "))
            } else {
                hints.append("No user-defined actions are declared in this application")
                hints.append("Declare one with `(MyAction: Action) { ... }`")
            }
            diagnostics.error(
                "Unknown user-defined action 'Application.\(actionName)'",
                at: statement.action.span.start,
                hints: hints
            )
            return
        }

        // `from <value>` is only valid when the callee declares `takes <field>`.
        // The parser folds `from <value>` into preposition `.from` plus an
        // expression (object base = `_expression_`) or a literal (object base = `_literal_`).
        if statement.object.preposition == .from && info.takesField == nil {
            diagnostics.error(
                "Cannot call 'Application.\(actionName)' with `from <value>`",
                at: statement.action.span.start,
                hints: [
                    "'\(actionName)' does not declare a `takes` clause in its header",
                    "Use `with { … }` to pass an input object, or add `takes <field>` to the header to allow positional calls",
                ]
            )
        }
    }

    /// Reject references to framework variables inside an `Action` body.
    /// Framework variables are bound only by HTTP routes, event handlers, and
    /// lifecycle feature sets — they have no value here.
    private func validateNoFrameworkVariables(_ statement: AROStatement) {
        // Object base
        let objectBase = statement.object.noun.base
        if UserActionFrameworkVariables.contains(objectBase) {
            diagnostics.error(
                "Framework variable '<\(objectBase)>' is not available inside a user-defined action",
                at: statement.object.noun.span.start,
                hints: [
                    "User-defined actions are synchronous transformations with no event or request context",
                    "Pass the data you need via the `<input>` object instead",
                ]
            )
        }

        // Object specifier (e.g. `<request: body>` — checks the base, which is `request`).
        // The check above already covers this because `noun.base == "request"`.
        // But `<event: user>` style: also covered, because the base is `event`.
    }
}
