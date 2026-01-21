// ============================================================
// DependencyGraph.swift
// ARORuntime - Data-Flow Dependency Analysis (ARO-0011)
// ============================================================
//
// This module builds a dependency graph from DataFlowInfo to enable
// parallel execution of I/O operations while maintaining sequential
// semantics.
//
// The key insight from ARO-0011:
// - Statements APPEAR synchronous to the programmer
// - Runtime MAY execute I/O operations in parallel
// - Results MUST appear in statement order
//
// Example:
// ```aro
// <Request> the <users> from the <user-api>.      (* I/O - starts immediately *)
// <Request> the <orders> from the <order-api>.    (* I/O - starts in parallel *)
// <Compute> the <hash> for the <request>.         (* CPU - runs immediately *)
// <Map> the <names> from the <users: name>.       (* Needs users - await here *)
// <Return> an <OK: status> with <users, orders>.  (* Needs both - await orders *)
// ```

import Foundation
import AROParser

// MARK: - Statement Node

/// A node in the dependency graph representing a statement
public struct StatementNode: Sendable {
    /// Index of the statement in the feature set
    public let index: Int

    /// The statement itself
    public let statement: Statement

    /// Data flow information for this statement
    public let dataFlow: DataFlowInfo

    /// Indices of statements this one depends on (must complete before this starts)
    public var dependencies: Set<Int>

    /// Whether this statement involves I/O (can run in parallel with others)
    public let isIO: Bool

    /// Whether this statement has been scheduled for execution
    public var isScheduled: Bool = false

    public init(
        index: Int,
        statement: Statement,
        dataFlow: DataFlowInfo,
        dependencies: Set<Int> = [],
        isIO: Bool
    ) {
        self.index = index
        self.statement = statement
        self.dataFlow = dataFlow
        self.dependencies = dependencies
        self.isIO = isIO
    }
}

// MARK: - Dependency Graph

