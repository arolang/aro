// ============================================================
// StatementScheduler.swift
// ARORuntime - Data-Flow Driven Statement Execution (ARO-0011)
// ============================================================
//
// This module schedules statement execution to enable parallel I/O
// while maintaining sequential semantics. Key principles from ARO-0011:
//
// 1. **Eager Start**: I/O operations begin immediately (non-blocking)
// 2. **Dependency Tracking**: The runtime tracks which variables each statement needs
// 3. **Lazy Synchronization**: Only wait for data when it's actually used
// 4. **Preserved Semantics**: Results appear in statement order
//
// Example execution timeline:
//
// Without optimization:
// T0: Request users     [====]
// T1: Request orders           [====]
// T2: Compute hash                   [=]
// T3: Map names                        [=]
// T4: Return                            [=]
// Total: ~5 time units
//
// With optimization:
// T0: Request users     [====]
// T0: Request orders    [====]  (parallel I/O)
// T0: Compute hash      [=]     (no dependencies)
// T1: Map names              [=] (waits for users)
// T2: Return                  [=] (waits for orders)
// Total: ~3 time units

import Foundation
import AROParser

// MARK: - Statement Future

/// Represents a statement that has been started but may not have completed.
/// Converted to actor for Swift 6.2 concurrency safety (Issue #2).
public actor StatementFuture {
    private var _result: (any Sendable)?
    private var _error: Error?
    private var _isComplete: Bool = false
    private var continuations: [CheckedContinuation<any Sendable, Error>] = []

    /// The index of the statement (immutable, safe to access without isolation)
    public nonisolated let statementIndex: Int

    public init(statementIndex: Int) {
        self.statementIndex = statementIndex
    }

    /// Check if the future has completed
    public var isComplete: Bool {
        _isComplete
    }

    /// Complete the future with a result
    public func complete(with result: any Sendable) {
        guard !_isComplete else { return }
        _result = result
        _isComplete = true
        let waiting = continuations
        continuations.removeAll()

        // Resume all waiting continuations
        for continuation in waiting {
            continuation.resume(returning: result)
        }
    }

    /// Complete the future with an error
    public func fail(with error: Error) {
        guard !_isComplete else { return }
        _error = error
        _isComplete = true
        let waiting = continuations
        continuations.removeAll()

        // Resume all waiting continuations with error
        for continuation in waiting {
            continuation.resume(throwing: error)
        }
    }

    /// Register continuation or resume immediately if already complete.
    /// This method provides atomic check-and-register within actor isolation.
    private func registerOrComplete(_ continuation: CheckedContinuation<any Sendable, Error>) {
        if _isComplete {
            if let error = _error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume(returning: _result ?? ())
            }
        } else {
            continuations.append(continuation)
        }
    }

    /// Wait for the future to complete
    public func wait() async throws -> any Sendable {
        // Fast path: if already complete, return immediately
        if _isComplete {
            if let error = _error {
                throw error
            }
            return _result ?? ()
        }

        // Slow path: suspend until completion
        // Use Task to hop back to actor context for safe registration
        return try await withCheckedThrowingContinuation { continuation in
            Task {
                // Call actor-isolated method (await required for isolation crossing)
                await self.registerOrComplete(continuation)
            }
        }
    }
}

// MARK: - Statement Scheduler

