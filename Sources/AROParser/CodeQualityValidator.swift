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

        // GitLab #502: a bare Sleep operand is seconds, and a large one reads
        // like milliseconds to anyone from other ecosystems — the symptom is a
        // mysterious hang. Warn on unitless literals over a minute.
        validateSleepDurations(in: statements)

        // GitLab #575: `<params: port> or 8080` is the fallback shape people
        // reach for, and `or` is boolean, so it binds `true`.
        validateLogicalLiterals(in: statements)

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
                    ],
                    // Consequential (GitLab #509): a statement that failed
                    // analysis often takes the terminator down with it, so
                    // this must never headline over the statement's error.
                    category: .consequential
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

    // MARK: - Sleep Duration Validation (GitLab #502)

    /// Verbs that dispatch to `SleepAction` (ARO-0004 row 54).
    private static let sleepVerbs: Set<String> = ["sleep", "delay", "pause"]

    /// Warns when a Sleep operand is a bare numeric literal over
    /// `DurationUnitCatalog.bareLiteralWarningThreshold` seconds.
    ///
    /// `Sleep the <pause> with 300.` sleeps five minutes. Nothing in the
    /// syntax says seconds, and 300 reads like milliseconds to anyone
    /// arriving from JavaScript or Java — the failure is a hang, the
    /// least debuggable symptom there is. A spelled-out unit
    /// (`for 300s`, `for 300ms`, `for 5 minutes`) states intent, so it
    /// never warns; neither does a variable duration, whose value is not
    /// decidable here.
    private func validateSleepDurations(in statements: [Statement]) {
        for aro in collectAROStatements(statements) {
            guard Self.sleepVerbs.contains(aro.action.verb.lowercased()) else { continue }

            // A unit in the source ends up as the object base ("ms",
            // "seconds", …) — see Parser.parseAROObject. Its presence is
            // exactly what makes the duration intentional.
            guard !DurationUnitCatalog.isUnit(aro.object.noun.base) else { continue }

            // Only literal durations are decidable from the AST.
            let seconds: Double
            switch literalNumber(of: aro) {
            case .some(let value): seconds = value
            case .none: continue
            }

            guard seconds > DurationUnitCatalog.bareLiteralWarningThreshold else { continue }

            let shown = formatNumber(seconds)
            diagnostics.warning(
                "Sleep sleeps in seconds — \(shown) is \(describeDuration(seconds))",
                at: aro.span.start,
                hints: [
                    "Write \(shown)s if you mean it, or \(shown)ms for milliseconds",
                    "Units: ms, s, m (minutes), h — e.g. Sleep the <\(aro.result.base)> for 500ms.",
                ]
            )
        }
    }

    /// The statement's duration operand as a number, when it is a bare
    /// numeric literal (`with 300`, `for 90`). Anything else — variables,
    /// arithmetic, strings — returns nil and is not judged.
    private func literalNumber(of statement: AROStatement) -> Double? {
        let literal: LiteralValue
        if let expr = statement.valueSource.asExpression as? LiteralExpression {
            literal = expr.value
        } else if let value = statement.valueSource.asLiteral {
            literal = value
        } else {
            return nil
        }
        switch literal {
        case .integer(let i): return Double(i)
        case .float(let f): return f
        default: return nil
        }
    }

    /// "300" for 300.0, "90.5" for 90.5 — no trailing ".0" noise.
    private func formatNumber(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15
            ? String(Int(value))
            : String(value)
    }

    /// A human reading of a seconds count: "5 minutes", "1.5 hours",
    /// "~1 minute" when a tenth doesn't represent it exactly.
    private func describeDuration(_ seconds: Double) -> String {
        let (amount, unit) = seconds >= 3600
            ? (seconds / 3600, "hour")
            : (seconds / 60, "minute")
        let rounded = (amount * 10).rounded() / 10
        let prefix = rounded == amount ? "" : "~"
        let shown = formatNumber(rounded)
        return shown == "1"
            ? "\(prefix)1 \(unit)"
            : "\(prefix)\(shown) \(unit)s"
    }

    /// Flattens the statement tree, descending into match cases and loop bodies.
    /// Mirrors `DataFlowAnalyzer.collectAROStatements`.
    // MARK: - Logical operators over non-boolean literals (GitLab #575)

    /// `<params: port> or 8080` reads as "the port, or 8080 if it wasn't
    /// passed", and that is what several editions of the docs taught. But `or`
    /// evaluates truthiness and yields a boolean (ARO-0001 §Logical
    /// Operators), so the statement binds `true` — and 8080 is constantly
    /// truthy, so it binds `true` whether the parameter was passed or not.
    /// `aro check` passed it, the program exited `[OK]`, and the wrong value
    /// only surfaced wherever it was finally used.
    ///
    /// A non-boolean literal under `and`/`or` is always dead weight: its
    /// truthiness is fixed at parse time, so it can only pin the result or
    /// contribute nothing. There is no program for which flagging it loses
    /// something, which is what makes this an error rather than a warning.
    /// Boolean literals are left alone — `<x> or false` is redundant but it
    /// is not a mistaken default, and generated source writes it.
    private func validateLogicalLiterals(in statements: [Statement]) {
        for aro in collectAROStatements(statements) {
            for expression in expressionSlots(of: aro) {
                for binary in logicalExpressions(in: expression) {
                    checkLogicalOperand(binary, side: "right", operand: binary.right)
                    checkLogicalOperand(binary, side: "left", operand: binary.left)
                }
            }
        }
    }

    private func checkLogicalOperand(
        _ binary: BinaryExpression,
        side: String,
        operand: any Expression
    ) {
        guard let literal = Self.literalOperand(operand),
              let shown = Self.nonBooleanLiteralDescription(literal) else { return }

        let op = binary.op.rawValue
        let truthy = Self.isTruthyLiteral(literal)

        // A literal under `and`/`or` either pins the result — `or` with a
        // truthy operand is always true, `and` with a falsy one always false —
        // or contributes nothing, leaving the other operand's truthiness.
        // Both are dead weight; they differ only in how to say so.
        let effect: String
        if (binary.op == .or) == truthy {
            effect = "makes the expression constantly \(truthy)"
        } else {
            let other = side == "right" ? binary.left.description : binary.right.description
            effect = "does nothing — the expression is just the truthiness of \(other)"
        }

        var hints = [
            "`\(op)` evaluates truthiness and yields a boolean (ARO-0001 §Logical Operators)",
            "\(shown) is always \(truthy ? "truthy" : "falsy"), so `\(op)` has nothing to decide",
        ]
        // The fallback misreading only has one shape: the value on the left,
        // the intended default on the right of an `or`.
        if binary.op == .or && side == "right" {
            hints.insert(
                "To supply a fallback value, use `default`: "
                    + "\(binary.left.description) default \(shown)",
                at: 0
            )
        }

        diagnostics.error(
            "`\(op)` is a boolean operator, so the \(side) operand \(shown) \(effect)",
            at: binary.span.start,
            hints: hints
        )
    }

    /// How to name a non-boolean literal in a diagnostic, or nil when the
    /// literal is a boolean and therefore not judged.
    private static func nonBooleanLiteralDescription(_ literal: LiteralValue) -> String? {
        switch literal {
        case .boolean: return nil
        case .integer(let i): return String(i)
        case .float(let f): return String(f)
        case .string(let s): return "\"\(s)\""
        default: return nil
        }
    }

    private static func isTruthyLiteral(_ literal: LiteralValue) -> Bool {
        switch literal {
        case .integer(let i): return i != 0
        case .float(let f): return f != 0
        case .string(let s): return !s.isEmpty
        default: return true
        }
    }

    /// Every expression an `AROStatement` carries: its value, and its guard.
    private func expressionSlots(of statement: AROStatement) -> [any Expression] {
        var slots: [any Expression] = []
        switch statement.valueSource {
        case .expression(let e), .sinkExpression(let e): slots.append(e)
        case .literal, .none: break
        }
        if let condition = statement.statementGuard.condition { slots.append(condition) }
        return slots
    }

    /// Every `and`/`or` node in an expression tree.
    ///
    /// Descends through the wrappers an operand can hide behind — the
    /// parenthesised group most of all, since `(<a> or 5)` is precisely how
    /// someone writes the mistake once the precedence table surprises them.
    private func logicalExpressions(in expression: any Expression) -> [BinaryExpression] {
        switch expression {
        case let binary as BinaryExpression:
            var found = logicalExpressions(in: binary.left)
                + logicalExpressions(in: binary.right)
            if binary.op == .and || binary.op == .or { found.append(binary) }
            return found
        case let grouped as GroupedExpression:
            return logicalExpressions(in: grouped.expression)
        case let unary as UnaryExpression:
            return logicalExpressions(in: unary.operand)
        case let array as ArrayLiteralExpression:
            return array.elements.flatMap { logicalExpressions(in: $0) }
        case let map as MapLiteralExpression:
            return map.entries.flatMap { logicalExpressions(in: $0.value) }
        default:
            return []
        }
    }

    /// A literal operand, seen through any parentheses around it: `(8080)`
    /// is the same mistake as `8080`.
    private static func literalOperand(_ expression: any Expression) -> LiteralValue? {
        switch expression {
        case let literal as LiteralExpression: return literal.value
        case let grouped as GroupedExpression: return literalOperand(grouped.expression)
        default: return nil
        }
    }

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
