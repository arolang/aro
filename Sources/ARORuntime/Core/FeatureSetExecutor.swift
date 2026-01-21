// ============================================================
// FeatureSetExecutor.swift
// ARO Runtime - Feature Set Executor
// ============================================================
//
// ARO-0011: Data-Flow Driven Execution
// ------------------------------------
// The executor supports two modes:
// 1. Sequential (default): Statements execute one after another
// 2. Optimized: I/O operations run in parallel based on data dependencies
//
// The optimized mode maintains sequential semantics from the programmer's
// perspective while overlapping I/O operations under the hood.

import Foundation
import AROParser

/// Executes a single feature set
///
/// The FeatureSetExecutor processes statements within a feature set,
/// managing variable bindings and action execution.
///
/// By default, statements execute sequentially. When `enableParallelIO`
/// is true, I/O operations may run in parallel based on data dependencies
/// while maintaining sequential semantics (ARO-0011).
public final class FeatureSetExecutor: @unchecked Sendable {
    // MARK: - Properties

    private let actionRegistry: ActionRegistry
    private let eventBus: EventBus
    private let globalSymbols: GlobalSymbolStorage
    private let expressionEvaluator: ExpressionEvaluator

    /// Whether to enable parallel I/O optimization (ARO-0011)
    public var enableParallelIO: Bool = false

    /// The statement scheduler for parallel I/O (lazy initialization)
    private lazy var scheduler = StatementScheduler()

    // MARK: - Initialization

    public init(
        actionRegistry: ActionRegistry,
        eventBus: EventBus,
        globalSymbols: GlobalSymbolStorage,
        enableParallelIO: Bool = false
    ) {
        self.actionRegistry = actionRegistry
        self.eventBus = eventBus
        self.globalSymbols = globalSymbols
        self.expressionEvaluator = ExpressionEvaluator()
        self.enableParallelIO = enableParallelIO
    }

    // MARK: - Execution

    /// Execute an analyzed feature set
    /// - Parameters:
    ///   - analyzedFeatureSet: The feature set to execute
    ///   - context: The execution context
    /// - Returns: The response from the feature set
    public func execute(
        _ analyzedFeatureSet: AnalyzedFeatureSet,
        context: ExecutionContext
    ) async throws -> Response {
        let featureSet = analyzedFeatureSet.featureSet
        let startTime = Date()

        // Emit start event
        eventBus.publish(FeatureSetStartedEvent(
            featureSetName: featureSet.name,
            executionId: context.executionId
        ))

        // Bind external dependencies from global symbols (with business activity validation)
        for dependency in analyzedFeatureSet.dependencies {
            // Check if access would be denied due to business activity mismatch
            if globalSymbols.isAccessDenied(dependency, forBusinessActivity: context.businessActivity) {
                let sourceActivity = globalSymbols.businessActivity(for: dependency) ?? "unknown"
                throw ActionError.runtimeError(
                    "Variable '\(dependency)' is not accessible. " +
                    "Published variables are only visible within the same business activity. " +
                    "'\(dependency)' is published in \"\(sourceActivity)\" but accessed from \"\(context.businessActivity)\"."
                )
            }

            if let value = globalSymbols.resolveAny(dependency, forBusinessActivity: context.businessActivity) {
                context.bind(dependency, value: value)
            }
        }

        // Execute statements
        do {
            if enableParallelIO {
                // ARO-0011: Data-flow driven parallel I/O execution
                _ = try await scheduler.execute(
                    analyzedFeatureSet,
                    context: context
                ) { [self] statement, ctx in
                    try await self.executeStatement(statement, context: ctx)
                    return () as any Sendable
                }
            } else {
                // Sequential execution (default)
                for statement in featureSet.statements {
                    try await executeStatement(statement, context: context)

                    // Check if we have a response (Return was called)
                    if context.getResponse() != nil {
                        break
                    }
                }
            }

            // Check for response (either from sequential or scheduled execution)
            if let response = context.getResponse() {
                let duration = Date().timeIntervalSince(startTime) * 1000

                eventBus.publish(FeatureSetCompletedEvent(
                    featureSetName: featureSet.name,
                    executionId: context.executionId,
                    success: true,
                    durationMs: duration
                ))

                return response
            }

            // No explicit return - create default response
            let duration = Date().timeIntervalSince(startTime) * 1000

            eventBus.publish(FeatureSetCompletedEvent(
                featureSetName: featureSet.name,
                executionId: context.executionId,
                success: true,
                durationMs: duration
            ))

            return Response.ok()

        } catch {
            let duration = Date().timeIntervalSince(startTime) * 1000

            eventBus.publish(FeatureSetCompletedEvent(
                featureSetName: featureSet.name,
                executionId: context.executionId,
                success: false,
                durationMs: duration
            ))

            throw error
        }
    }