/// Schedules and executes statements with data-flow driven parallelism.
/// Converted to actor for Swift 6.2 concurrency safety (Issue #2).
public actor StatementScheduler {

    // MARK: - Properties

    private let dependencyGraph: DependencyGraph
    private var futures: [Int: StatementFuture] = [:]
    private var completedIndices: Set<Int> = []

    /// Callback type for executing a statement
    public typealias StatementExecutor = @Sendable (Statement, ExecutionContext) async throws -> any Sendable

    // MARK: - Initialization

    public init() {
        self.dependencyGraph = DependencyGraph()
    }

    // MARK: - State Helpers

    private func resetState() {
        futures.removeAll()
        completedIndices.removeAll()
    }

    private func getFuture(at index: Int) -> StatementFuture? {
        return futures[index]
    }

    private func setFuture(_ future: StatementFuture, at index: Int) {
        futures[index] = future
    }

    private func getCompletedIndices() -> Set<Int> {
        return completedIndices
    }

    private func addCompletedIndex(_ index: Int) {
        completedIndices.insert(index)
    }

    private func hasFuture(at index: Int) -> Bool {
        return futures[index] != nil
    }

    // MARK: - Execution

    /// Execute statements with data-flow driven scheduling
    /// - Parameters:
    ///   - analyzedFeatureSet: The feature set to execute
    ///   - context: The execution context
    ///   - executor: Callback to execute individual statements
    /// - Returns: Whether execution completed (vs. early return)
    public func execute(
        _ analyzedFeatureSet: AnalyzedFeatureSet,
        context: ExecutionContext,
        executor: @escaping StatementExecutor
    ) async throws -> Bool {
        let statements = analyzedFeatureSet.featureSet.statements
        let dataFlows = analyzedFeatureSet.dataFlows

        // Build dependency graph
        await dependencyGraph.build(statements: statements, dataFlows: dataFlows)

        // Generate execution plan
        let plan = await dependencyGraph.generatePlan()

        // Reset state
        resetState()

        // Phase 1: Start eager I/O operations (no dependencies)
        for index in plan.eagerStart {
            if let node = await dependencyGraph.node(at: index) {
                await startStatement(node, context: context, executor: executor)
            }
        }

        // Phase 2: Process statements in semantic order
        for index in plan.executionOrder {
            guard let node = await dependencyGraph.node(at: index) else { continue }

            // Wait for dependencies
            for depIndex in node.dependencies {
                try await waitForStatement(depIndex)
            }

            // Check if this statement was already started eagerly
            let future = await getOrStartStatement(node, context: context, executor: executor)

            // Wait for this statement to complete
            _ = try await future.wait()

            // Mark as completed
            addCompletedIndex(index)

            // Check for early return (Response was set)
            if context.getResponse() != nil {
                // Cancel any pending futures (best effort)
                cancelPendingFutures()
                return false
            }

            // Start any newly ready I/O operations
            await startReadyIOOperations(context: context, executor: executor)
        }

        return true
    }

    // MARK: - Private Methods

    /// Start a statement execution (non-blocking)
    private func startStatement(
        _ node: StatementNode,
        context: ExecutionContext,
        executor: @escaping @Sendable StatementExecutor
    ) async {
        let future = StatementFuture(statementIndex: node.index)

        setFuture(future, at: node.index)
        await dependencyGraph.markScheduled(node.index)

        // Capture values needed for the task
        let statement = node.statement

        // Execute in a detached task
        Task { @Sendable in
            do {
                let result = try await executor(statement, context)
                await future.complete(with: result)
            } catch {
                await future.fail(with: error)
            }
        }
    }

    /// Get existing future or start new execution
    private func getOrStartStatement(
        _ node: StatementNode,
        context: ExecutionContext,
        executor: @escaping @Sendable StatementExecutor
    ) async -> StatementFuture {
        if let existing = getFuture(at: node.index) {
            return existing
        }

        // Start it now
        await startStatement(node, context: context, executor: executor)

        return getFuture(at: node.index)!
    }

    /// Wait for a statement to complete
    private func waitForStatement(_ index: Int) async throws {
        guard let future = getFuture(at: index) else {
            return // Statement not started or already completed
        }

        _ = try await future.wait()
    }

    /// Start any I/O operations that are now ready
    private func startReadyIOOperations(
        context: ExecutionContext,
        executor: @escaping @Sendable StatementExecutor
    ) async {
        let completed = getCompletedIndices()
        let readyIO = await dependencyGraph.parallelizableNodes(completedIndices: completed)

        for node in readyIO {
            if !hasFuture(at: node.index) {
                await startStatement(node, context: context, executor: executor)
            }
        }
    }

    /// Cancel any pending futures (best effort)
    private func cancelPendingFutures() {
        // Note: Swift's Task cancellation is cooperative
        // For now, we just let them complete - they won't affect the result
        // A more sophisticated implementation could use TaskGroup with cancellation
    }
}

// MARK: - Scheduler Configuration

/// Configuration options for the statement scheduler
public struct SchedulerConfiguration: Sendable {
    /// Whether to enable parallel I/O optimization
    public let enableParallelIO: Bool

    /// Maximum number of concurrent I/O operations
    public let maxConcurrentIO: Int

    /// Default configuration (optimization enabled)
    public static let `default` = SchedulerConfiguration(
        enableParallelIO: true,
        maxConcurrentIO: 10
    )

    /// Sequential execution (no optimization)
    public static let sequential = SchedulerConfiguration(
        enableParallelIO: false,
        maxConcurrentIO: 1
    )

    public init(enableParallelIO: Bool, maxConcurrentIO: Int) {
        self.enableParallelIO = enableParallelIO
        self.maxConcurrentIO = maxConcurrentIO
    }
}
