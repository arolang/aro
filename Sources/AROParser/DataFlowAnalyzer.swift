// ============================================================
// DataFlowAnalyzer.swift
// ARO Parser - Data Flow Analysis and Statement Analysis
// ============================================================
//
// Error-handling contract (#340): nonthrowing, exactly like
// SemanticAnalyzer (see Parser.swift for the module summary).
// Missing dependencies, unresolved identifiers, and shadowed
// publishes become diagnostics in the shared collector instead
// of exceptions. The empty-result fallback that some helpers
// return on missing inputs is the analyzer's way of letting
// downstream passes still observe partial structure — the real
// signal of failure is on the diagnostics bag, not the return
// value.

import Foundation

// MARK: - Data Flow Analyzer

/// Analyzes data flow through statements: variable tracking, immutability,
/// dependency detection, and streaming optimizations (ARO-0051)
public struct DataFlowAnalyzer {

    private let diagnostics: DiagnosticCollector

    public init(diagnostics: DiagnosticCollector) {
        self.diagnostics = diagnostics
    }

    // MARK: - Feature Set Analysis

    /// Analyzes a single feature set, returning symbol table, data flows, dependencies, and exports
    public func analyzeFeatureSet(_ featureSet: FeatureSet) -> AnalyzedFeatureSet {
        let builder = SymbolTableBuilder(
            scopeId: "fs-\(featureSet.name.hashValue)",
            scopeName: featureSet.name
        )

        var dataFlows: [DataFlowInfo] = []
        var dependencies: Set<String> = []
        var exports: Set<String> = []
        var definedSymbols: Set<String> = []

        for statement in featureSet.statements {
            let (flow, newDeps) = analyzeStatement(
                statement,
                builder: builder,
                definedSymbols: &definedSymbols
            )
            dataFlows.append(flow)
            dependencies.formUnion(newDeps)

            if let publish = statement as? PublishStatement {
                exports.insert(publish.externalName)
            }

            if let require = statement as? RequireStatement {
                dependencies.insert(require.variableName)
            }
        }

        // Detect unused variables (ARO-0003)
        let symbolTable = builder.build()
        var usedVariables: Set<String> = []
        for flow in dataFlows {
            usedVariables.formUnion(flow.inputs)
        }

        // Result names produced by a side-effect verb are intentionally
        // discardable — Make, Append, Write, Log, Emit, Start, Stop,
        // Send, Notify, Schedule and user-defined `Application.X` calls
        // are all "do something" rather than "compute a value". Mark
        // them used so the unused-var warning doesn't shame intentional
        // fire-and-forget calls.
        // Walk the whole statement tree (descending into match cases and
        // for-each bodies) — the checks below need to see every action,
        // not just top-level ones.
        let allAros = collectAROStatements(featureSet.statements)

        var sideEffectResults: Set<String> = []
        for aro in allAros where isSideEffectVerb(aro.action.verb) {
            sideEffectResults.insert(aro.result.base)
        }

        // Variables consumed as the *base* of another statement's result
        // qualifier (e.g. the `defaults` in `Merge the <opts: defaults>
        // with <raw>.`) are real uses too — the data-flow visitor only
        // records the right-hand side as input, so flag the qualifier
        // bases explicitly here.
        var qualifierBaseRefs: Set<String> = []
        for aro in allAros {
            for specifier in aro.result.specifiers {
                qualifierBaseRefs.insert(specifier)
            }
        }

        // If the feature set renders a template via Transform/Include
        // (object base == "template"), the template body reads variables
        // from the calling scope at runtime — static analysis can't see
        // those reads, so suppress unused warnings for every local in
        // this feature set.
        let rendersTemplate = allAros.contains { aro in
            let verb = aro.action.verb.lowercased()
            return (verb == "transform" || verb == "include" || verb == "render")
                && aro.object.noun.base.lowercased() == "template"
        }

        for (name, symbol) in symbolTable.symbols {
            if symbol.visibility == .published { continue }
            if case .alias = symbol.source { continue }
            if symbol.visibility == .external { continue }
            if isSideEffectBinding(name) { continue }
            if sideEffectResults.contains(name) { continue }
            if qualifierBaseRefs.contains(name) { continue }
            if rendersTemplate { continue }

            if !usedVariables.contains(name) {
                diagnostics.warning(
                    "Variable '\(name)' is defined but never used",
                    at: symbol.definedAt.start
                )
            }
        }

        // ARO-0051: Detect streaming optimizations
        let aggregationFusions = detectAggregationFusions(featureSet.statements)
        let streamConsumers = detectStreamConsumers(dataFlows, statements: featureSet.statements)

        return AnalyzedFeatureSet(
            featureSet: featureSet,
            symbolTable: symbolTable,
            dataFlows: dataFlows,
            dependencies: dependencies,
            exports: exports,
            aggregationFusions: aggregationFusions,
            streamConsumers: streamConsumers
        )
    }

