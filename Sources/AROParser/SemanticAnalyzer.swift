// ============================================================
// SemanticAnalyzer.swift
// ARO Parser - Semantic Analysis Orchestrator
//
// Delegates to focused validators:
//   - DataFlowAnalyzer:      Symbol tables, data flow, dependencies
//   - EventAnalyzer:         Circular chains, orphaned emissions
//   - CodeQualityValidator:  Empty sets, unreachable code, missing returns
//   - TypeInferencer:        Expression and statement type inference
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

// MARK: - Aggregation Fusion (ARO-0051)

/// Represents a single aggregation operation in a fusion group
public struct AggregationOperation: Sendable, Equatable {
    public let output: String
    public let function: String
    public let field: String?

    public init(output: String, function: String, field: String?) {
        self.output = output
        self.function = function
        self.field = field
    }
}

/// Represents a group of Reduce operations that can be fused into a single pass
public struct AggregationFusionGroup: Sendable, Equatable {
    /// The source variable being reduced
    public let source: String

    /// The reduce operations (output variable → aggregation function)
    public let operations: [AggregationOperation]

    /// Statement indices in the feature set
    public let statementIndices: [Int]

    public init(source: String, operations: [AggregationOperation], statementIndices: [Int]) {
        self.source = source
        self.operations = operations
        self.statementIndices = statementIndices
    }
}

// MARK: - Stream Consumer Info (ARO-0051)

/// Tracks how many times a stream variable is consumed
public struct StreamConsumerInfo: Sendable, Equatable {
    /// The stream variable name
    public let variable: String

    /// Number of consumers (statements that use this variable)
    public let consumerCount: Int

    /// Statement indices that consume this stream
    public let consumerIndices: [Int]

    /// Whether this requires stream teeing (multiple diverse consumers)
    public var requiresTee: Bool { consumerCount > 1 }

    public init(variable: String, consumerCount: Int, consumerIndices: [Int]) {
        self.variable = variable
        self.consumerCount = consumerCount
        self.consumerIndices = consumerIndices
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

    // ARO-0051: Streaming optimizations
    public let aggregationFusions: [AggregationFusionGroup]  // Groups of fusible reduces
    public let streamConsumers: [StreamConsumerInfo]          // Multi-consumer streams

    public init(
        featureSet: FeatureSet,
        symbolTable: SymbolTable,
        dataFlows: [DataFlowInfo],
        dependencies: Set<String>,
        exports: Set<String>,
        aggregationFusions: [AggregationFusionGroup] = [],
        streamConsumers: [StreamConsumerInfo] = []
    ) {
        self.featureSet = featureSet
        self.symbolTable = symbolTable
        self.dataFlows = dataFlows
        self.dependencies = dependencies
        self.exports = exports
        self.aggregationFusions = aggregationFusions
        self.streamConsumers = streamConsumers
    }
}

// MARK: - Analyzed Program

/// A fully analyzed program
public struct AnalyzedProgram: Sendable {
    public let program: Program
    public let featureSets: [AnalyzedFeatureSet]
    public let globalRegistry: GlobalSymbolRegistry

    /// Feature sets grouped by business activity string.
    public let byActivity: [String: [AnalyzedFeatureSet]]

    /// Feature sets indexed by name for O(1) lookup (e.g. by HTTP operationId).
    public let byName: [String: AnalyzedFeatureSet]

    // MARK: - Pre-computed handler category indexes

    /// Feature sets whose business activity contains "Socket Event Handler".
    public let socketHandlers: [AnalyzedFeatureSet]
    /// Feature sets whose business activity contains "WebSocket Event Handler".
    public let webSocketHandlers: [AnalyzedFeatureSet]
    /// Feature sets whose business activity contains "File Event Handler".
    public let fileHandlers: [AnalyzedFeatureSet]
    /// Feature sets whose business activity contains "NotificationSent Handler".
    public let notificationHandlers: [AnalyzedFeatureSet]
    /// Feature sets whose business activity contains " Observer" and "-repository".
    public let repositoryObservers: [AnalyzedFeatureSet]
    /// Feature sets whose business activity has " Evicted Handler" suffix and "-repository".
    public let evictionHandlers: [AnalyzedFeatureSet]
    /// Feature sets whose business activity contains " Watch:".
    public let watchHandlers: [AnalyzedFeatureSet]
    /// Feature sets whose business activity contains "StateObserver" or "StateTransition Handler".
    public let stateObservers: [AnalyzedFeatureSet]
    /// Feature sets whose business activity contains "KeyPress Handler".
    public let keyPressHandlers: [AnalyzedFeatureSet]
    /// Domain event handlers: contain " Handler" but not socket/websocket/file/keypress/application-end.
    public let domainHandlers: [AnalyzedFeatureSet]

