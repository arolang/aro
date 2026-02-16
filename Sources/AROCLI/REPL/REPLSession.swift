// REPLSession.swift
// ARO REPL Session Management
//
// Manages the state of an interactive REPL session including:
// - Variable persistence across statements
// - Feature set definitions
// - History tracking
// - Session export

import Foundation
import AROParser
import ARORuntime

/// Result of executing a REPL input
public enum REPLResult: Sendable {
    case value(any Sendable)
    case ok
    case featureSetStarted(String)
    case featureSetDefined(String)
    case statementAdded
    case commandOutput(String)
    case table([[String]])
    case exit
    case error(String)

    public var isSuccess: Bool {
        switch self {
        case .error:
            return false
        default:
            return true
        }
    }
}

/// Entry in the session history
public struct HistoryEntry: Sendable {
    public let input: String
    public let timestamp: Date
    public let type: HistoryEntryType
    public var result: REPLResult?
    public var duration: TimeInterval?

    public init(input: String, type: HistoryEntryType) {
        self.input = input
        self.timestamp = Date()
        self.type = type
        self.result = nil
        self.duration = nil
    }
}

public enum HistoryEntryType: Sendable {
    case statement
    case featureSetStart
    case featureSetEnd
    case metaCommand
    case expression
}

/// The current mode of the REPL
public enum REPLMode: Sendable {
    case direct
    case featureSetDefinition(name: String, activity: String, statements: [String])
}

/// Manages an interactive REPL session
public final class REPLSession: @unchecked Sendable {
    public let id = UUID()

    /// The runtime context for this session
    public private(set) var context: RuntimeContext

    /// Event bus for the session
    public let eventBus: EventBus

    /// Global symbol storage
    public let globalSymbols: GlobalSymbolStorage

    /// Defined feature sets (thread-safe access via methods)
    private var _featureSets: [String: AnalyzedFeatureSet] = [:]

    /// Raw feature set sources for export
    private var _featureSetSources: [String: String] = [:]

    /// Session history
    private var _history: [HistoryEntry] = []

    /// Current mode
    public var mode: REPLMode = .direct

    /// The compiler instance
    private let compiler = Compiler()

    /// The statement executor
    private let executor: FeatureSetExecutor

    public init() {
        self.eventBus = EventBus()
        self.globalSymbols = GlobalSymbolStorage()
        self.context = RuntimeContext(
            featureSetName: "_repl_session_",
            businessActivity: "Interactive",
            outputContext: .human,
            eventBus: eventBus
        )

        // Register services for REPL session
        let fileService = AROFileSystemService(eventBus: eventBus)
        self.context.register(fileService as FileSystemService)

        self.executor = FeatureSetExecutor(
            actionRegistry: ActionRegistry.shared,
            eventBus: eventBus,
            globalSymbols: globalSymbols
        )
    }

    // MARK: - Thread-safe accessors

    public var featureSets: [String: AnalyzedFeatureSet] {
        _featureSets
    }

    public var featureSetSources: [String: String] {
        _featureSetSources
    }

    public var history: [HistoryEntry] {
        _history
    }

    public func addFeatureSet(name: String, featureSet: AnalyzedFeatureSet, source: String? = nil) {
        _featureSets[name] = featureSet
        if let source = source {
            _featureSetSources[name] = source
        }
    }

    private func addHistory(_ entry: HistoryEntry) {
        _history.append(entry)
    }

    // MARK: - Statement Execution

    /// Execute a single ARO statement
    public func executeStatement(_ source: String) async throws -> REPLResult {
        let startTime = Date()

        // Record in history
        var entry = HistoryEntry(input: source, type: .statement)

        // Wrap statement in a temporary feature set for compilation
        let wrappedSource = """
        (_repl_temp_: Interactive) {
            \(source)
        }
        """

        let result = compiler.compile(wrappedSource)

        if !result.isSuccess {
            let errorMsg = result.diagnostics.map { $0.message }.joined(separator: "\n")
            entry.result = .error(errorMsg)
            entry.duration = Date().timeIntervalSince(startTime)
            addHistory(entry)
            return .error(errorMsg)
        }

        guard let analyzedFS = result.analyzedProgram.featureSets.first else {
            let errorMsg = "No feature set found in compiled result"
            entry.result = .error(errorMsg)
            entry.duration = Date().timeIntervalSince(startTime)
            addHistory(entry)
            return .error(errorMsg)
        }

        do {
            let response = try await executor.execute(analyzedFS, context: context)

            entry.duration = Date().timeIntervalSince(startTime)

            // Check if there's a meaningful return value
            if !response.data.isEmpty {
                // Convert response data to a displayable format
                let data = convertResponseData(response.data)
                entry.result = .value(data)
                addHistory(entry)
                return .value(data)
            } else {
                entry.result = .ok
                addHistory(entry)
                return .ok
            }
        } catch {
            let errorMsg = formatError(error)
            entry.result = .error(errorMsg)
            entry.duration = Date().timeIntervalSince(startTime)
            addHistory(entry)
            return .error(errorMsg)
        }
    }

