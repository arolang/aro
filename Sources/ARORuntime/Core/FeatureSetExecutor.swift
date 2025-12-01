// ============================================================
// FeatureSetExecutor.swift
// ARO Runtime - Feature Set Executor
// ============================================================

import Foundation
import AROParser

/// Executes a single feature set
///
/// The FeatureSetExecutor processes statements sequentially within a
/// feature set, managing variable bindings and action execution.
public final class FeatureSetExecutor: @unchecked Sendable {
    // MARK: - Properties

    private let actionRegistry: ActionRegistry
    private let eventBus: EventBus
    private let globalSymbols: GlobalSymbolStorage

    // MARK: - Initialization

    public init(
        actionRegistry: ActionRegistry,
        eventBus: EventBus,
        globalSymbols: GlobalSymbolStorage
    ) {
        self.actionRegistry = actionRegistry
        self.eventBus = eventBus
        self.globalSymbols = globalSymbols
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

        // Bind external dependencies from global symbols
        for dependency in analyzedFeatureSet.dependencies {
            if let value = globalSymbols.resolveAny(dependency) {
                context.bind(dependency, value: value)
            }
        }

        // Execute statements
        do {
            for statement in featureSet.statements {
                try await executeStatement(statement, context: context)

                // Check if we have a response (Return was called)
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
        }
        // Other statement types can be added here
    }

    private func executeAROStatement(
        _ statement: AROStatement,
        context: ExecutionContext
    ) async throws {
        let verb = statement.action.verb
        let resultDescriptor = ResultDescriptor(from: statement.result)
        let objectDescriptor = ObjectDescriptor(from: statement.object)

        // Get action implementation
        guard let action = actionRegistry.action(for: verb) else {
            throw ActionError.unknownAction(verb)
        }

        // Execute action
        let result = try await action.execute(
            result: resultDescriptor,
            object: objectDescriptor,
            context: context
        )

        // Bind result to context (unless it's a response action that already set the response)
        if statement.action.semanticRole != .response {
            context.bind(resultDescriptor.base, value: result)
        }
    }

    private func executePublishStatement(
        _ statement: PublishStatement,
        context: ExecutionContext
    ) async throws {
        // Get the internal value
        guard let value = context.resolveAny(statement.internalVariable) else {
            throw ActionError.undefinedVariable(statement.internalVariable)
        }

        // Publish to global symbols
        globalSymbols.publish(
            name: statement.externalName,
            value: value,
            fromFeatureSet: context.featureSetName
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
}

// MARK: - Runtime

/// Main runtime that manages program execution lifecycle
public final class Runtime: @unchecked Sendable {
    // MARK: - Properties

    private let engine: ExecutionEngine
    private let eventBus: EventBus
    private var _isRunning: Bool = false
    private let lock = NSLock()

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
    }

    // MARK: - Service Registration

    /// Register a service for dependency injection
    public func register<S: Sendable>(service: S) {
        engine.register(service: service)
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
        _ = try await run(program, entryPoint: entryPoint)

        // Keep running until stopped
        while isRunning {
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
    }

    /// Stop the runtime
    public func stop() {
        eventBus.publish(ApplicationStoppingEvent(reason: "stop requested"))
        isRunning = false
    }
}