    // MARK: - Statement Execution

    private func executeStatement(
        _ statement: Statement,
        context: ExecutionContext
    ) async throws {
        if let aroStatement = statement as? AROStatement {
            try await executeAROStatement(aroStatement, context: context)
        } else if let publishStatement = statement as? PublishStatement {
            try await executePublishStatement(publishStatement, context: context)
        } else if let matchStatement = statement as? MatchStatement {
            try await executeMatchStatement(matchStatement, context: context)
        } else if let requireStatement = statement as? RequireStatement {
            try await executeRequireStatement(requireStatement, context: context)
        } else if let forEachLoop = statement as? ForEachLoop {
            try await executeForEachLoop(forEachLoop, context: context)
        }
    }

    private func executeAROStatement(
        _ statement: AROStatement,
        context: ExecutionContext
    ) async throws {
        // Clear transient bindings from previous statements
        // These are statement-local and should not persist between statements
        context.unbind("_literal_")
        context.unbind("_expression_")
        context.unbind("_expression_name_")
        context.unbind("_result_expression_")
        context.unbind("_aggregation_type_")
        context.unbind("_aggregation_field_")
        context.unbind("_where_field_")
        context.unbind("_where_op_")
        context.unbind("_where_value_")
        context.unbind("_by_pattern_")
        context.unbind("_by_flags_")
        context.unbind("_to_")
        context.unbind("_with_")

        // ARO-0004: Evaluate when condition before processing statement
        // If condition is present and evaluates to false, skip this statement entirely
        if let whenCondition = statement.whenCondition {
            let conditionResult = try await expressionEvaluator.evaluate(whenCondition, context: context)
            guard asBool(conditionResult) else {
                return  // Condition is false - skip this statement
            }
        }

        let verb = statement.action.verb
        let resultDescriptor = ResultDescriptor(from: statement.result)
        let objectDescriptor = ObjectDescriptor(from: statement.object)

        // ARO-0002: Evaluate expression if present
        if let expression = statement.expression {
            let expressionValue = try await expressionEvaluator.evaluate(expression, context: context)
            context.bind("_expression_", value: expressionValue)

            // ARO-0042: If preposition is "with" and object is expression, also bind to _with_
            // This handles: <Start> the <http-server> with {}.
            if statement.object.preposition == .with && statement.object.noun.base == "_expression_" {
                context.bind("_with_", value: expressionValue)
            }

            // Store the original expression name if it's a simple variable reference
            // This allows EmitAction to use the variable name as payload key
            if let varRef = expression as? VariableRefExpression {
                context.bind("_expression_name_", value: varRef.noun.base)
            }

            // For expressions, directly bind the result to the expression value
            // This handles cases like: <Set> the <x> to 30 * 2.
            // or: <Compute> the <total> from <price> * <quantity>.
            // NOTE: We only do early return for simple assignment actions, NOT for
            // comparison/assertion actions like Then/Assert that need to run.
            if statement.object.noun.base == "_expression_" {
                // Check if the action needs to be executed
                // These actions need to run even with expression shortcut:
                // - "then", "assert" for testing
                // - "call", "invoke" for external service calls (they bind their own results)
                // - "update", "modify", "change", "set" when they have specifiers (field-level updates)
                // - "create", "make", "build" when they have specifiers (typed entities need ID generation)
                // - "merge", "combine", "join", "concat" always need execution (they transform and bind result)
                // - "compute", "calculate", "derive" when they have specifiers (operations like +7d, hash, format)
                // - "extract", "parse", "get" when they have specifiers (property extraction like :days, :next)
                let testVerbs: Set<String> = ["then", "assert"]
                let requestVerbs: Set<String> = ["call", "invoke"]
                let updateVerbs: Set<String> = ["update", "modify", "change", "set"]
                let createVerbs: Set<String> = ["create", "make", "build", "construct"]
                let mergeVerbs: Set<String> = ["merge", "combine", "join", "concat"]
                let computeVerbs: Set<String> = ["compute", "calculate", "derive"]
                let extractVerbs: Set<String> = ["extract", "parse", "get"]
                // Query actions always need execution for where clause processing
                let queryVerbs: Set<String> = ["filter", "map", "reduce", "aggregate"]
                // Response actions like write/read/store should NOT have their result bound to expression value
                let responseVerbs: Set<String> = ["write", "read", "store", "save", "persist", "log", "print", "send", "emit"]
                // Server lifecycle actions always need execution for side effects
                let serverVerbs: Set<String> = ["start", "stop", "restart", "keepalive"]
                let needsExecution = testVerbs.contains(verb.lowercased()) ||
                    requestVerbs.contains(verb.lowercased()) ||
                    mergeVerbs.contains(verb.lowercased()) ||
                    responseVerbs.contains(verb.lowercased()) ||
                    queryVerbs.contains(verb.lowercased()) ||
                    serverVerbs.contains(verb.lowercased()) ||
                    (updateVerbs.contains(verb.lowercased()) && !resultDescriptor.specifiers.isEmpty) ||
                    (createVerbs.contains(verb.lowercased()) && !resultDescriptor.specifiers.isEmpty) ||
                    (computeVerbs.contains(verb.lowercased()) && !resultDescriptor.specifiers.isEmpty) ||
                    (extractVerbs.contains(verb.lowercased()) && !resultDescriptor.specifiers.isEmpty)
                if !needsExecution {
                    context.bind(resultDescriptor.base, value: expressionValue)

                    // Still need to get the action for side effects (like Return, Log, etc.)
                    if let action = actionRegistry.action(for: verb) {
                        // For response actions, execute them with the expression result
                        if statement.action.semanticRole == .response {
                            _ = try await action.execute(
                                result: resultDescriptor,
                                object: objectDescriptor,
                                context: context
                            )
                        }
                    }
                    return
                }
                // For test verbs (then, assert), fall through to normal execution
                // The _expression_ binding is already set for ThenAction/AssertAction to use
            }
        }

        // Bind literal value if present (e.g., "Hello, World!" in the statement)
        if let literalValue = statement.literalValue {
            let literalName = "_literal_"
            switch literalValue {
            case .string(let s):
                context.bind(literalName, value: s)
            case .integer(let i):
                context.bind(literalName, value: i)
            case .float(let f):
                context.bind(literalName, value: f)
            case .boolean(let b):
                context.bind(literalName, value: b)
            case .null:
                context.bind(literalName, value: "")
            case .array(let elements):
                context.bind(literalName, value: convertLiteralArray(elements))
            case .object(let fields):
                context.bind(literalName, value: convertLiteralObject(fields))
            case .regex(let pattern, let flags):
                context.bind(literalName, value: ["pattern": pattern, "flags": flags])
            }
        }

        // ARO-0018: Bind aggregation clause if present
        if let aggregation = statement.aggregation {
            context.bind("_aggregation_type_", value: aggregation.type.rawValue)
            if let field = aggregation.field {
                context.bind("_aggregation_field_", value: field)
            }
        }

        // ARO-0018: Bind where clause if present
        if let whereClause = statement.whereClause {
            context.bind("_where_field_", value: whereClause.field)
            context.bind("_where_op_", value: whereClause.op.rawValue)
            // Evaluate the where value expression
            let whereValue = try await expressionEvaluator.evaluate(whereClause.value, context: context)
            context.bind("_where_value_", value: whereValue)
        }

        // ARO-0037: Bind by clause if present (for Split action)
        if let byClause = statement.byClause {
            context.bind("_by_pattern_", value: byClause.pattern)
            context.bind("_by_flags_", value: byClause.flags)
        }

        // ARO-0041: Bind to clause if present (for date ranges)
        if let toClause = statement.toClause {
            let toValue = try await expressionEvaluator.evaluate(toClause, context: context)
            context.bind("_to_", value: toValue)
        }

        // ARO-0042: Bind with clause if present (for set operations)
        if let withClause = statement.withClause {
            let withValue = try await expressionEvaluator.evaluate(withClause, context: context)
            context.bind("_with_", value: withValue)
        }

        // ARO-0043: Evaluate result expression if present (for sink syntax)
        // Sink syntax: <Log> "message" to the <console>.
        if let resultExpression = statement.resultExpression {
            let resultValue = try await expressionEvaluator.evaluate(resultExpression, context: context)
            context.bind("_result_expression_", value: resultValue)
        }

        // Get action implementation
        guard let action = actionRegistry.action(for: verb) else {
            throw ActionError.unknownAction(verb)
        }

        // Execute action with ARO-0008 error wrapping
        do {
            let result = try await action.execute(
                result: resultDescriptor,
                object: objectDescriptor,
                context: context
            )

            // Bind result to context (unless it's a response action that already set the response)
            // Also skip binding if the action already bound the result (to avoid double-binding)
            if statement.action.semanticRole != .response && !context.exists(resultDescriptor.base) {
                // Check if this is a rebinding action (accept, update, delete, merge, etc.)
                let rebindingVerbs: Set<String> = [
                    "accept", "update", "modify", "change", "set", "configure",
                    "delete", "remove", "destroy", "clear",
                    "merge", "combine", "join", "concat"
                ]
                let allowRebind = rebindingVerbs.contains(verb.lowercased())
                context.bind(resultDescriptor.base, value: result, allowRebind: allowRebind)
            }
        } catch let assertionError as AssertionError {
            // Re-throw assertion errors directly for test framework
            throw assertionError
        } catch let aroError as AROError {
            // Already an AROError, re-throw
            throw ActionError.statementFailed(aroError)
        } catch {
            // Wrap other errors with statement context (ARO-0008: Code Is The Error Message)
            let aroError = AROError.fromStatement(
                verb: verb,
                result: resultDescriptor.fullName,
                preposition: statement.object.preposition.rawValue,
                object: objectDescriptor.fullName,
                condition: statement.whenCondition != nil ? "when <condition>" : nil,
                featureSet: context.featureSetName,
                businessActivity: context.businessActivity,
                resolvedValues: gatherResolvedValues(for: statement, context: context)
            )
            throw ActionError.statementFailed(aroError)
        }
    }