    // MARK: - Statement Analysis

    private func analyzeStatement(
        _ statement: Statement,
        builder: SymbolTableBuilder,
        definedSymbols: inout Set<String>,
        inMutableScope: Bool = false
    ) -> (DataFlowInfo, Set<String>) {

        if let aro = statement as? AROStatement {
            return analyzeAROStatement(aro, builder: builder, definedSymbols: &definedSymbols, inMutableScope: inMutableScope)
        }

        if let publish = statement as? PublishStatement {
            return analyzePublishStatement(publish, builder: builder, definedSymbols: definedSymbols)
        }

        if let require = statement as? RequireStatement {
            return analyzeRequireStatement(require, builder: builder)
        }

        if let match = statement as? MatchStatement {
            return analyzeMatchStatement(match, builder: builder, definedSymbols: &definedSymbols)
        }

        if let forEach = statement as? ForEachLoop {
            return analyzeForEachLoop(forEach, builder: builder, definedSymbols: &definedSymbols)
        }

        if let whileLoop = statement as? WhileLoop {
            return analyzeWhileLoop(whileLoop, builder: builder, definedSymbols: &definedSymbols)
        }

        if statement is BreakStatement {
            return (DataFlowInfo(), [])
        }

        return (DataFlowInfo(), [])
    }

    // MARK: - ARO Statement