    public init(program: Program, featureSets: [AnalyzedFeatureSet], globalRegistry: GlobalSymbolRegistry) {
        self.program = program
        self.featureSets = featureSets
        self.globalRegistry = globalRegistry
        self.byActivity = Dictionary(grouping: featureSets, by: { $0.featureSet.businessActivity })
        var nameIndex: [String: AnalyzedFeatureSet] = [:]
        for fs in featureSets { nameIndex[fs.featureSet.name] = fs }
        self.byName = nameIndex

        // Pre-classify feature sets by handler category (single pass)
        var socket: [AnalyzedFeatureSet] = []
        var ws: [AnalyzedFeatureSet] = []
        var file: [AnalyzedFeatureSet] = []
        var notification: [AnalyzedFeatureSet] = []
        var repoObs: [AnalyzedFeatureSet] = []
        var eviction: [AnalyzedFeatureSet] = []
        var watch: [AnalyzedFeatureSet] = []
        var state: [AnalyzedFeatureSet] = []
        var keyPress: [AnalyzedFeatureSet] = []
        var domain: [AnalyzedFeatureSet] = []

        for fs in featureSets {
            let activity = fs.featureSet.businessActivity

            if activity.contains(" Watch:") {
                watch.append(fs)
            }
            if activity.contains("StateObserver") || activity.contains("StateTransition Handler") {
                state.append(fs)
            }
            if activity.contains("KeyPress Handler") {
                keyPress.append(fs)
            }

            let isSocket = activity.contains("Socket Event Handler")
            let isWS = activity.contains("WebSocket Event Handler")
            let isFile = activity.contains("File Event Handler")
            let isNotification = activity.contains("NotificationSent Handler")

            if isSocket { socket.append(fs) }
            if isWS { ws.append(fs) }
            if isFile { file.append(fs) }
            if isNotification { notification.append(fs) }

            if activity.contains(" Observer") && activity.contains("-repository") {
                repoObs.append(fs)
            }
            if activity.hasSuffix(" Evicted Handler") && activity.contains("-repository") {
                eviction.append(fs)
            }

            // Domain handlers: have " Handler" but aren't special handler types
            if activity.contains(" Handler") &&
               !isSocket && !isWS && !isFile &&
               !activity.contains("KeyPress Handler") &&
               !activity.contains("StateTransition Handler") &&
               !activity.contains("StateObserver") &&
               !activity.contains("Application-End") {
                domain.append(fs)
            }
        }

        self.socketHandlers = socket
        self.webSocketHandlers = ws
        self.fileHandlers = file
        self.notificationHandlers = notification
        self.repositoryObservers = repoObs
        self.evictionHandlers = eviction
        self.watchHandlers = watch
        self.stateObservers = state
        self.keyPressHandlers = keyPress
        self.domainHandlers = domain
    }
}

// MARK: - Semantic Analyzer

/// Performs semantic analysis on the AST by orchestrating focused validators
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
        let dataFlow = DataFlowAnalyzer(diagnostics: diagnostics)
        let codeQuality = CodeQualityValidator(diagnostics: diagnostics)
        let events = EventAnalyzer(diagnostics: diagnostics)

        var analyzedSets: [AnalyzedFeatureSet] = []

        // First pass: check for duplicate names
        dataFlow.detectDuplicateFeatureSetNames(program.featureSets)

        // Second pass: analyze each feature set
        for featureSet in program.featureSets {
            let analyzed = dataFlow.analyzeFeatureSet(featureSet)
            analyzedSets.append(analyzed)

            // Code quality check
            codeQuality.validate(featureSet)

            // Register published symbols
            for symbol in analyzed.symbolTable.publishedSymbols.values {
                globalRegistry.register(symbol: symbol, fromFeatureSet: featureSet.name)
            }
        }

        // Third pass: verify external dependencies
        for analyzed in analyzedSets {
            dataFlow.verifyDependencies(analyzed, globalRegistry: globalRegistry)
        }

        // Fourth pass: detect circular event chains
        events.detectCircularEventChains(analyzedSets)

        // Fifth pass: detect orphaned event emissions
        events.detectOrphanedEventEmissions(analyzedSets)

        return AnalyzedProgram(
            program: program,
            featureSets: analyzedSets,
            globalRegistry: globalRegistry
        )
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