    /// Gather resolved variable values for error context
    private func gatherResolvedValues(
        for statement: AROStatement,
        context: ExecutionContext
    ) -> [String: String] {
        var values: [String: String] = [:]

        // Collect object base value
        let objectBase = statement.object.noun.base
        if let value = context.resolveAny(objectBase) {
            values[objectBase] = String(describing: value)
        }

        // Collect object specifier values
        for specifier in statement.object.noun.specifiers {
            if let value = context.resolveAny(specifier) {
                values[specifier] = String(describing: value)
            }
        }

        // Collect result base value
        let resultBase = statement.result.base
        if let value = context.resolveAny(resultBase) {
            values[resultBase] = String(describing: value)
        }

        // Collect result specifier values
        for specifier in statement.result.specifiers {
            if let value = context.resolveAny(specifier) {
                values[specifier] = String(describing: value)
            }
        }

        return values
    }

    private func executePublishStatement(
        _ statement: PublishStatement,
        context: ExecutionContext
    ) async throws {
        // Get the internal value
        guard let value = context.resolveAny(statement.internalVariable) else {
            throw ActionError.undefinedVariable(statement.internalVariable)
        }

        // Publish to global symbols with business activity
        globalSymbols.publish(
            name: statement.externalName,
            value: value,
            fromFeatureSet: context.featureSetName,
            businessActivity: context.businessActivity
        )

        // Also bind the external name locally
        context.bind(statement.externalName, value: value)

        // Emit event
        eventBus.publish(VariablePublishedEvent(
            externalName: statement.externalName,
            internalName: statement.internalVariable,
            featureSet: context.featureSetName
        ))
    }