    private func analyzeAROStatement(
        _ statement: AROStatement,
        builder: SymbolTableBuilder,
        definedSymbols: inout Set<String>,
        inMutableScope: Bool = false
    ) -> (DataFlowInfo, Set<String>) {

        var inputs: Set<String> = []
        var outputs: Set<String> = []
        var sideEffects: [String] = []
        var dependencies: Set<String> = []

        let resultName = statement.result.base
        let objectName = statement.object.noun.base

        // Track object qualifier as input if it looks like a variable reference
        if let objectQualifier = statement.object.noun.typeAnnotation,
           looksLikeVariable(objectQualifier) {
            inputs.insert(objectQualifier)
        }

        // ARO-0002: Extract variables from expression if present
        if let expr = statement.valueSource.asExpression {
            let exprVars = extractVariables(from: expr)
            for varName in exprVars {
                if !definedSymbols.contains(varName) && !isKnownExternal(varName) {
                    dependencies.insert(varName)
                }
                inputs.insert(varName)
            }
        }

        // ARO-0004: Extract variables from when condition if present
        if let whenExpr = statement.statementGuard.condition {
            let condVars = extractVariables(from: whenExpr)
            for varName in condVars {
                if !definedSymbols.contains(varName) && !isKnownExternal(varName) {
                    dependencies.insert(varName)
                }
                inputs.insert(varName)
            }
        }

        // ARO-0018: Extract variables from where clause if present
        if let whereClause = statement.queryModifiers.whereClause {
            let whereVars = extractVariables(from: whereClause.value)
            for varName in whereVars {
                if !definedSymbols.contains(varName) && !isKnownExternal(varName) {
                    dependencies.insert(varName)
                }
                inputs.insert(varName)
            }
        }

        // Extract variables from range modifiers with clause
        if let withClause = statement.rangeModifiers.withClause {
            let withVars = extractVariables(from: withClause)
            for varName in withVars {
                if !definedSymbols.contains(varName) && !isKnownExternal(varName) {
                    dependencies.insert(varName)
                }
                inputs.insert(varName)
            }
        }

        // Determine data flow based on action semantic role
        switch statement.action.semanticRole {
        case .request:
            if !isKnownExternal(objectName) && !definedSymbols.contains(objectName) {
                dependencies.insert(objectName)
            }
            inputs.insert(objectName)
            outputs.insert(resultName)

            let dataType = TypeInferencer.inferResultType(statement)
            checkImmutabilityViolation(
                name: resultName, verb: statement.action.verb,
                objectName: objectName, preposition: statement.object.preposition,
                span: statement.result.span,
                definedSymbols: definedSymbols, inMutableScope: inMutableScope
            )

            builder.define(
                name: resultName,
                definedAt: statement.span,
                visibility: .internal,
                source: .extracted(from: objectName),
                dataType: dataType
            )
            definedSymbols.insert(resultName)

        case .own:
            if !isKnownExternal(objectName) && !definedSymbols.contains(objectName) && !dependencies.contains(objectName) {
                diagnostics.warning(
                    "Variable '\(objectName)' used before definition",
                    at: statement.object.noun.span.start
                )
            }
            inputs.insert(objectName)
            outputs.insert(resultName)

            let dataType = TypeInferencer.inferResultType(statement)
            checkImmutabilityViolation(
                name: resultName, verb: statement.action.verb,
                objectName: objectName, preposition: statement.object.preposition,
                span: statement.result.span,
                definedSymbols: definedSymbols, inMutableScope: inMutableScope
            )

            builder.define(
                name: resultName,
                definedAt: statement.span,
                visibility: .internal,
                source: .computed,
                dataType: dataType
            )
            definedSymbols.insert(resultName)

        case .response:
            if definedSymbols.contains(objectName) || isKnownExternal(objectName) {
                inputs.insert(objectName)
            }
            let exportDataVerbs = ["store", "write", "emit", "save", "persist", "send"]
            if exportDataVerbs.contains(statement.action.verb.lowercased()) {
                if definedSymbols.contains(resultName) {
                    inputs.insert(resultName)
                }
            }
            sideEffects.append("\(statement.action.verb):\(resultName)")

        case .export:
            break

        case .server:
            if !isKnownExternal(objectName) && !definedSymbols.contains(objectName) && !dependencies.contains(objectName) {
                if !isServiceObject(objectName) {
                    dependencies.insert(objectName)
                }
            }
            inputs.insert(objectName)
            outputs.insert(resultName)

            let dataType = TypeInferencer.inferResultType(statement)
            checkImmutabilityViolation(
                name: resultName, verb: statement.action.verb,
                objectName: objectName, preposition: statement.object.preposition,
                span: statement.result.span,
                definedSymbols: definedSymbols, inMutableScope: inMutableScope
            )

            builder.define(
                name: resultName,
                definedAt: statement.span,
                visibility: .internal,
                source: .computed,
                dataType: dataType
            )
            definedSymbols.insert(resultName)
        }

        return (
            DataFlowInfo(inputs: inputs, outputs: outputs, sideEffects: sideEffects),
            dependencies
        )
    }

    // MARK: - Immutability Check

    /// Checks whether rebinding a variable would violate immutability rules
    private func checkImmutabilityViolation(
        name: String,
        verb: String,
        objectName: String,
        preposition: Preposition,
        span: SourceSpan,
        definedSymbols: Set<String>,
        inMutableScope: Bool
    ) {
        if definedSymbols.contains(name) && !isInternalVariable(name) && !isRebindingAllowed(verb) && !inMutableScope {
            diagnostics.error(
                "Cannot rebind variable '\(name)' - variables are immutable",
                at: span.start,
                hints: [
                    "Variable '\(name)' was already defined earlier in this feature set",
                    "Create a new variable with a different name instead",
                    "Example: <\(verb)> the <\(name)-updated> \(preposition.rawValue) the <\(objectName)>"
                ]
            )
        }
    }

    // MARK: - Publish Statement

