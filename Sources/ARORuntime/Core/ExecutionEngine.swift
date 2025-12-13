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
        print("[ExecutionEngine] execute() called with entryPoint: \(entryPoint)")

        // Find entry point
        guard let entryFeatureSet = program.featureSets.first(where: {
            $0.featureSet.name == entryPoint
        }) else {
            throw ActionError.entryPointNotFound(entryPoint)
        }

        // Emit application start event
        eventBus.publish(ApplicationStartedEvent(applicationName: entryPoint))

        // Create root context with business activity from entry feature set
        let context = RuntimeContext(
            featureSetName: entryPoint,
            businessActivity: entryFeatureSet.featureSet.businessActivity,
            eventBus: eventBus
        )

        // Register services in context
        services.registerAll(in: context)

        // Wire up event handlers for Socket Event Handler feature sets
        #if !os(Windows)
        registerSocketEventHandlers(for: program, baseContext: context)
        #endif

        // Wire up domain event handlers (e.g., "UserCreated Handler", "OrderPlaced Handler")
        registerDomainEventHandlers(for: program, baseContext: context)

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

    #if !os(Windows)
    /// Register socket event handlers for feature sets with "Socket Event Handler" business activity
    private func registerSocketEventHandlers(for program: AnalyzedProgram, baseContext: RuntimeContext) {
        // Find all feature sets with "Socket Event Handler" business activity
        let socketHandlers = program.featureSets.filter { analyzedFS in
            analyzedFS.featureSet.businessActivity.contains("Socket Event Handler")
        }

        print("[ExecutionEngine] Found \(socketHandlers.count) socket event handlers")

        for analyzedFS in socketHandlers {
            let featureSetName = analyzedFS.featureSet.name
            let lowercaseName = featureSetName.lowercased()
            print("[ExecutionEngine] Registering handler: \(featureSetName) (activity: \(analyzedFS.featureSet.businessActivity))")

            // Determine which event type this handler should respond to
            if lowercaseName.contains("data received") || lowercaseName.contains("data") {
                print("[ExecutionEngine] -> Subscribing to DataReceivedEvent, eventBus=\(ObjectIdentifier(eventBus))")
                // Subscribe to DataReceivedEvent
                eventBus.subscribe(to: DataReceivedEvent.self) { [weak self] event in
                    guard let self = self else { return }
                    print("[ExecutionEngine] DataReceivedEvent received! connectionId=\(event.connectionId), data=\(event.data.count) bytes")
                    await self.executeSocketHandler(
                        analyzedFS,
                        program: program,
                        baseContext: baseContext,
                        eventData: [
                            "packet": SocketPacket(
                                connectionId: event.connectionId,
                                data: event.data
                            )
                        ]
                    )
                }
            } else if lowercaseName.contains("connected") {
                // Subscribe to ClientConnectedEvent
                eventBus.subscribe(to: ClientConnectedEvent.self) { [weak self] event in
                    guard let self = self else { return }
                    await self.executeSocketHandler(
                        analyzedFS,
                        program: program,
                        baseContext: baseContext,
                        eventData: [
                            "connection": SocketConnection(
                                id: event.connectionId,
                                remoteAddress: event.remoteAddress
                            )
                        ]
                    )
                }
            } else if lowercaseName.contains("disconnected") {
                // Subscribe to ClientDisconnectedEvent
                eventBus.subscribe(to: ClientDisconnectedEvent.self) { [weak self] event in
                    guard let self = self else { return }
                    await self.executeSocketHandler(
                        analyzedFS,
                        program: program,
                        baseContext: baseContext,
                        eventData: [
                            "event": SocketDisconnectInfo(
                                connectionId: event.connectionId,
                                reason: event.reason
                            )
                        ]
                    )
                }
            }
        }
    }

    /// Execute a socket event handler feature set
    private func executeSocketHandler(
        _ analyzedFS: AnalyzedFeatureSet,
        program: AnalyzedProgram,
        baseContext: RuntimeContext,
        eventData: [String: any Sendable]
    ) async {
        // Create child context for this event handler with its business activity
        let handlerContext = RuntimeContext(
            featureSetName: analyzedFS.featureSet.name,
            businessActivity: analyzedFS.featureSet.businessActivity,
            eventBus: eventBus,
            parent: baseContext
        )

        // Bind event data to context
        for (key, value) in eventData {
            handlerContext.bind(key, value: value)
        }

        // Copy services from base context
        services.registerAll(in: handlerContext)

        // Execute the handler
        let executor = FeatureSetExecutor(
            actionRegistry: actionRegistry,
            eventBus: eventBus,
            globalSymbols: globalSymbols
        )

        do {
            _ = try await executor.execute(analyzedFS, context: handlerContext)
        } catch {
            eventBus.publish(ErrorOccurredEvent(
                error: String(describing: error),
                context: analyzedFS.featureSet.name,
                recoverable: true
            ))
        }
    }
    #endif

    /// Register domain event handlers for feature sets with "Handler" business activity pattern
    /// For example: "UserCreated Handler", "OrderPlaced Handler"
    private func registerDomainEventHandlers(for program: AnalyzedProgram, baseContext: RuntimeContext) {
        // Find all feature sets with "*Handler" business activity (but not Socket/File event handlers)
        let domainHandlers = program.featureSets.filter { analyzedFS in
            let activity = analyzedFS.featureSet.businessActivity
            return activity.hasSuffix("Handler") &&
                   !activity.contains("Socket Event Handler") &&
                   !activity.contains("File") &&
                   !activity.contains("Application-End")
        }

        print("[ExecutionEngine] Found \(domainHandlers.count) domain event handlers")

        for analyzedFS in domainHandlers {
            let activity = analyzedFS.featureSet.businessActivity

            // Extract event type from business activity
            // e.g., "UserCreated Handler" -> "UserCreated"
            let eventType = activity
                .replacingOccurrences(of: " Handler", with: "")
                .trimmingCharacters(in: .whitespaces)

            print("[ExecutionEngine] Registering domain handler: \(analyzedFS.featureSet.name) for event: \(eventType)")

            // Subscribe to DomainEvent and filter by eventType
            eventBus.subscribe(to: DomainEvent.self) { [weak self] event in
                guard let self = self else { return }

                // Only handle events that match this handler's event type
                if event.domainEventType == eventType {
                    print("[ExecutionEngine] DomainEvent '\(eventType)' received, triggering handler: \(analyzedFS.featureSet.name)")
                    await self.executeDomainEventHandler(
                        analyzedFS,
                        program: program,
                        baseContext: baseContext,
                        event: event
                    )
                }
            }
        }
    }

    /// Execute a domain event handler feature set
    private func executeDomainEventHandler(
        _ analyzedFS: AnalyzedFeatureSet,
        program: AnalyzedProgram,
        baseContext: RuntimeContext,
        event: DomainEvent
    ) async {
        // Create child context for this event handler with its business activity
        let handlerContext = RuntimeContext(
            featureSetName: analyzedFS.featureSet.name,
            businessActivity: analyzedFS.featureSet.businessActivity,
            eventBus: eventBus,
            parent: baseContext
        )

        // Bind event payload to context as "event" with nested access
        // e.g., <Extract> the <user> from the <event: user>
        handlerContext.bind("event", value: event.payload)

        // Also bind payload keys directly for convenience
        for (key, value) in event.payload {
            handlerContext.bind("event:\(key)", value: value)
        }

        // Copy services from base context
        services.registerAll(in: handlerContext)

        // Execute the handler
        let executor = FeatureSetExecutor(
            actionRegistry: actionRegistry,
            eventBus: eventBus,
            globalSymbols: globalSymbols
        )

        do {
            _ = try await executor.execute(analyzedFS, context: handlerContext)
            print("[ExecutionEngine] Domain handler '\(analyzedFS.featureSet.name)' completed successfully")
        } catch {
            print("[ExecutionEngine] Domain handler '\(analyzedFS.featureSet.name)' failed: \(error)")
            eventBus.publish(ErrorOccurredEvent(
                error: String(describing: error),
                context: analyzedFS.featureSet.name,
                recoverable: true
            ))
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

/// Thread-safe storage for published symbols with business activity enforcement
public final class GlobalSymbolStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var symbols: [String: (value: any Sendable, featureSet: String, businessActivity: String)] = [:]

    public init() {}

    /// Store a published symbol with its business activity
    public func publish(name: String, value: any Sendable, fromFeatureSet: String, businessActivity: String) {
        lock.lock()
        defer { lock.unlock() }
        symbols[name] = (value, fromFeatureSet, businessActivity)
    }

    /// Resolve a published symbol (validates business activity)
    /// - Parameters:
    ///   - name: The symbol name
    ///   - forBusinessActivity: The business activity of the requesting feature set
    /// - Returns: The value if found and accessible, nil otherwise
    public func resolve<T: Sendable>(_ name: String, forBusinessActivity: String) -> T? {
        lock.lock()
        defer { lock.unlock() }

        guard let entry = symbols[name] else { return nil }

        // Business activity validation: must match or be empty (framework/external)
        if !entry.businessActivity.isEmpty && !forBusinessActivity.isEmpty &&
           entry.businessActivity != forBusinessActivity {
            return nil  // Access denied - different business activity
        }

        return entry.value as? T
    }

    /// Resolve a published symbol as any Sendable (validates business activity)
    public func resolveAny(_ name: String, forBusinessActivity: String) -> (any Sendable)? {
        lock.lock()
        defer { lock.unlock() }

        guard let entry = symbols[name] else { return nil }

        // Business activity validation: must match or be empty (framework/external)
        if !entry.businessActivity.isEmpty && !forBusinessActivity.isEmpty &&
           entry.businessActivity != forBusinessActivity {
            return nil  // Access denied - different business activity
        }

        return entry.value
    }

    /// Check if a symbol is published and accessible
    public func isPublished(_ name: String, forBusinessActivity: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let entry = symbols[name] else { return false }

        // Business activity validation
        if !entry.businessActivity.isEmpty && !forBusinessActivity.isEmpty &&
           entry.businessActivity != forBusinessActivity {
            return false
        }

        return true
    }

    /// Get the feature set that published a symbol
    public func sourceFeatureSet(for name: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return symbols[name]?.featureSet
    }

    /// Get the business activity that a symbol belongs to
    public func businessActivity(for name: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return symbols[name]?.businessActivity
    }

    /// Check if accessing a symbol would be denied due to business activity mismatch
    public func isAccessDenied(_ name: String, forBusinessActivity: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let entry = symbols[name] else { return false }

        // Access is denied if both have non-empty business activities that don't match
        return !entry.businessActivity.isEmpty &&
               !forBusinessActivity.isEmpty &&
               entry.businessActivity != forBusinessActivity
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

        for (typeId, service) in services {
            // Preserve type ID to avoid type erasure
            context.registerWithTypeId(typeId, service: service)
        }
    }
}