    // MARK: - Match Statement Execution (ARO-0004)

    private func executeMatchStatement(
        _ statement: MatchStatement,
        context: ExecutionContext
    ) async throws {
        // Resolve the subject value
        guard let subjectValue = context.resolveAny(statement.subject.base) else {
            throw ActionError.undefinedVariable(statement.subject.base)
        }

        // Try each case in order
        for caseClause in statement.cases {
            if try await matchesPattern(caseClause.pattern, against: subjectValue, context: context) {
                // Check guard condition if present
                if let guardCondition = caseClause.guardCondition {
                    let guardResult = try await expressionEvaluator.evaluate(guardCondition, context: context)
                    guard let boolResult = guardResult as? Bool, boolResult else {
                        continue // Guard failed, try next case
                    }
                }

                // Execute the case body
                for bodyStatement in caseClause.body {
                    try await executeStatement(bodyStatement, context: context)
                    // Check if we have a response
                    if context.getResponse() != nil {
                        return
                    }
                }
                return // Case matched, don't try other cases
            }
        }

        // No case matched, execute otherwise if present
        if let otherwiseBody = statement.otherwise {
            for bodyStatement in otherwiseBody {
                try await executeStatement(bodyStatement, context: context)
                if context.getResponse() != nil {
                    return
                }
            }
        }
    }