    private func analyzePublishStatement(
        _ statement: PublishStatement,
        builder: SymbolTableBuilder,
        definedSymbols: Set<String>
    ) -> (DataFlowInfo, Set<String>) {

        if !definedSymbols.contains(statement.internalVariable) {
            diagnostics.error(
                "Cannot publish undefined variable '\(statement.internalVariable)'",
                at: statement.span.start
            )
        }

        builder.updateVisibility(name: statement.internalVariable, to: .published)

        builder.define(
            name: statement.externalName,
            definedAt: statement.span,
            visibility: .published,
            source: .alias(of: statement.internalVariable)
        )

        return (
            DataFlowInfo(inputs: [statement.internalVariable], outputs: [statement.externalName]),
            []
        )
    }

    // MARK: - Require Statement

    private func analyzeRequireStatement(
        _ statement: RequireStatement,
        builder: SymbolTableBuilder
    ) -> (DataFlowInfo, Set<String>) {
        builder.define(
            name: statement.variableName,
            definedAt: statement.span,
            visibility: .external,
            source: .extracted(from: "\(statement.source)")
        )

        return (
            DataFlowInfo(inputs: [], outputs: [statement.variableName]),
            [statement.variableName]
        )
    }

    // MARK: - Match Statement (ARO-0004)

    private func analyzeMatchStatement(
        _ statement: MatchStatement,
        builder: SymbolTableBuilder,
        definedSymbols: inout Set<String>
    ) -> (DataFlowInfo, Set<String>) {
        var inputs: Set<String> = []
        var outputs: Set<String> = []
        var sideEffects: [String] = []
        var dependencies: Set<String> = []

        let subjectName = statement.subject.base
        if !definedSymbols.contains(subjectName) && !isKnownExternal(subjectName) {
            diagnostics.warning(
                "Variable '\(subjectName)' used in match before definition",
                at: statement.subject.span.start
            )
        }
        inputs.insert(subjectName)

        var branchDefinitions: [Set<String>] = []

        for caseClause in statement.cases {
            var branchSymbols = definedSymbols

            if let guard_ = caseClause.guardCondition {
                let guardVars = extractVariables(from: guard_)
                for varName in guardVars {
                    if !branchSymbols.contains(varName) && !isKnownExternal(varName) {
                        dependencies.insert(varName)
                    }
                    inputs.insert(varName)
                }
            }

            if case .variable(let noun) = caseClause.pattern {
                let patternName = noun.base
                if branchSymbols.contains(patternName) {
                    inputs.insert(patternName)
                }
            }

            for bodyStatement in caseClause.body {
                let (flow, newDeps) = analyzeStatement(
                    bodyStatement,
                    builder: builder,
                    definedSymbols: &branchSymbols
                )
                inputs.formUnion(flow.inputs)
                outputs.formUnion(flow.outputs)
                sideEffects.append(contentsOf: flow.sideEffects)
                dependencies.formUnion(newDeps)
            }

            branchDefinitions.append(branchSymbols.subtracting(definedSymbols))
        }

        if let otherwise = statement.otherwise {
            var branchSymbols = definedSymbols

            for bodyStatement in otherwise {
                let (flow, newDeps) = analyzeStatement(
                    bodyStatement,
                    builder: builder,
                    definedSymbols: &branchSymbols
                )
                inputs.formUnion(flow.inputs)
                outputs.formUnion(flow.outputs)
                sideEffects.append(contentsOf: flow.sideEffects)
                dependencies.formUnion(newDeps)
            }

            branchDefinitions.append(branchSymbols.subtracting(definedSymbols))
        }

        if !branchDefinitions.isEmpty {
            let allBranchSymbols = branchDefinitions.reduce(Set<String>()) { $0.union($1) }
            definedSymbols.formUnion(allBranchSymbols)
        }

        return (
            DataFlowInfo(inputs: inputs, outputs: outputs, sideEffects: sideEffects),
            dependencies
        )
    }

    // MARK: - For-Each Loop (ARO-0005)

