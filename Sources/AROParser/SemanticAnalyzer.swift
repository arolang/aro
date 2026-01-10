// ============================================================
// SemanticAnalyzer.swift
// ARO Parser - Semantic Analysis
// ============================================================

import Foundation

// MARK: - Data Flow Info

/// Information about data flow in a statement
public struct DataFlowInfo: Sendable, Equatable, CustomStringConvertible {
    public let inputs: Set<String>      // Variables consumed
    public let outputs: Set<String>     // Variables produced
    public let sideEffects: [String]    // External effects
    
    public init(inputs: Set<String> = [], outputs: Set<String> = [], sideEffects: [String] = []) {
        self.inputs = inputs
        self.outputs = outputs
        self.sideEffects = sideEffects
    }
    
    public var description: String {
        "DataFlow(in: \(inputs), out: \(outputs), effects: \(sideEffects))"
    }
}

// MARK: - Analyzed Feature Set

/// A feature set with semantic annotations
public struct AnalyzedFeatureSet: Sendable {
    public let featureSet: FeatureSet
    public let symbolTable: SymbolTable
    public let dataFlows: [DataFlowInfo]
    public let dependencies: Set<String>    // External dependencies
    public let exports: Set<String>         // Published symbols
    
    public init(
        featureSet: FeatureSet,
        symbolTable: SymbolTable,
        dataFlows: [DataFlowInfo],
        dependencies: Set<String>,
        exports: Set<String>
    ) {
        self.featureSet = featureSet
        self.symbolTable = symbolTable
        self.dataFlows = dataFlows
        self.dependencies = dependencies
        self.exports = exports
    }
}

// MARK: - Analyzed Program

/// A fully analyzed program
public struct AnalyzedProgram: Sendable {
    public let program: Program
    public let featureSets: [AnalyzedFeatureSet]
    public let globalRegistry: GlobalSymbolRegistry
    
    public init(program: Program, featureSets: [AnalyzedFeatureSet], globalRegistry: GlobalSymbolRegistry) {
        self.program = program
        self.featureSets = featureSets
        self.globalRegistry = globalRegistry
    }
}

// MARK: - Semantic Analyzer

/// Performs semantic analysis on the AST
public final class SemanticAnalyzer {
    
    // MARK: - Properties
    
    private let diagnostics: DiagnosticCollector
    private let globalRegistry: GlobalSymbolRegistry
    
    // MARK: - Initialization
    
    public init(diagnostics: DiagnosticCollector = DiagnosticCollector()) {
        self.diagnostics = diagnostics
        self.globalRegistry = GlobalSymbolRegistry()
    }
    
    // MARK: - Public Interface
    
    /// Analyzes the entire program
    public func analyze(_ program: Program) -> AnalyzedProgram {
        var analyzedSets: [AnalyzedFeatureSet] = []

        // Check for duplicate feature set names
        detectDuplicateFeatureSetNames(program.featureSets)

        for featureSet in program.featureSets {
            let analyzed = analyzeFeatureSet(featureSet)
            analyzedSets.append(analyzed)

            // Register published symbols
            for symbol in analyzed.symbolTable.publishedSymbols.values {
                globalRegistry.register(symbol: symbol, fromFeatureSet: featureSet.name)
            }
        }

        // Second pass: verify external dependencies
        for analyzed in analyzedSets {
            verifyDependencies(analyzed)
        }

        // Third pass: detect circular event chains
        detectCircularEventChains(analyzedSets)

        // Fourth pass: detect orphaned event emissions
        detectOrphanedEventEmissions(analyzedSets)

        return AnalyzedProgram(
            program: program,
            featureSets: analyzedSets,
            globalRegistry: globalRegistry
        )
    }
    
    // MARK: - Feature Set Analysis
    
    private func analyzeFeatureSet(_ featureSet: FeatureSet) -> AnalyzedFeatureSet {
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

            // Handle RequireStatement (ARO-0003)
            if let require = statement as? RequireStatement {
                dependencies.insert(require.variableName)
            }
        }

        // Check for code quality issues (empty, unreachable code, missing return)
        checkCodeQuality(featureSet)

        // Detect unused variables (ARO-0003)
        let symbolTable = builder.build()
        var usedVariables: Set<String> = []
        for flow in dataFlows {
            usedVariables.formUnion(flow.inputs)
        }