/// Builds and maintains a dependency graph for statement execution.
/// Converted to actor for Swift 6.2 concurrency safety (Issue #2).
public actor DependencyGraph {

    // MARK: - Properties

    private var nodes: [StatementNode] = []

    /// Verbs that typically involve I/O operations
    private static let ioVerbs: Set<String> = [
        // Network I/O
        "request", "fetch", "retrieve", "send",
        // File I/O
        "read", "write", "store", "load", "open",
        // Database
        "query", "insert", "update", "delete",
        // External services
        "call", "invoke"
    ]

    /// Verbs that are purely computational (no I/O)
    private static let cpuVerbs: Set<String> = [
        "compute", "calculate", "derive", "transform", "convert",
        "map", "filter", "reduce", "validate", "compare",
        "create", "parse", "extract", "format"
    ]

    // MARK: - Initialization

    public init() {}

    // MARK: - Graph Building

    /// Build dependency graph from analyzed feature set
    /// - Parameters:
    ///   - statements: The statements to analyze
    ///   - dataFlows: The data flow info for each statement (parallel array)
    public func build(
        statements: [Statement],
        dataFlows: [DataFlowInfo]
    ) {
        nodes = []

        // Map from variable name to the index of the statement that produces it
        var producers: [String: Int] = [:]

        for (index, statement) in statements.enumerated() {
            let dataFlow = index < dataFlows.count ? dataFlows[index] : DataFlowInfo()

            // Determine if this is an I/O statement
            let isIO = classifyAsIO(statement)

            // Find dependencies: statements that produce variables we need
            var deps: Set<Int> = []
            for input in dataFlow.inputs {
                if let producerIndex = producers[input] {
                    deps.insert(producerIndex)
                }
            }

            let node = StatementNode(
                index: index,
                statement: statement,
                dataFlow: dataFlow,
                dependencies: deps,
                isIO: isIO
            )
            nodes.append(node)

            // Register outputs from this statement
            for output in dataFlow.outputs {
                producers[output] = index
            }
        }
    }

    /// Classify a statement as I/O or CPU-bound
    private func classifyAsIO(_ statement: Statement) -> Bool {
        guard let aroStatement = statement as? AROStatement else {
            return false
        }

        let verb = aroStatement.action.verb.lowercased()

        // Check against known I/O verbs
        if Self.ioVerbs.contains(verb) {
            return true
        }

        // Check against known CPU verbs
        if Self.cpuVerbs.contains(verb) {
            return false
        }

        // Check semantic role - REQUEST actions typically involve I/O
        if aroStatement.action.semanticRole == .request {
            return true
        }

        // Check side effects - if there are external effects, it's likely I/O
        // This would need dataFlowInfo which we have in the node

        // Default to non-I/O (conservative)
        return false
    }

    // MARK: - Query Methods

    /// Get all nodes in the graph
    public var allNodes: [StatementNode] {
        return nodes
    }

    /// Get nodes that are ready to execute (all dependencies satisfied)
    /// - Parameter completedIndices: Indices of statements that have completed
    /// - Returns: Nodes ready for execution
    public func readyNodes(completedIndices: Set<Int>) -> [StatementNode] {
        return nodes.filter { node in
            // Not already scheduled
            !node.isScheduled &&
            // All dependencies completed
            node.dependencies.isSubset(of: completedIndices)
        }
    }

    /// Get nodes that can run in parallel (I/O operations with satisfied dependencies)
    /// - Parameter completedIndices: Indices of statements that have completed
    /// - Returns: I/O nodes ready for parallel execution
    public func parallelizableNodes(completedIndices: Set<Int>) -> [StatementNode] {
        readyNodes(completedIndices: completedIndices).filter { $0.isIO }
    }

    /// Get the next node that must be awaited (first non-completed in order)
    /// - Parameter completedIndices: Indices of statements that have completed
    /// - Returns: The next node to await, or nil if all complete
    public func nextToAwait(completedIndices: Set<Int>) -> StatementNode? {
        // Find first node not in completed set
        return nodes.first { !completedIndices.contains($0.index) }
    }

    /// Mark a node as scheduled
    public func markScheduled(_ index: Int) {
        if index < nodes.count {
            nodes[index].isScheduled = true
        }
    }

    /// Reset all scheduled flags
    public func reset() {
        for i in 0..<nodes.count {
            nodes[i].isScheduled = false
        }
    }

    /// Get node at index
    public func node(at index: Int) -> StatementNode? {
        guard index >= 0 && index < nodes.count else { return nil }
        return nodes[index]
    }

    /// Number of nodes in the graph
    public var count: Int {
        return nodes.count
    }
}

// MARK: - Execution Plan

/// Represents an execution plan for a feature set
public struct ExecutionPlan: Sendable {
    /// Statements to start immediately (I/O operations with no dependencies)
    public let eagerStart: [Int]

    /// Statements to execute in order (with potential parallel I/O)
    public let executionOrder: [Int]

    /// Map of statement index to its dependencies
    public let dependencies: [Int: Set<Int>]

    /// Which statements are I/O operations
    public let ioStatements: Set<Int>

    public init(
        eagerStart: [Int],
        executionOrder: [Int],
        dependencies: [Int: Set<Int>],
        ioStatements: Set<Int>
    ) {
        self.eagerStart = eagerStart
        self.executionOrder = executionOrder
        self.dependencies = dependencies
        self.ioStatements = ioStatements
    }
}

extension DependencyGraph {
    /// Generate an execution plan from the dependency graph
    public func generatePlan() -> ExecutionPlan {
        var eagerStart: [Int] = []
        var ioStatements: Set<Int> = []
        var dependencies: [Int: Set<Int>] = [:]

        for node in nodes {
            dependencies[node.index] = node.dependencies

            if node.isIO {
                ioStatements.insert(node.index)

                // I/O with no dependencies can start immediately
                if node.dependencies.isEmpty {
                    eagerStart.append(node.index)
                }
            }
        }

        // Execution order is just 0, 1, 2, ... (semantic order)
        let executionOrder = nodes.map { $0.index }

        return ExecutionPlan(
            eagerStart: eagerStart,
            executionOrder: executionOrder,
            dependencies: dependencies,
            ioStatements: ioStatements
        )
    }
}
