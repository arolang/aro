// ============================================================
// ExecutionEngine.swift
// ARO Runtime - Execution Engine
// ============================================================

import Foundation
import AROParser

/// Main execution engine for ARO programs
///
/// The ExecutionEngine interprets and executes analyzed ARO programs.
/// It coordinates feature set execution, manages the global symbol registry,
/// and handles cross-feature-set dependencies.
public final class ExecutionEngine: @unchecked Sendable {
    // MARK: - Properties

    /// The action registry for looking up action implementations
    private let actionRegistry: ActionRegistry

    /// The event bus for event-driven communication
    private let eventBus: EventBus

    /// Global symbol registry for published variables
    private let globalSymbols: GlobalSymbolStorage

    /// Service registry for dependency injection
    private let services: ServiceRegistry

    /// Lock for thread-safe access
    private let lock = NSLock()

    // MARK: - Initialization

    /// Initialize the execution engine
    /// - Parameters:
    ///   - actionRegistry: Action registry (defaults to shared)
    ///   - eventBus: Event bus (defaults to shared)
    public init(
        actionRegistry: ActionRegistry = .shared,
        eventBus: EventBus = .shared
    ) {
        self.actionRegistry = actionRegistry
        self.eventBus = eventBus
        self.globalSymbols = GlobalSymbolStorage()
        self.services = ServiceRegistry()
    }

    // MARK: - Service Registration

    /// Register a service for dependency injection
    /// - Parameter service: The service instance
    public func register<S: Sendable>(service: S) {
        services.register(service)
    }

    // MARK: - Program Execution

    /// Execute an analyzed program
    /// - Parameters:
    ///   - program: The analyzed program to execute
    ///   - entryPoint: Name of the entry point feature set (default: "Application-Start")
    /// - Returns: The response from the entry point feature set
    public func execute(
        _ program: AnalyzedProgram,
        entryPoint: String = "Application-Start"
    ) async throws -> Response {
        // Find entry point
        guard let entryFeatureSet = program.featureSets.first(where: {
            $0.featureSet.name == entryPoint
        }) else {
            throw ActionError.entryPointNotFound(entryPoint)
        }

        // Emit application start event
        eventBus.publish(ApplicationStartedEvent(applicationName: entryPoint))

        // Create root context
        let context = RuntimeContext(
            featureSetName: entryPoint,
            eventBus: eventBus
        )

        // Register services in context
        services.registerAll(in: context)

        // Execute entry point
        let executor = FeatureSetExecutor(
            actionRegistry: actionRegistry,
            eventBus: eventBus,
            globalSymbols: globalSymbols
        )

        do {
            let response = try await executor.execute(entryFeatureSet, context: context)
            return response
        } catch {
            eventBus.publish(ErrorOccurredEvent(
                error: String(describing: error),
                context: entryPoint,
                recoverable: false
            ))
            throw error
        }
    }

    /// Execute a specific feature set by name
    /// - Parameters:
    ///   - name: The feature set name
    ///   - program: The analyzed program containing the feature set
    ///   - context: The execution context
    /// - Returns: The response from the feature set
    public func executeFeatureSet(
        named name: String,
        in program: AnalyzedProgram,
        context: ExecutionContext
    ) async throws -> Response {
        guard let featureSet = program.featureSets.first(where: {
            $0.featureSet.name == name
        }) else {
            throw ActionError.featureSetNotFound(name)
        }

        let executor = FeatureSetExecutor(
            actionRegistry: actionRegistry,
            eventBus: eventBus,
            globalSymbols: globalSymbols
        )

        return try await executor.execute(featureSet, context: context)
    }
}

// MARK: - Global Symbol Storage

/// Thread-safe storage for published symbols
public final class GlobalSymbolStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var symbols: [String: (value: any Sendable, featureSet: String)] = [:]

    public init() {}

    /// Store a published symbol
    public func publish(name: String, value: any Sendable, fromFeatureSet: String) {
        lock.lock()
        defer { lock.unlock() }
        symbols[name] = (value, fromFeatureSet)
    }

    /// Resolve a published symbol
    public func resolve<T: Sendable>(_ name: String) -> T? {
        lock.lock()
        defer { lock.unlock() }
        return symbols[name]?.value as? T
    }

    /// Resolve a published symbol as any Sendable
    public func resolveAny(_ name: String) -> (any Sendable)? {
        lock.lock()
        defer { lock.unlock() }
        return symbols[name]?.value
    }

    /// Check if a symbol is published
    public func isPublished(_ name: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return symbols[name] != nil
    }

    /// Get the feature set that published a symbol
    public func sourceFeatureSet(for name: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return symbols[name]?.featureSet
    }
}

// MARK: - Service Registry

/// Registry for dependency injection
public final class ServiceRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var services: [ObjectIdentifier: any Sendable] = [:]

    public init() {}

    /// Register a service
    public func register<S: Sendable>(_ service: S) {
        lock.lock()
        defer { lock.unlock() }
        services[ObjectIdentifier(S.self)] = service
    }

    /// Resolve a service
    public func resolve<S>(_ type: S.Type) -> S? {
        lock.lock()
        defer { lock.unlock() }
        return services[ObjectIdentifier(type)] as? S
    }

    /// Register all services in a context
    public func registerAll(in context: ExecutionContext) {
        lock.lock()
        defer { lock.unlock() }

        for (_, service) in services {
            // Use reflection to register each service
            context.register(service)
        }
    }
}
