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
        // Pre-filter once. 195 of 200 feature sets are typically
        // non-Action; the second loop then visits only the
        // candidate set instead of re-checking the predicate on
        // every iteration (#350).
        let actionFeatureSets = featureSets.filter { $0.isUserAction }
        var actions: [String: UserActionInfo] = [:]
        actions.reserveCapacity(actionFeatureSets.count)

        for fs in actionFeatureSets {
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

    // MARK: - Unavoidable Recursion (GitLab #473)

    /// Warn about a recursion that can never reach a base case.
    ///
    /// The runtime no longer dies on a missing base case — it runs until the
    /// call-depth budget stops it, and a tail-recursive one runs forever in
    /// constant space. Either way the program is wrong, and both are cheaper to
    /// find here: the shape being caught is an action whose *every* path
    /// reaches a call before it can reach a `Return`.
    ///
    /// Direct and mutual cycles both. Deliberately conservative: anything that
    /// could branch before the call — a guarded statement, a match, a loop —
    /// means a base case might exist, and nothing is reported.
    public func detectUnavoidableRecursion(in featureSets: [FeatureSet], registry: UserActionRegistry) {
        // Each action's first unavoidable call, if it has one. At most one edge
        // per node, so cycle detection is a walk.
        var edges: [String: (callee: String, span: SourceSpan)] = [:]
        for fs in featureSets where fs.isUserAction {
            if let call = firstUnavoidableCall(in: fs, registry: registry) {
                edges[fs.name] = call
            }
        }

        var reported = Set<String>()
        for start in edges.keys.sorted() {
            guard !reported.contains(start) else { continue }

            // Walk the chain from `start`; a name seen twice on this walk is a
            // cycle. Names on the way in that are not part of the cycle still
            // reach it, but reporting the cycle itself is the useful message.
            var path: [String] = []
            var seen: [String: Int] = [:]
            var current = start
            while let edge = edges[current] {
                if let cycleStart = seen[current] {
                    let cycle = Array(path[cycleStart...])
                    report(cycle: cycle, edges: edges, reported: &reported)
                    break
                }
                seen[current] = path.count
                path.append(current)
                current = edge.callee
            }
        }
    }

    private func report(
        cycle: [String],
        edges: [String: (callee: String, span: SourceSpan)],
        reported: inout Set<String>
    ) {
        for name in cycle where !reported.contains(name) {
            reported.insert(name)
            guard let edge = edges[name] else { continue }

            let isDirect = cycle.count == 1
            let chain = (cycle + [cycle[0]]).joined(separator: " → ")
            let message = isDirect
                ? "Action '\(name)' always calls itself — this recursion has no base case"
                : "Action '\(name)' always reaches itself again — this recursion has no base case (\(chain))"

            diagnostics.warning(
                message,
                at: edge.span.start,
                hints: [
                    "Every path through '\(name)' reaches `Application.\(edge.callee)` before it can reach a `Return`",
                    "Add a guarded return that runs first, e.g. `Return an <OK: status> with <value> when <n> <= 0.`",
                ]
            )
        }
    }

    /// The first call this action makes that nothing can prevent it from
    /// making, or `nil` if some path could return first.
    private func firstUnavoidableCall(
        in featureSet: FeatureSet,
        registry: UserActionRegistry
    ) -> (callee: String, span: SourceSpan)? {
        for statement in featureSet.statements {
            // Anything other than a plain statement introduces control flow this
            // pass does not model — a match arm or loop body may well return.
            guard let aro = statement as? AROStatement else { return nil }

            let verb = aro.action.verb.lowercased()

            if aro.statementGuard.isPresent {
                // A guarded return is exactly the base case being looked for.
                if verb == "return" || verb == "throw" { return nil }
                // Any other guarded statement is harmless: it either runs or
                // doesn't, and execution continues either way. A guarded *call*
                // is not unavoidable, so it is skipped rather than reported.
                continue
            }

            // An unguarded return ends the action before any call below it.
            if verb == "return" || verb == "throw" { return nil }

            if let callee = UserActionRegistry.actionName(fromCallVerb: aro.action.verb),
               registry.info(for: callee) != nil {
                return (callee, aro.action.span)
            }
        }
        return nil
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