    /// Check if a pattern matches a value
    private func matchesPattern(
        _ pattern: Pattern,
        against value: any Sendable,
        context: ExecutionContext
    ) async throws -> Bool {
        switch pattern {
        case .literal(let literalValue):
            return matchesLiteral(literalValue, against: value)
        case .variable(let noun):
            // Resolve variable and compare
            if let varValue = context.resolveAny(noun.base) {
                return valuesEqual(varValue, value)
            }
            return false
        case .wildcard:
            return true
        case .regex(let pattern, let flags):
            guard let stringValue = value as? String else { return false }
            return regexMatches(stringValue, pattern: pattern, flags: flags)
        }
    }

    /// Check if a literal value matches a runtime value
    private func matchesLiteral(_ literal: LiteralValue, against value: any Sendable) -> Bool {
        switch literal {
        case .string(let s):
            if let valueString = value as? String {
                return s == valueString
            }
            return false
        case .integer(let i):
            if let valueInt = value as? Int {
                return i == valueInt
            }
            return false
        case .float(let f):
            if let valueFloat = value as? Double {
                return f == valueFloat
            }
            return false
        case .boolean(let b):
            if let valueBool = value as? Bool {
                return b == valueBool
            }
            return false
        case .null:
            // Check for nil-like values
            // Note: value is already any Sendable, so it can't be nil
            return false
        case .array, .object:
            // Complex types - use string comparison for now
            return String(describing: convertLiteralValue(literal)) == String(describing: value)
        case .regex(let pattern, let flags):
            guard let stringValue = value as? String else { return false }
            return regexMatches(stringValue, pattern: pattern, flags: flags)
        }
    }

    /// Check if a string matches a regex pattern with flags
    private func regexMatches(_ string: String, pattern: String, flags: String) -> Bool {
        var options: NSRegularExpression.Options = []
        if flags.contains("i") { options.insert(.caseInsensitive) }
        if flags.contains("s") { options.insert(.dotMatchesLineSeparators) }
        if flags.contains("m") { options.insert(.anchorsMatchLines) }

        do {
            let regex = try NSRegularExpression(pattern: pattern, options: options)
            let range = NSRange(string.startIndex..., in: string)
            return regex.firstMatch(in: string, range: range) != nil
        } catch {
            // Invalid regex pattern - return false
            return false
        }
    }

    /// Convert a LiteralValue to a runtime value
    private func convertLiteralValue(_ literal: LiteralValue) -> any Sendable {
        switch literal {
        case .string(let s): return s
        case .integer(let i): return i
        case .float(let f): return f
        case .boolean(let b): return b
        case .null: return ""
        case .array(let elements): return convertLiteralArray(elements)
        case .object(let fields): return convertLiteralObject(fields)
        case .regex(let pattern, let flags): return ["pattern": pattern, "flags": flags]
        }
    }

    /// Convert an array of LiteralValues to a runtime array
    private func convertLiteralArray(_ elements: [LiteralValue]) -> [any Sendable] {
        elements.map { convertLiteralValue($0) }
    }

    /// Convert object fields to a runtime dictionary
    private func convertLiteralObject(_ fields: [(String, LiteralValue)]) -> [String: any Sendable] {
        var dict: [String: any Sendable] = [:]
        for (key, value) in fields {
            dict[key] = convertLiteralValue(value)
        }
        return dict
    }

    /// Check if two values are equal
    private func valuesEqual(_ a: any Sendable, _ b: any Sendable) -> Bool {
        // Try various type comparisons
        if let aString = a as? String, let bString = b as? String {
            return aString == bString
        }
        if let aInt = a as? Int, let bInt = b as? Int {
            return aInt == bInt
        }
        if let aDouble = a as? Double, let bDouble = b as? Double {
            return aDouble == bDouble
        }
        if let aBool = a as? Bool, let bBool = b as? Bool {
            return aBool == bBool
        }
        // Fall back to string comparison
        return String(describing: a) == String(describing: b)
    }

