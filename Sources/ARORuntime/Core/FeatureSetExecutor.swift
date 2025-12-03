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
    private let expressionEvaluator: ExpressionEvaluator

    // MARK: - Initialization

    public init(
        actionRegistry: ActionRegistry,
        eventBus: EventBus,
        globalSymbols: GlobalSymbolStorage
    ) {
        self.actionRegistry = actionRegistry
        self.eventBus = eventBus
        self.globalSymbols = globalSymbols
        self.expressionEvaluator = ExpressionEvaluator()
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

        // ARO-0002: Evaluate expression if present
        if let expression = statement.expression {
            let expressionValue = try await expressionEvaluator.evaluate(expression, context: context)
            context.bind("_expression_", value: expressionValue)

            // For expressions, directly bind the result to the expression value
            // This handles cases like: <Set> the <x> to 30 * 2.
            // or: <Compute> the <total> from <price> * <quantity>.
            if statement.object.noun.base == "_expression_" {
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
            }
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
            if statement.action.semanticRole != .response {
                context.bind(resultDescriptor.base, value: result)
            }
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
    private var _currentProgram: AnalyzedProgram?
    private var _shutdownError: Error?
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
}