    private func analyzeForEachLoop(
        _ statement: ForEachLoop,
        builder: SymbolTableBuilder,
        definedSymbols: inout Set<String>
    ) -> (DataFlowInfo, Set<String>) {
        var inputs: Set<String> = []
        var outputs: Set<String> = []
        var sideEffects: [String] = []
        var dependencies: Set<String> = []

        let collectionName = statement.collection.base
        if !definedSymbols.contains(collectionName) && !isKnownExternal(collectionName) {
            diagnostics.warning(
                "Collection '\(collectionName)' used in for-each before definition",
                at: statement.collection.span.start
            )
        }
        inputs.insert(collectionName)

        if let filter = statement.filter {
            let filterVars = extractVariables(from: filter)
            for varName in filterVars {
                if varName != statement.itemVariable && !definedSymbols.contains(varName) && !isKnownExternal(varName) {
                    dependencies.insert(varName)
                }
                inputs.insert(varName)
            }
        }

        var loopDefinedSymbols = definedSymbols

        builder.define(
            name: statement.itemVariable,
            definedAt: statement.span,
            visibility: .internal,
            source: .extracted(from: collectionName),
            dataType: .unknown
        )
        loopDefinedSymbols.insert(statement.itemVariable)

        if let indexVar = statement.indexVariable {
            builder.define(
                name: indexVar,
                definedAt: statement.span,
                visibility: .internal,
                source: .computed,
                dataType: .integer
            )
            loopDefinedSymbols.insert(indexVar)
        }

        if statement.isParallel {
            if let concurrency = statement.concurrency {
                sideEffects.append("parallel:concurrency=\(concurrency)")
            } else {
                sideEffects.append("parallel")
            }
        }

        for bodyStatement in statement.body {
            let (flow, newDeps) = analyzeStatement(
                bodyStatement,
                builder: builder,
                definedSymbols: &loopDefinedSymbols
            )
            inputs.formUnion(flow.inputs)
            outputs.formUnion(flow.outputs)
            sideEffects.append(contentsOf: flow.sideEffects)
            dependencies.formUnion(newDeps)
        }

        outputs.remove(statement.itemVariable)
        if let indexVar = statement.indexVariable {
            outputs.remove(indexVar)
        }

        return (
            DataFlowInfo(inputs: inputs, outputs: outputs, sideEffects: sideEffects),
            dependencies
        )
    }

    // MARK: - While Loop

    private func analyzeWhileLoop(
        _ statement: WhileLoop,
        builder: SymbolTableBuilder,
        definedSymbols: inout Set<String>
    ) -> (DataFlowInfo, Set<String>) {
        var inputs: Set<String> = []
        var outputs: Set<String> = []
        var sideEffects: [String] = []
        var dependencies: Set<String> = []

        let condVars = extractVariables(from: statement.condition)
        for varName in condVars {
            if !definedSymbols.contains(varName) && !isKnownExternal(varName) {
                dependencies.insert(varName)
            }
            inputs.insert(varName)
        }

        for bodyStatement in statement.body {
            let (flow, newDeps) = analyzeStatement(
                bodyStatement,
                builder: builder,
                definedSymbols: &definedSymbols,
                inMutableScope: true
            )
            inputs.formUnion(flow.inputs)
            outputs.formUnion(flow.outputs)
            sideEffects.append(contentsOf: flow.sideEffects)
            dependencies.formUnion(newDeps)
        }

        return (
            DataFlowInfo(inputs: inputs, outputs: outputs, sideEffects: sideEffects),
            dependencies
        )
    }

    // MARK: - Dependency Verification

    /// Verifies that external dependencies are published by some feature set
    public func verifyDependencies(_ analyzed: AnalyzedFeatureSet, globalRegistry: GlobalSymbolRegistry) {
        for dependency in analyzed.dependencies {
            if globalRegistry.lookup(dependency) == nil {
                if !isKnownExternal(dependency) {
                    diagnostics.warning(
                        "External dependency '\(dependency)' is not published by any feature set",
                        hints: ["Consider adding a <Publish> statement or marking it as framework-provided"]
                    )
                }
            }
        }
    }

    // MARK: - Duplicate Feature Set Detection

    /// Detects duplicate feature set names
    public func detectDuplicateFeatureSetNames(_ featureSets: [FeatureSet]) {
        var seen: [String: SourceLocation] = [:]

        for featureSet in featureSets {
            let key: String
            if featureSet.name == "Application-End" {
                key = "\(featureSet.name):\(featureSet.businessActivity)"
            } else {
                key = featureSet.name
            }

            if let firstLocation = seen[key] {
                diagnostics.error(
                    "Duplicate feature set name '\(featureSet.name)'",
                    at: featureSet.span.start,
                    hints: [
                        "A feature set with this name was already defined at line \(firstLocation.line)",
                        "Each feature set must have a unique name"
                    ]
                )
            } else {
                seen[key] = featureSet.span.start
            }
        }
    }