    // MARK: - Require Statement Execution (ARO-0003)

    private func executeRequireStatement(
        _ statement: RequireStatement,
        context: ExecutionContext
    ) async throws {
        // Require statements are typically handled at analysis/setup time
        // At runtime, we just verify the dependency is available
        switch statement.source {
        case .framework:
            // Framework dependencies are auto-bound (console, http-server, etc.)
            // These are typically already available in the context
            break
        case .environment:
            // Environment variables
            if let envValue = ProcessInfo.processInfo.environment[statement.variableName] {
                context.bind(statement.variableName, value: envValue)
            }
        case .featureSet(let name):
            // Cross-feature-set dependency - resolve from global symbols (with business activity validation)
            if let value = globalSymbols.resolveAny(statement.variableName, forBusinessActivity: context.businessActivity) {
                context.bind(statement.variableName, value: value)
            }
            // If not found, the dependency might be provided later
            _ = name // Suppress unused warning
        }
    }

    // MARK: - Property Access Helper

    /// Access a property on a collection value (for nested iteration like `<team: members>`)
    private func accessCollectionProperty(_ property: String, on value: any Sendable) throws -> any Sendable {
        // Handle [String: any Sendable] dictionary
        if let dict = value as? [String: any Sendable] {
            guard let propValue = dict[property] else {
                throw ActionError.runtimeError("Property '\(property)' not found on object")
            }
            return propValue
        }

        // Handle [String: AnySendable] dictionary
        if let dict = value as? [String: AnySendable] {
            guard let propValue = dict[property] else {
                throw ActionError.runtimeError("Property '\(property)' not found on object")
            }
            return propValue
        }

        throw ActionError.runtimeError("Cannot access property '\(property)' on \(type(of: value))")
    }

    // MARK: - For-Each Loop Execution (ARO-0005)

    private func executeForEachLoop(
        _ loop: ForEachLoop,
        context: ExecutionContext
    ) async throws {
        // Resolve the collection (with specifier support for property access)
        guard var collectionValue: any Sendable = context.resolveAny(loop.collection.base) else {
            throw ActionError.undefinedVariable(loop.collection.base)
        }

        // Handle specifiers as property access (e.g., <team: members> -> team.members)
        for specifier in loop.collection.specifiers {
            collectionValue = try accessCollectionProperty(specifier, on: collectionValue)
        }

        // Convert to array
        let items: [any Sendable]
        if let array = collectionValue as? [any Sendable] {
            items = array
        } else if let array = collectionValue as? [String] {
            items = array
        } else if let array = collectionValue as? [Int] {
            items = array
        } else if let array = collectionValue as? [Double] {
            items = array
        } else {
            // Single item
            items = [collectionValue]
        }

        // Execute loop body for each item
        if loop.isParallel {
            // Parallel execution
            let concurrency = loop.concurrency ?? items.count
            try await withThrowingTaskGroup(of: Void.self) { group in
                var activeCount = 0
                for (index, item) in items.enumerated() {
                    // Create a child context for filter evaluation
                    // This ensures the filter check doesn't violate immutability
                    let filterContext = context.createChild(featureSetName: context.featureSetName)
                    filterContext.bind(loop.itemVariable, value: item)
                    if let indexVar = loop.indexVariable {
                        filterContext.bind(indexVar, value: index)
                    }

                    // Check filter condition if present
                    if let filter = loop.filter {
                        let filterResult = try await expressionEvaluator.evaluate(filter, context: filterContext)
                        guard let passes = filterResult as? Bool, passes else {
                            continue
                        }
                    }

                    group.addTask {
                        // Create a child context for this iteration
                        let childContext = context.createChild(featureSetName: context.featureSetName)
                        childContext.bind(loop.itemVariable, value: item)
                        if let indexVar = loop.indexVariable {
                            childContext.bind(indexVar, value: index)
                        }

                        for bodyStatement in loop.body {
                            try await self.executeStatement(bodyStatement, context: childContext)
                        }
                    }

                    activeCount += 1
                    if activeCount >= concurrency {
                        try await group.next()
                        activeCount -= 1
                    }
                }
            }
        } else {
            // Sequential execution
            for (index, item) in items.enumerated() {
                // Create fresh child context for this iteration
                // This gives us fresh immutable bindings per iteration
                let iterationContext = context.createChild(featureSetName: context.featureSetName)

                // Bind loop variables in iteration context
                iterationContext.bind(loop.itemVariable, value: item)
                if let indexVar = loop.indexVariable {
                    iterationContext.bind(indexVar, value: index)
                }

                // Check filter condition if present
                if let filter = loop.filter {
                    let filterResult = try await expressionEvaluator.evaluate(filter, context: iterationContext)
                    guard let passes = filterResult as? Bool, passes else {
                        continue
                    }
                }

                // Execute loop body in iteration context
                for bodyStatement in loop.body {
                    try await executeStatement(bodyStatement, context: iterationContext)
                    if iterationContext.getResponse() != nil {
                        return
                    }
                }
            }
        }
    }