    /// Convert AnySendable response data to displayable format
    private func convertResponseData(_ data: [String: AnySendable]) -> any Sendable {
        // Try to extract single value if there's only one key
        if data.count == 1, let first = data.first {
            // Try common types
            if let str: String = first.value.get() { return str }
            if let num: Int = first.value.get() { return num }
            if let num: Double = first.value.get() { return num }
            if let bool: Bool = first.value.get() { return bool }
            if let arr: [String] = first.value.get() { return arr }
            if let dict: [String: String] = first.value.get() { return dict }
        }

        // Return the whole dictionary as a string representation
        var result: [String: String] = [:]
        for (key, value) in data {
            if let str: String = value.get() { result[key] = str }
            else if let num: Int = value.get() { result[key] = String(num) }
            else if let num: Double = value.get() { result[key] = String(num) }
            else if let bool: Bool = value.get() { result[key] = String(bool) }
            else { result[key] = String(describing: value) }
        }
        return result
    }

    /// Execute an expression and return the result
    public func evaluateExpression(_ source: String) async throws -> REPLResult {
        // For simple expressions, wrap in a Compute statement
        let statement = "<Compute> the <_expr_result_> from \(source)."
        let result = try await executeStatement(statement)

        // Return the computed value
        if case .ok = result {
            if let value = context.resolveAny("_expr_result_") {
                return .value(value)
            }
        }
        return result
    }

    /// Define a feature set from accumulated statements
    public func defineFeatureSet(name: String, activity: String, statements: [String]) async throws -> REPLResult {
        let statementsSource = statements.map { "    \($0)" }.joined(separator: "\n")
        let source = """
        (\(name): \(activity)) {
        \(statementsSource)
        }
        """

        let result = compiler.compile(source)

        if !result.isSuccess {
            let errorMsg = result.diagnostics.map { $0.message }.joined(separator: "\n")
            return .error(errorMsg)
        }

        guard let analyzedFS = result.analyzedProgram.featureSets.first else {
            return .error("No feature set found in compiled result")
        }

        addFeatureSet(name: name, featureSet: analyzedFS, source: source)

        // Record in history
        let entry = HistoryEntry(input: "(\(name): \(activity)) { ... }", type: .featureSetEnd)
        addHistory(entry)

        return .featureSetDefined(name)
    }

    /// Invoke a defined feature set
    public func invokeFeatureSet(named name: String, input: [String: any Sendable]? = nil) async throws -> REPLResult {
        guard let featureSet = _featureSets[name] else {
            return .error("Feature set '\(name)' not found. Use :fs to list defined feature sets.")
        }

        // Create a child context for the invocation
        let childContext = context.createChild(
            featureSetName: name,
            businessActivity: featureSet.featureSet.businessActivity
        )

        // Bind input values if provided
        if let input = input {
            for (key, value) in input {
                childContext.bind(key, value: value)
            }
        }

        do {
            let response = try await executor.execute(featureSet, context: childContext)

            if !response.data.isEmpty {
                let data = convertResponseData(response.data)
                return .value(data)
            } else {
                return .ok
            }
        } catch {
            return .error(formatError(error))
        }
    }

    /// Clear session state
    public func clear() {
        _featureSets.removeAll()
        _featureSetSources.removeAll()
        _history.removeAll()
        // Reset the runtime context to clear all variables
        context = RuntimeContext(
            featureSetName: "_repl_session_",
            businessActivity: "Interactive",
            outputContext: .human,
            eventBus: eventBus
        )
    }

    /// Get all variable names
    public var variableNames: [String] {
        context.variableNames.filter { !$0.hasPrefix("_") }.sorted()
    }

    /// Get variable value
    public func getVariable(_ name: String) -> (any Sendable)? {
        context.resolveAny(name)
    }

    /// Set a variable
    public func setVariable(_ name: String, value: any Sendable) {
        context.bind(name, value: value, allowRebind: true)
    }

    /// Get feature set names
    public var featureSetNames: [String] {
        Array(_featureSets.keys).sorted()
    }

    /// Format error for display
    private func formatError(_ error: Error) -> String {
        if let aroError = error as? AROError {
            return aroError.message
        }
        return String(describing: error)
    }
}