    // MARK: - Aggregation Fusion Detection (ARO-0051)

    private func detectAggregationFusions(_ statements: [Statement]) -> [AggregationFusionGroup] {
        var reducesBySource: [String: [(index: Int, output: String, function: String, field: String?)]] = [:]

        for (index, statement) in statements.enumerated() {
            guard let aro = statement as? AROStatement,
                  aro.action.verb.lowercased() == "reduce" else {
                continue
            }

            let source = aro.object.noun.base
            let output = aro.result.base
            let (function, field) = parseAggregationFunction(aro)

            reducesBySource[source, default: []].append((index, output, function, field))
        }

        var fusions: [AggregationFusionGroup] = []

        for (source, reduces) in reducesBySource where reduces.count > 1 {
            let operations = reduces.map { AggregationOperation(output: $0.output, function: $0.function, field: $0.field) }
            let indices = reduces.map { $0.index }

            fusions.append(AggregationFusionGroup(
                source: source,
                operations: operations,
                statementIndices: indices
            ))
        }

        return fusions
    }

    private func parseAggregationFunction(_ statement: AROStatement) -> (function: String, field: String?) {
        if let aggregation = statement.queryModifiers.aggregation {
            return (aggregation.type.rawValue, aggregation.field)
        }

        if let typeAnnotation = statement.result.typeAnnotation {
            let lower = typeAnnotation.lowercased()
            if ["sum", "count", "avg", "min", "max", "first", "last"].contains(lower) {
                return (lower, nil)
            }
        }

        return ("unknown", nil)
    }

    // MARK: - Stream Consumer Detection (ARO-0051)

    private func detectStreamConsumers(_ dataFlows: [DataFlowInfo], statements: [Statement]) -> [StreamConsumerInfo] {
        var inputCounts: [String: [Int]] = [:]

        for (index, flow) in dataFlows.enumerated() {
            for input in flow.inputs {
                inputCounts[input, default: []].append(index)
            }
        }

        var consumers: [StreamConsumerInfo] = []

        for (variable, indices) in inputCounts where indices.count > 1 {
            if isKnownExternal(variable) { continue }

            consumers.append(StreamConsumerInfo(
                variable: variable,
                consumerCount: indices.count,
                consumerIndices: indices
            ))
        }

        return consumers
    }

    // MARK: - Expression Analysis

    /// Extracts variable names referenced in an expression
    private func extractVariables(from expression: any Expression) -> Set<String> {
        var variables: Set<String> = []
        collectVariables(expression, into: &variables)
        return variables
    }

    private func collectVariables(_ expr: any Expression, into variables: inout Set<String>) {
        switch expr {
        case let varRef as VariableRefExpression:
            variables.insert(varRef.noun.base)

        case let binary as BinaryExpression:
            collectVariables(binary.left, into: &variables)
            collectVariables(binary.right, into: &variables)

        case let unary as UnaryExpression:
            collectVariables(unary.operand, into: &variables)

        case let member as MemberAccessExpression:
            collectVariables(member.base, into: &variables)

        case let subscript_ as SubscriptExpression:
            collectVariables(subscript_.base, into: &variables)
            collectVariables(subscript_.index, into: &variables)

        case let grouped as GroupedExpression:
            collectVariables(grouped.expression, into: &variables)

        case let existence as ExistenceExpression:
            collectVariables(existence.expression, into: &variables)

        case let typeCheck as TypeCheckExpression:
            collectVariables(typeCheck.expression, into: &variables)

        case let array as ArrayLiteralExpression:
            for element in array.elements {
                collectVariables(element, into: &variables)
            }

        case let map as MapLiteralExpression:
            for entry in map.entries {
                collectVariables(entry.value, into: &variables)
            }

        case let interp as InterpolatedStringExpression:
            for part in interp.parts {
                if case .interpolation(let expr) = part {
                    collectVariables(expr, into: &variables)
                }
            }

        default:
            break
        }
    }