    // MARK: - When Clause Helpers

    /// Evaluate a value as a boolean for when clause conditions
    /// Follows JavaScript-like truthiness rules for convenience
    private func asBool(_ value: any Sendable) -> Bool {
        if let b = value as? Bool { return b }
        if let i = value as? Int { return i != 0 }
        if let s = value as? String { return !s.isEmpty }
        if let array = value as? [any Sendable] { return !array.isEmpty }
        return true  // Non-nil values are truthy
    }
}

// MARK: - Runtime

/// Main runtime that manages program execution lifecycle
public final class Runtime: @unchecked Sendable {
    // MARK: - Properties

    private let engine: ExecutionEngine
    /// Event bus for event emission (public for C bridge access in compiled binaries)
    public let eventBus: EventBus
    private var _isRunning: Bool = false
    private var _currentProgram: AnalyzedProgram?
    private var _shutdownError: Error?
    private let lock = NSLock()

    /// Registry for compiled event handlers: eventType -> [(handlerName, callback)]
    private var _compiledHandlers: [String: [(String, @Sendable (DomainEvent) async -> Void)]] = [:]

    // MARK: - Thread-safe helpers

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private var isRunning: Bool {
        get { withLock { _isRunning } }
        set { withLock { _isRunning = newValue } }
    }

    private var currentProgram: AnalyzedProgram? {
        get { withLock { _currentProgram } }
        set { withLock { _currentProgram = newValue } }
    }

    private var shutdownError: Error? {
        get { withLock { _shutdownError } }
        set { withLock { _shutdownError = newValue } }
    }

    private func tryStartRunning() -> Bool {
        withLock {
            if _isRunning { return false }
            _isRunning = true
            return true
        }
    }

    // MARK: - Initialization

    public init(
        actionRegistry: ActionRegistry = .shared,
        eventBus: EventBus = .shared
    ) {
        self.engine = ExecutionEngine(actionRegistry: actionRegistry, eventBus: eventBus)
        self.eventBus = eventBus

        // Subscribe to DomainEvent once to dispatch to compiled handlers
        eventBus.subscribe(to: DomainEvent.self) { [weak self] event in
            guard let self = self else { return }

            // Get handlers for this event type
            let handlers = self.withLock {
                self._compiledHandlers[event.domainEventType] ?? []
            }

            // Execute all matching handlers concurrently
            await withTaskGroup(of: Void.self) { group in
                for (_, callback) in handlers {
                    group.addTask {
                        await callback(event)
                    }
                }
            }
        }
    }

    // MARK: - Service Registration

    /// Register a service for dependency injection
    public func register<S: Sendable>(service: S) {
        engine.register(service: service)
    }

    // MARK: - Compiled Handler Registration

    /// Register a compiled event handler
    /// - Parameters:
    ///   - eventType: The event type to listen for
    ///   - handlerName: Name of the handler feature set
    ///   - callback: The compiled handler function to call
    public func registerCompiledHandler(
        eventType: String,
        handlerName: String,
        callback: @escaping @Sendable (DomainEvent) async -> Void
    ) {
        withLock {
            if _compiledHandlers[eventType] == nil {
                _compiledHandlers[eventType] = []
            }
            _compiledHandlers[eventType]?.append((handlerName, callback))
        }
    }

    // MARK: - Execution

    /// Run a program
    /// - Parameters:
    ///   - program: The analyzed program to run
    ///   - entryPoint: The entry point feature set name
    /// - Returns: The response from execution
    public func run(
        _ program: AnalyzedProgram,
        entryPoint: String = "Application-Start"
    ) async throws -> Response {
        guard tryStartRunning() else {
            throw ActionError.runtimeError("Runtime is already running")
        }

        defer {
            isRunning = false
        }

        return try await engine.execute(program, entryPoint: entryPoint)
    }