        for (name, symbol) in symbolTable.symbols {
            // Skip published variables (they're used externally)
            if symbol.visibility == .published { continue }
            // Skip aliases (the original is tracked)
            if case .alias = symbol.source { continue }
            // Skip external dependencies
            if symbol.visibility == .external { continue }

            // Skip service bindings that are side-effect producing
            // (e.g., http-server, file-monitor, database-connections)
            if isSideEffectBinding(name) { continue }

            if !usedVariables.contains(name) {
                diagnostics.warning(
                    "Variable '\(name)' is defined but never used",
                    at: symbol.definedAt.start
                )
            }
        }

        return AnalyzedFeatureSet(
            featureSet: featureSet,
            symbolTable: symbolTable,
            dataFlows: dataFlows,
            dependencies: dependencies,
            exports: exports
        )
    }

    // MARK: - Statement Analysis

    /// Check if variable name is framework-internal (exempt from immutability)
    private func isInternalVariable(_ name: String) -> Bool {
        return name.hasPrefix("_")
    }

    /// Check if action verb is allowed to rebind variables (exempt from immutability)
    /// Accept and Update actions need to rebind for state transitions
    private func isRebindingAllowed(_ verb: String) -> Bool {
        let rebindingVerbs: Set<String> = ["accept", "update", "modify", "change", "set"]
        return rebindingVerbs.contains(verb.lowercased())
    }

    private func analyzeStatement(
        _ statement: Statement,
        builder: SymbolTableBuilder,
        definedSymbols: inout Set<String>
    ) -> (DataFlowInfo, Set<String>) {
        
        if let aro = statement as? AROStatement {
            return analyzeAROStatement(aro, builder: builder, definedSymbols: &definedSymbols)
        }
        
        if let publish = statement as? PublishStatement {
            return analyzePublishStatement(publish, builder: builder, definedSymbols: definedSymbols)
        }

        if let require = statement as? RequireStatement {
            return analyzeRequireStatement(require, builder: builder)
        }

        // ARO-0004: Match statement
        if let match = statement as? MatchStatement {
            return analyzeMatchStatement(match, builder: builder, definedSymbols: &definedSymbols)
        }

        // ARO-0005: For-each loop
        if let forEach = statement as? ForEachLoop {
            return analyzeForEachLoop(forEach, builder: builder, definedSymbols: &definedSymbols)
        }

        return (DataFlowInfo(), [])
    }
    
    private func analyzeAROStatement(
        _ statement: AROStatement,
        builder: SymbolTableBuilder,
        definedSymbols: inout Set<String>
    ) -> (DataFlowInfo, Set<String>) {

        var inputs: Set<String> = []
        var outputs: Set<String> = []
        var sideEffects: [String] = []
        var dependencies: Set<String> = []

        let resultName = statement.result.base
        let objectName = statement.object.noun.base

        // Track object qualifier as input if it looks like a variable reference
        // (e.g., <file: file-path> where file-path is a variable)
        if let objectQualifier = statement.object.noun.typeAnnotation,
           looksLikeVariable(objectQualifier) {
            inputs.insert(objectQualifier)
        }

        // ARO-0002: Extract variables from expression if present
        if let expr = statement.expression {
            let exprVars = extractVariables(from: expr)
            for varName in exprVars {
                if !definedSymbols.contains(varName) && !isKnownExternal(varName) {
                    dependencies.insert(varName)
                }
                inputs.insert(varName)
            }
        }

        // ARO-0004: Extract variables from when condition if present
        if let whenExpr = statement.whenCondition {
            let condVars = extractVariables(from: whenExpr)
            for varName in condVars {
                if !definedSymbols.contains(varName) && !isKnownExternal(varName) {
                    dependencies.insert(varName)
                }
                inputs.insert(varName)
            }
        }

        // ARO-0018: Extract variables from where clause if present
        if let whereClause = statement.whereClause {
            let whereVars = extractVariables(from: whereClause.value)
            for varName in whereVars {
                if !definedSymbols.contains(varName) && !isKnownExternal(varName) {
                    dependencies.insert(varName)
                }
                inputs.insert(varName)
            }
        }

        // Determine data flow based on action semantic role
        switch statement.action.semanticRole {
        case .request:
            // REQUEST: external -> internal
            // Creates a new variable from external source
            if !isKnownExternal(objectName) && !definedSymbols.contains(objectName) {
                dependencies.insert(objectName)
            }
            inputs.insert(objectName)
            outputs.insert(resultName)

            // ARO-0006: Infer type from type annotation or expression
            let dataType: DataType
            if let annotatedType = statement.result.dataType {
                dataType = annotatedType
            } else if let expr = statement.expression {
                dataType = inferExpressionType(expr)
            } else {
                dataType = .unknown
            }

            // Check for duplicate binding (immutability enforcement)
            // Exempt Accept and Update actions which need to rebind for state transitions
            if definedSymbols.contains(resultName) && !isInternalVariable(resultName) && !isRebindingAllowed(statement.action.verb) {
                diagnostics.error(
                    "Cannot rebind variable '\(resultName)' - variables are immutable",
                    at: statement.result.span.start,
                    hints: [
                        "Variable '\(resultName)' was already defined earlier in this feature set",
                        "Create a new variable with a different name instead",
                        "Example: <\(statement.action.verb)> the <\(resultName)-updated> \(statement.object.preposition.rawValue) the <\(objectName)>"
                    ]
                )
            }

            builder.define(
                name: resultName,
                definedAt: statement.span,
                visibility: .internal,
                source: .extracted(from: objectName),
                dataType: dataType
            )
            definedSymbols.insert(resultName)

        case .own:
            // OWN: internal computation
            // Uses existing variables, may create new one
            if !isKnownExternal(objectName) && !definedSymbols.contains(objectName) && !dependencies.contains(objectName) {
                diagnostics.warning(
                    "Variable '\(objectName)' used before definition",
                    at: statement.object.noun.span.start
                )
            }
            inputs.insert(objectName)
            outputs.insert(resultName)

            // ARO-0006: Infer type from type annotation or expression
            let dataType: DataType
            if let annotatedType = statement.result.dataType {
                dataType = annotatedType
            } else if let expr = statement.expression {
                dataType = inferExpressionType(expr)
            } else {
                dataType = .unknown
            }

            // Check for duplicate binding (immutability enforcement)
            // Exempt Accept and Update actions which need to rebind for state transitions
            if definedSymbols.contains(resultName) && !isInternalVariable(resultName) && !isRebindingAllowed(statement.action.verb) {
                diagnostics.error(
                    "Cannot rebind variable '\(resultName)' - variables are immutable",
                    at: statement.result.span.start,
                    hints: [
                        "Variable '\(resultName)' was already defined earlier in this feature set",
                        "Create a new variable with a different name instead",
                        "Example: <\(statement.action.verb)> the <\(resultName)-updated> \(statement.object.preposition.rawValue) the <\(objectName)>"
                    ]
                )
            }

            builder.define(
                name: resultName,
                definedAt: statement.span,
                visibility: .internal,
                source: .computed,
                dataType: dataType
            )
            definedSymbols.insert(resultName)

        case .response:
            // RESPONSE: internal -> external
            // Side effect. For Return/Throw, the object is typically a semantic label
            // (e.g., "for the <startup>"), not a variable requiring definition.
            // We don't warn about undefined objects in response actions.
            if definedSymbols.contains(objectName) || isKnownExternal(objectName) {
                inputs.insert(objectName)
            }
            // For Store/Write/Emit/Save actions, the result is the data being exported,
            // so it should be tracked as an input (being used)
            let exportDataVerbs = ["store", "write", "emit", "save", "persist", "send"]
            if exportDataVerbs.contains(statement.action.verb.lowercased()) {
                if definedSymbols.contains(resultName) {
                    inputs.insert(resultName)
                }
            }
            sideEffects.append("\(statement.action.verb):\(resultName)")

        case .export:
            // Handled by PublishStatement
            break
        }

        return (
            DataFlowInfo(inputs: inputs, outputs: outputs, sideEffects: sideEffects),
            dependencies
        )
    }
    
    private func analyzePublishStatement(
        _ statement: PublishStatement,
        builder: SymbolTableBuilder,
        definedSymbols: Set<String>
    ) -> (DataFlowInfo, Set<String>) {
        
        // Verify the internal variable exists
        if !definedSymbols.contains(statement.internalVariable) {
            diagnostics.error(
                "Cannot publish undefined variable '\(statement.internalVariable)'",
                at: statement.span.start
            )
        }
        
        // Update visibility of the internal variable
        builder.updateVisibility(name: statement.internalVariable, to: .published)
        
        // Create alias for external name
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

    private func analyzeRequireStatement(
        _ statement: RequireStatement,
        builder: SymbolTableBuilder
    ) -> (DataFlowInfo, Set<String>) {
        // Register as an external dependency
        builder.define(
            name: statement.variableName,
            definedAt: statement.span,
            visibility: .external,
            source: .extracted(from: "\(statement.source)")
        )

        // The variable is treated as an input from external source
        return (
            DataFlowInfo(inputs: [], outputs: [statement.variableName]),
            [statement.variableName]
        )
    }

    // ARO-0004: Analyze match statement
    private func analyzeMatchStatement(
        _ statement: MatchStatement,
        builder: SymbolTableBuilder,
        definedSymbols: inout Set<String>
    ) -> (DataFlowInfo, Set<String>) {
        var inputs: Set<String> = []
        var outputs: Set<String> = []
        var sideEffects: [String] = []
        var dependencies: Set<String> = []

        // The subject variable must be defined
        let subjectName = statement.subject.base
        if !definedSymbols.contains(subjectName) && !isKnownExternal(subjectName) {
            diagnostics.warning(
                "Variable '\(subjectName)' used in match before definition",
                at: statement.subject.span.start
            )
        }
        inputs.insert(subjectName)

        // Track symbols defined in each branch separately
        // Match branches are mutually exclusive, so defining the same symbol
        // in different branches is allowed (no rebinding violation)
        var branchDefinitions: [Set<String>] = []

        // Analyze each case clause with a branch-local copy of definedSymbols
        for caseClause in statement.cases {
            // Start with the current definedSymbols for this branch
            var branchSymbols = definedSymbols

            // Extract variables from guard condition if present
            if let guard_ = caseClause.guardCondition {
                let guardVars = extractVariables(from: guard_)
                for varName in guardVars {
                    if !branchSymbols.contains(varName) && !isKnownExternal(varName) {
                        dependencies.insert(varName)
                    }
                    inputs.insert(varName)
                }
            }

            // Extract variables from pattern if it's a variable pattern
            if case .variable(let noun) = caseClause.pattern {
                // Variable patterns can reference existing variables for comparison
                let patternName = noun.base
                if branchSymbols.contains(patternName) {
                    inputs.insert(patternName)
                }
            }

            // Analyze body statements with branch-local symbols
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

            // Track what this branch defined (new symbols not in original definedSymbols)
            branchDefinitions.append(branchSymbols.subtracting(definedSymbols))
        }

        // Analyze otherwise clause if present
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

        // After match: symbols defined in ALL branches are definitely defined
        // Symbols defined in SOME branches are potentially defined (we add them too
        // since we need to track them for use after the match)
        if !branchDefinitions.isEmpty {
            // Union of all branch definitions - any symbol defined in any branch
            // is considered defined after the match for subsequent code
            let allBranchSymbols = branchDefinitions.reduce(Set<String>()) { $0.union($1) }
            definedSymbols.formUnion(allBranchSymbols)
        }

        return (
            DataFlowInfo(inputs: inputs, outputs: outputs, sideEffects: sideEffects),
            dependencies
        )
    }

    // ARO-0005: Analyze for-each loop
    private func analyzeForEachLoop(
        _ statement: ForEachLoop,
        builder: SymbolTableBuilder,
        definedSymbols: inout Set<String>
    ) -> (DataFlowInfo, Set<String>) {
        var inputs: Set<String> = []
        var outputs: Set<String> = []
        var sideEffects: [String] = []
        var dependencies: Set<String> = []

        // The collection variable must be defined
        let collectionName = statement.collection.base
        if !definedSymbols.contains(collectionName) && !isKnownExternal(collectionName) {
            diagnostics.warning(
                "Collection '\(collectionName)' used in for-each before definition",
                at: statement.collection.span.start
            )
        }
        inputs.insert(collectionName)

        // Extract variables from filter condition if present
        if let filter = statement.filter {
            let filterVars = extractVariables(from: filter)
            for varName in filterVars {
                // Allow the item variable to be used in filter
                if varName != statement.itemVariable && !definedSymbols.contains(varName) && !isKnownExternal(varName) {
                    dependencies.insert(varName)
                }
                inputs.insert(varName)
            }
        }

        // Create a new scope for the loop body
        // The item variable is scoped to the loop body (shadows outer scope)
        var loopDefinedSymbols = definedSymbols

        // Define item variable in loop scope
        builder.define(
            name: statement.itemVariable,
            definedAt: statement.span,
            visibility: .internal,
            source: .extracted(from: collectionName),
            dataType: .unknown
        )
        loopDefinedSymbols.insert(statement.itemVariable)

        // Define index variable if present
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

        // Add parallel/concurrency as side effects
        if statement.isParallel {
            if let concurrency = statement.concurrency {
                sideEffects.append("parallel:concurrency=\(concurrency)")
            } else {
                sideEffects.append("parallel")
            }
        }

        // Analyze body statements
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

        // Remove loop-scoped variables from outputs (they don't escape the loop)
        outputs.remove(statement.itemVariable)
        if let indexVar = statement.indexVariable {
            outputs.remove(indexVar)
        }

        return (
            DataFlowInfo(inputs: inputs, outputs: outputs, sideEffects: sideEffects),
            dependencies
        )
    }

    // MARK: - Dependency Verification
    
    private func verifyDependencies(_ analyzed: AnalyzedFeatureSet) {
        for dependency in analyzed.dependencies {
            // Check if this dependency is published by another feature set
            if globalRegistry.lookup(dependency) == nil {
                // Check if it's a known external (framework-provided)
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
    /// Note: Application-End handlers use both name and business activity to allow
    /// Application-End: Success and Application-End: Error to coexist.
    private func detectDuplicateFeatureSetNames(_ featureSets: [FeatureSet]) {
        var seen: [String: SourceLocation] = [:]

        for featureSet in featureSets {
            // For Application-End handlers, include business activity in the key
            // to allow both Application-End: Success and Application-End: Error
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

    // MARK: - Circular Event Chain Detection

    /// Detects circular event chains that would cause infinite loops at runtime
    private func detectCircularEventChains(_ featureSets: [AnalyzedFeatureSet]) {
        let analyzer = EventChainAnalyzer()
        let cycles = analyzer.detectCycles(in: featureSets)

        for cycle in cycles {
            diagnostics.error(
                "Circular event chain detected: \(cycle.description)",
                at: cycle.location,
                hints: [
                    "Event handlers form an infinite loop that will exhaust resources",
                    "Consider breaking the chain by using different event types or adding termination conditions"
                ]
            )
        }
    }

    // MARK: - Orphaned Event Detection

    /// Detects events that are emitted but have no corresponding handler
    private func detectOrphanedEventEmissions(_ featureSets: [AnalyzedFeatureSet]) {
        // Collect all handled event types
        var handledEvents: Set<String> = []
        for analyzed in featureSets {
            let activity = analyzed.featureSet.businessActivity
            if activity.hasSuffix(" Handler") {
                // Extract event type from handler name
                let eventType = activity
                    .replacingOccurrences(of: " Handler", with: "")
                    .trimmingCharacters(in: .whitespaces)

                // Exclude system handlers
                if eventType != "Socket Event" && eventType != "File Event" {
                    handledEvents.insert(eventType)
                }
            }
        }

        // Collect all emitted events and check for orphans
        for analyzed in featureSets {
            let emittedEvents = findEmittedEventsWithLocations(in: analyzed.featureSet.statements)

            for (eventType, location) in emittedEvents {
                if !handledEvents.contains(eventType) {
                    diagnostics.warning(
                        "Event '\(eventType)' is emitted but no handler exists",
                        at: location,
                        hints: [
                            "Create a handler with business activity '\(eventType) Handler'",
                            "Or remove this Emit statement if the event is not needed"
                        ]
                    )
                }
            }
        }
    }

    /// Finds all emitted events with their source locations
    private func findEmittedEventsWithLocations(in statements: [Statement]) -> [(String, SourceLocation)] {
        var events: [(String, SourceLocation)] = []

        for statement in statements {
            collectEmittedEventsWithLocations(from: statement, into: &events)
        }

        return events
    }

    /// Recursively collects emitted events with locations from a statement
    private func collectEmittedEventsWithLocations(from statement: Statement, into events: inout [(String, SourceLocation)]) {
        if let aro = statement as? AROStatement {
            if aro.action.verb.lowercased() == "emit" {
                events.append((aro.result.base, aro.span.start))
            }
        }

        if let match = statement as? MatchStatement {
            for caseClause in match.cases {
                for bodyStatement in caseClause.body {
                    collectEmittedEventsWithLocations(from: bodyStatement, into: &events)
                }
            }
            if let otherwise = match.otherwise {
                for bodyStatement in otherwise {
                    collectEmittedEventsWithLocations(from: bodyStatement, into: &events)
                }
            }
        }

        if let forEach = statement as? ForEachLoop {
            for bodyStatement in forEach.body {
                collectEmittedEventsWithLocations(from: bodyStatement, into: &events)
            }
        }
    }

    // MARK: - Code Quality Checks

    /// Checks for code quality issues in a feature set
    private func checkCodeQuality(_ featureSet: FeatureSet) {
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

        // Check for unreachable code after Return/Throw
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
                if verb == "return" || verb == "throw" {
                    foundTerminator = true
                    terminatorLocation = aro.span.start
                }
            }
        }

        // Check for missing Return statement (excluding Application-End handlers)
        let activity = featureSet.businessActivity
        let isLifecycleHandler = activity.hasPrefix("Application-End")

        if !isLifecycleHandler && !foundTerminator {
            // Check if there's any Return/Throw in the code
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

    private func isKnownExternal(_ name: String) -> Bool {
        // These are typically provided by the framework/runtime
        let knownExternals: Set<String> = [
            // HTTP/Request context
            "request", "incoming-request", "context", "session",
            "pathparameters", "queryparameters", "headers",
            // Runtime objects
            "console", "application", "event", "shutdown",
            // Service targets
            "port", "host", "directory", "file", "events", "contract",
            // Repository pattern (any *-repository is external)
            "repository",
            // Literals (internal representation)
            "_literal_",
            // Expression placeholders (ARO-0002)
            "_expression_"
        ]
        // Also treat anything ending in "-repository" as external
        if name.lowercased().hasSuffix("-repository") {
            return true
        }
        return knownExternals.contains(name.lowercased())
    }

    /// Determines if a variable name represents a side-effect producing binding.
    /// These are service bindings that are defined but "used" through their side effects.
    private func isSideEffectBinding(_ name: String) -> Bool {
        let sideEffectPatterns: Set<String> = [
            // HTTP server/client
            "http-server", "http-client", "server", "client",
            // File system
            "file-monitor", "file-watcher",
            // Database
            "database-connections", "database", "db-connection",
            // Sockets
            "socket-server", "socket-client",
            // Buffers/caches
            "log-buffer", "cache",
            // Application lifecycle
            "application"
        ]
        return sideEffectPatterns.contains(name.lowercased())
    }

    /// Determines if a qualifier looks like a variable reference rather than a type name.
    /// Variable references typically use kebab-case (contain hyphens) while type names use PascalCase.
    private func looksLikeVariable(_ name: String) -> Bool {
        // Contains hyphen = likely a variable (e.g., "file-path", "user-id")
        if name.contains("-") {
            return true
        }
        // All lowercase = likely a variable (e.g., "path", "id")
        if name == name.lowercased() && !name.isEmpty {
            return true
        }
        // PascalCase or contains special chars like < = likely a type (e.g., "String", "List<User>")
        return false
    }

    // MARK: - Expression Analysis (ARO-0002)

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
            // Literals don't have variables
            break
        }
    }

    /// Infers the type of an expression (ARO-0006)
    private func inferExpressionType(_ expr: any Expression) -> DataType {
        switch expr {
        case let literal as LiteralExpression:
            switch literal.value {
            case .string: return .string
            case .integer: return .integer
            case .float: return .float
            case .boolean: return .boolean
            case .null: return .unknown
            case .array: return .list(.unknown)
            case .object: return .map(key: .string, value: .unknown)
            case .regex: return .string  // Regex patterns are treated as string type for matching
            }

        case is ArrayLiteralExpression:
            return .list(.unknown)

        case is MapLiteralExpression:
            return .map(key: .string, value: .unknown)

        case let binary as BinaryExpression:
            // Infer type based on operator
            switch binary.op {
            case .add, .subtract, .multiply, .divide, .modulo:
                return .float  // Numeric operations return Float
            case .concat:
                return .string
            case .equal, .notEqual, .lessThan, .greaterThan, .lessEqual, .greaterEqual,
                 .and, .or, .contains, .matches, .is, .isNot:
                return .boolean
            }

        case is UnaryExpression:
            return .unknown

        case is VariableRefExpression:
            return .unknown

        case is TypeCheckExpression, is ExistenceExpression:
            return .boolean

        case is InterpolatedStringExpression:
            return .string

        default:
            return .unknown
        }
    }
}

// MARK: - Convenience Extension

extension SemanticAnalyzer {
    /// Analyzes source code in one step
    public static func analyze(_ source: String, diagnostics: DiagnosticCollector = DiagnosticCollector()) throws -> AnalyzedProgram {
        let program = try Parser.parse(source, diagnostics: diagnostics)
        return SemanticAnalyzer(diagnostics: diagnostics).analyze(program)
    }
}