    // MARK: - Helper Predicates

    private func isInternalVariable(_ name: String) -> Bool {
        name.hasPrefix("_")
    }

    private func isRebindingAllowed(_ verb: String) -> Bool {
        let rebindingVerbs: Set<String> = [
            "accept", "update", "modify", "change", "set",
            "merge", "combine", "join", "concat",
            "then", "assert",
            "clear", "show"
        ]
        return rebindingVerbs.contains(verb.lowercased())
    }

    func isKnownExternal(_ name: String) -> Bool {
        let knownExternals: Set<String> = [
            "request", "incoming-request", "context", "session",
            "pathparameters", "queryparameters", "headers",
            "console", "application", "event", "shutdown",
            "port", "host", "directory", "file", "events", "contract", "template",
            "repository",
            // Framework-provided runtime objects
            "parameter",   // CLI arguments via `<parameter: name>` / `<parameter>`
            "input",       // user-defined action arguments via `<input: name>`
            "path",        // file qualifier (`<file: path>` resolves a string variable to a fs path)
            "_literal_",
            "_expression_"
        ]
        if name.lowercased().hasSuffix("-repository") {
            return true
        }
        return knownExternals.contains(name.lowercased())
    }

    private func isServiceObject(_ name: String) -> Bool {
        let serviceObjects: Set<String> = [
            "http-server", "socket-server", "file-monitor", "websocket-server",
            "connection", "server-connection", "client-connection",
            "file", "directory", "path",
            "application", "events", "shutdown-signal"
        ]
        let lower = name.lowercased()
        if serviceObjects.contains(lower) {
            return true
        }
        if lower.hasSuffix("-server") || lower.hasSuffix("-connection") || lower.hasSuffix("-monitor") {
            return true
        }
        return false
    }

    private func isSideEffectBinding(_ name: String) -> Bool {
        let sideEffectPatterns: Set<String> = [
            "http-server", "http-client", "server", "client",
            "file-monitor", "file-watcher",
            "database-connections", "database", "db-connection",
            "socket-server", "socket-client",
            "log-buffer", "cache",
            "application"
        ]
        return sideEffectPatterns.contains(name.lowercased())
    }

    /// Flatten a statement tree (descending into `match` cases and
    /// `for-each` bodies) into the contained AROStatements. Used so
    /// side-effect / template-renders / qualifier-base checks see every
    /// action in the feature set, not just the top-level ones.
    private func collectAROStatements(_ statements: [Statement]) -> [AROStatement] {
        var out: [AROStatement] = []
        for stmt in statements {
            if let aro = stmt as? AROStatement {
                out.append(aro)
            } else if let m = stmt as? MatchStatement {
                for c in m.cases {
                    out.append(contentsOf: collectAROStatements(c.body))
                }
                out.append(contentsOf: collectAROStatements(m.otherwise ?? []))
            } else if let loop = stmt as? ForEachLoop {
                out.append(contentsOf: collectAROStatements(loop.body))
            }
        }
        return out
    }

    /// Verbs whose "result" is really just a confirmation handle for a
    /// side-effecting action — the value rarely needs reading because
    /// the point of the statement is what it *did*, not what it returns.
    private func isSideEffectVerb(_ verb: String) -> Bool {
        let v = verb.lowercased()
        // Plugin / user-defined action calls (`Application.X`,
        // `MyPlugin.DoThing`) — these are dispatched by name and almost
        // always called for their effect.
        if v.contains(".") { return true }
        let sideEffectVerbs: Set<String> = [
            "make", "append", "write", "copy", "move", "delete",
            "log", "emit", "send", "notify", "publish", "store",
            "schedule", "start", "stop", "listen", "keepalive",
            "render", "show", "repaint", "clear",
            "broadcast", "close", "connect"
        ]
        return sideEffectVerbs.contains(v)
    }

    private func looksLikeVariable(_ name: String) -> Bool {
        if name.contains("-") {
            return true
        }
        if name == name.lowercased() && !name.isEmpty {
            return true
        }
        return false
    }
}