    /// Run and keep alive (for servers)
    /// - Parameters:
    ///   - program: The analyzed program to run
    ///   - entryPoint: The entry point feature set name
    public func runAndKeepAlive(
        _ program: AnalyzedProgram,
        entryPoint: String = "Application-Start"
    ) async throws {
        // Reset shutdown coordinator for new run
        ShutdownCoordinator.shared.reset()

        // Store the program for Application-End execution
        currentProgram = program

        // Register for signal handling
        RuntimeSignalHandler.shared.register(self)

        do {
            _ = try await run(program, entryPoint: entryPoint)
        } catch {
            // Store error for Application-End: Error handler
            shutdownError = error
            await executeApplicationEnd(isError: true)
            throw error
        }

        // Re-set isRunning since run() resets it in defer block
        isRunning = true

        // Keep running until stopped
        while isRunning {
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }

        // Execute Application-End handler on graceful shutdown
        await executeApplicationEnd(isError: shutdownError != nil)
    }

    /// Execute Application-End handler if defined
    /// - Parameter isError: Whether shutdown is due to an error
    private func executeApplicationEnd(isError: Bool) async {
        guard let program = currentProgram else { return }

        // Find Application-End feature set
        let businessActivity = isError ? "Error" : "Success"
        guard let exitHandler = program.featureSets.first(where: { fs in
            fs.featureSet.name == "Application-End" &&
            fs.featureSet.businessActivity == businessActivity
        }) else {
            return // No exit handler defined
        }

        // Create context for exit handler
        let context = RuntimeContext(
            featureSetName: "Application-End",
            eventBus: eventBus
        )

        // Bind shutdown context variables
        if isError, let error = shutdownError {
            context.bind("shutdown", value: [
                "reason": String(describing: error),
                "code": 1,
                "error": String(describing: error)
            ] as [String: any Sendable])
        } else {
            context.bind("shutdown", value: [
                "reason": "graceful shutdown",
                "code": 0,
                "signal": "SIGTERM"
            ] as [String: any Sendable])
        }

        // Execute the exit handler
        let executor = FeatureSetExecutor(
            actionRegistry: ActionRegistry.shared,
            eventBus: eventBus,
            globalSymbols: GlobalSymbolStorage()
        )

        do {
            _ = try await executor.execute(exitHandler, context: context)
        } catch {
            // Log but don't propagate errors from exit handler
            print("[Runtime] Application-End handler failed: \(error)")
        }
    }

    /// Wait for all in-flight event handlers to complete
    /// - Parameter timeout: Maximum time to wait in seconds (default: 10.0)
    /// - Returns: true if all handlers completed, false if timeout occurred
    public func awaitPendingEvents(timeout: TimeInterval = 10.0) async -> Bool {
        return await eventBus.awaitPendingEvents(timeout: timeout)
    }

    /// Stop the runtime
    public func stop() {
        eventBus.publish(ApplicationStoppingEvent(reason: "stop requested"))

        // Signal any waiting actions via the global coordinator
        ShutdownCoordinator.shared.signalShutdown()

        isRunning = false
    }
}

// MARK: - Signal Handler

/// Thread-safe signal handler for runtime shutdown
public final class RuntimeSignalHandler: @unchecked Sendable {
    public static let shared = RuntimeSignalHandler()

    private let lock = NSLock()
    private var runtime: Runtime?
    private var isSetup = false

    private init() {}

    /// Register a runtime for signal handling
    public func register(_ runtime: Runtime) {
        lock.lock()
        defer { lock.unlock() }

        self.runtime = runtime

        if !isSetup {
            setupSignalHandlers()
            isSetup = true
        }
    }

    /// Setup signal handlers (once)
    private func setupSignalHandlers() {
        signal(SIGINT) { _ in
            RuntimeSignalHandler.shared.handleSignal()
        }

        signal(SIGTERM) { _ in
            RuntimeSignalHandler.shared.handleSignal()
        }
    }

    /// Handle shutdown signal
    private func handleSignal() {
        lock.lock()
        let rt = runtime
        lock.unlock()

        rt?.stop()
    }

    /// Reset for testing (clears registered runtime)
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        runtime = nil
    }
}
