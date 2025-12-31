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

        // Wire up file event handlers (e.g., "Handle File Modified: File Event Handler")
        registerFileEventHandlers(for: program, baseContext: context)

        // Wire up repository observers (e.g., "user-repository Observer")
        registerRepositoryObservers(for: program, baseContext: context)

        // Wire up state transition observers (e.g., "Audit Changes: status StateObserver")
        registerStateObservers(for: program, baseContext: context)

        // Execute entry point
        let executor = FeatureSetExecutor(
            actionRegistry: actionRegistry,
            eventBus: eventBus,
            globalSymbols: globalSymbols
        )

        do {
            let response = try await executor.execute(entryFeatureSet, context: context)

            // CRITICAL: Wait for all in-flight event handlers to complete
            // This ensures events emitted during Application-Start finish executing
            let completed = await eventBus.awaitPendingEvents(timeout: 10.0)
            if !completed {
                print("[WARNING] Some event handlers did not complete within timeout")
            }

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


        for analyzedFS in socketHandlers {
            let featureSetName = analyzedFS.featureSet.name
            let lowercaseName = featureSetName.lowercased()
            // Determine which event type this handler should respond to
            if lowercaseName.contains("data received") || lowercaseName.contains("data") {
                // Subscribe to DataReceivedEvent
                eventBus.subscribe(to: DataReceivedEvent.self) { [weak self] event in
                    guard let self = self else { return }
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
    /// Supports state guards: "UserCreated Handler<status:active>"
    private func registerDomainEventHandlers(for program: AnalyzedProgram, baseContext: RuntimeContext) {
        // Find all feature sets with "*Handler" business activity (but not Socket/File event handlers)
        // Also match handlers with state guards like "Handler<status:paid>"
        let domainHandlers = program.featureSets.filter { analyzedFS in
            let activity = analyzedFS.featureSet.businessActivity
            let hasHandler = activity.contains(" Handler")
            let isSpecialHandler = activity.contains("Socket Event Handler") ||
                                   activity.contains("File Event Handler") ||
                                   activity.contains("Application-End")
            return hasHandler && !isSpecialHandler
        }

        for analyzedFS in domainHandlers {
            let activity = analyzedFS.featureSet.businessActivity

            // Extract event type from business activity (before "Handler" or "Handler<")
            // e.g., "UserCreated Handler" -> "UserCreated"
            // e.g., "UserCreated Handler<status:active>" -> "UserCreated"
            let eventType: String
            if let handlerRange = activity.range(of: " Handler") {
                eventType = String(activity[..<handlerRange.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
            } else {
                continue // Invalid pattern
            }

            // Parse state guards from angle brackets
            let guardSet = StateGuardSet.parse(from: activity)

            // Subscribe to DomainEvent and filter by eventType and guards
            eventBus.subscribe(to: DomainEvent.self) { [weak self] event in
                guard let self = self else { return }

                // Only handle events that match this handler's event type
                guard event.domainEventType == eventType else { return }

                // Apply state guards if present
                if !guardSet.isEmpty {
                    guard guardSet.allMatch(payload: event.payload) else { return }
                }

                await self.executeDomainEventHandler(
                    analyzedFS,
                    program: program,
                    baseContext: baseContext,
                    event: event
                )
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
        } catch {
            eventBus.publish(ErrorOccurredEvent(
                error: String(describing: error),
                context: analyzedFS.featureSet.name,
                recoverable: true
            ))
        }
    }

    /// Register file event handlers for feature sets with "File Event Handler" business activity
    private func registerFileEventHandlers(for program: AnalyzedProgram, baseContext: RuntimeContext) {
        // Find all feature sets with "File Event Handler" business activity
        let fileHandlers = program.featureSets.filter { analyzedFS in
            analyzedFS.featureSet.businessActivity.contains("File Event Handler")
        }

        for analyzedFS in fileHandlers {
            let featureSetName = analyzedFS.featureSet.name
            let lowercaseName = featureSetName.lowercased()

            // Determine which file event type this handler should respond to
            if lowercaseName.contains("created") {
                eventBus.subscribe(to: FileCreatedEvent.self) { [weak self] event in
                    guard let self = self else { return }
                    await self.executeFileEventHandler(
                        analyzedFS,
                        program: program,
                        baseContext: baseContext,
                        eventData: ["path": event.path]
                    )
                }
            } else if lowercaseName.contains("modified") {
                eventBus.subscribe(to: FileModifiedEvent.self) { [weak self] event in
                    guard let self = self else { return }
                    // Skip temp files (hidden files starting with .)
                    let filename = (event.path as NSString).lastPathComponent
                    guard !filename.hasPrefix(".") else {
                        return
                    }
                    await self.executeFileEventHandler(
                        analyzedFS,
                        program: program,
                        baseContext: baseContext,
                        eventData: ["path": event.path]
                    )
                }
            } else if lowercaseName.contains("deleted") {
                eventBus.subscribe(to: FileDeletedEvent.self) { [weak self] event in
                    guard let self = self else { return }
                    await self.executeFileEventHandler(
                        analyzedFS,
                        program: program,
                        baseContext: baseContext,
                        eventData: ["path": event.path]
                    )
                }
            }
        }
    }

    /// Execute a file event handler feature set
    private func executeFileEventHandler(
        _ analyzedFS: AnalyzedFeatureSet,
        program: AnalyzedProgram,
        baseContext: RuntimeContext,
        eventData: [String: any Sendable]
    ) async {
        // Create child context for this event handler with its own business activity
        let handlerContext = RuntimeContext(
            featureSetName: analyzedFS.featureSet.name,
            businessActivity: analyzedFS.featureSet.businessActivity,
            eventBus: eventBus,
            parent: baseContext
        )

        // Bind event data to context as "event" with nested access
        // e.g., <Extract> the <path> from the <event: path>
        handlerContext.bind("event", value: eventData)

        // Also bind event keys directly for convenience
        for (key, value) in eventData {
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
        } catch {
            eventBus.publish(ErrorOccurredEvent(
                error: String(describing: error),
                context: analyzedFS.featureSet.name,
                recoverable: true
            ))
        }
    }

    /// Register repository observers for feature sets with "Observer" business activity pattern
    /// For example: "user-repository Observer", "order-repository Observer"
    /// Supports state guards: "user-repository Observer<status:active>"
    private func registerRepositoryObservers(for program: AnalyzedProgram, baseContext: RuntimeContext) {
        // Find all feature sets with "*-repository Observer" business activity
        // Also match observers with state guards like "Observer<status:active>"
        let observers = program.featureSets.filter { analyzedFS in
            let activity = analyzedFS.featureSet.businessActivity
            return activity.contains(" Observer") &&
                   activity.contains("-repository")
        }

        for analyzedFS in observers {
            let activity = analyzedFS.featureSet.businessActivity

            // Extract repository name from business activity (before "Observer")
            // e.g., "user-repository Observer" -> "user-repository"
            // e.g., "user-repository Observer<status:active>" -> "user-repository"
            let repositoryName: String
            if let observerRange = activity.range(of: " Observer") {
                repositoryName = String(activity[..<observerRange.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
            } else {
                continue // Invalid pattern
            }

            // Parse state guards from angle brackets
            let guardSet = StateGuardSet.parse(from: activity)

            // Subscribe to RepositoryChangedEvent and filter by repositoryName and guards
            eventBus.subscribe(to: RepositoryChangedEvent.self) { [weak self] event in
                guard let self = self else { return }

                // Only handle events that match this observer's repository
                guard event.repositoryName == repositoryName else { return }

                // Apply state guards if present (check newValue for creates/updates, oldValue for deletes)
                if !guardSet.isEmpty {
                    let entityToCheck: [String: any Sendable]?
                    if let newValue = event.newValue as? [String: any Sendable] {
                        entityToCheck = newValue
                    } else if let oldValue = event.oldValue as? [String: any Sendable] {
                        entityToCheck = oldValue
                    } else {
                        entityToCheck = nil
                    }

                    guard let entity = entityToCheck,
                          guardSet.allMatch(payload: entity) else { return }
                }

                await self.executeRepositoryObserver(
                    analyzedFS,
                    program: program,
                    baseContext: baseContext,
                    event: event
                )
            }
        }
    }

    /// Register state transition observers for feature sets with "StateObserver" business activity
    /// Supports optional transition filter: "status StateObserver<draft_to_placed>"
    /// For example: "Audit Changes: status StateObserver", "Notify Placed: status StateObserver<draft_to_placed>"
    private func registerStateObservers(for program: AnalyzedProgram, baseContext: RuntimeContext) {
        // Find all feature sets with "StateObserver" business activity
        let stateObservers = program.featureSets.filter { analyzedFS in
            analyzedFS.featureSet.businessActivity.contains("StateObserver")
        }

        for analyzedFS in stateObservers {
            let activity = analyzedFS.featureSet.businessActivity

            // Parse: "status StateObserver" or "status StateObserver<draft_to_placed>"
            var fieldName = ""
            var transitionFilter: String? = nil

            if let angleStart = activity.firstIndex(of: "<"),
               let angleEnd = activity.firstIndex(of: ">") {
                // Has transition filter: "status StateObserver<draft_to_placed>"
                transitionFilter = String(activity[activity.index(after: angleStart)..<angleEnd])
                let beforeAngle = String(activity[..<angleStart])
                fieldName = beforeAngle
                    .replacingOccurrences(of: " StateObserver", with: "")
                    .replacingOccurrences(of: "StateObserver", with: "")
                    .trimmingCharacters(in: .whitespaces)
                    .lowercased()
            } else {
                // No filter: "status StateObserver"
                fieldName = activity
                    .replacingOccurrences(of: " StateObserver", with: "")
                    .replacingOccurrences(of: "StateObserver", with: "")
                    .trimmingCharacters(in: .whitespaces)
                    .lowercased()
            }

            // Capture as constants for Sendable closure
            let capturedFieldName = fieldName
            let capturedTransitionFilter = transitionFilter

            // Subscribe to StateTransitionEvent and filter by field name and optional transition
            eventBus.subscribe(to: StateTransitionEvent.self) { [weak self] event in
                guard let self = self else { return }

                // Match field name (empty = match all fields)
                let fieldMatches = capturedFieldName.isEmpty || event.fieldName.lowercased() == capturedFieldName

                // Match transition filter if specified
                let transitionMatches: Bool
                if let filter = capturedTransitionFilter {
                    let expectedTransition = "\(event.fromState)_to_\(event.toState)"
                    transitionMatches = expectedTransition.lowercased() == filter.lowercased()
                } else {
                    transitionMatches = true  // No filter = match all transitions
                }

                let shouldHandle = fieldMatches && transitionMatches

                if shouldHandle {
                    await self.executeStateObserver(
                        analyzedFS,
                        program: program,
                        baseContext: baseContext,
                        event: event
                    )
                }
            }
        }
    }

    /// Execute a repository observer feature set
    private func executeRepositoryObserver(
        _ analyzedFS: AnalyzedFeatureSet,
        program: AnalyzedProgram,
        baseContext: RuntimeContext,
        event: RepositoryChangedEvent
    ) async {
        // Create child context for this observer with its own business activity
        let observerContext = RuntimeContext(
            featureSetName: analyzedFS.featureSet.name,
            businessActivity: analyzedFS.featureSet.businessActivity,
            eventBus: eventBus,
            parent: baseContext
        )

        // Build event payload for the observer
        var eventPayload: [String: any Sendable] = [
            "repositoryName": event.repositoryName,
            "changeType": event.changeType.rawValue,
            "timestamp": event.timestamp
        ]

        if let entityId = event.entityId {
            eventPayload["entityId"] = entityId
        }

        if let newValue = event.newValue {
            eventPayload["newValue"] = newValue
        }

        if let oldValue = event.oldValue {
            eventPayload["oldValue"] = oldValue
        }

        // Bind event payload to context as "event" with nested access
        // e.g., <Extract> the <changeType> from the <event: changeType>
        observerContext.bind("event", value: eventPayload)

        // Also bind event keys directly for convenience
        for (key, value) in eventPayload {
            observerContext.bind("event:\(key)", value: value)
        }

        // Copy services from base context
        services.registerAll(in: observerContext)

        // Execute the observer
        let executor = FeatureSetExecutor(
            actionRegistry: actionRegistry,
            eventBus: eventBus,
            globalSymbols: globalSymbols
        )

        do {
            _ = try await executor.execute(analyzedFS, context: observerContext)
        } catch {
            eventBus.publish(ErrorOccurredEvent(
                error: String(describing: error),
                context: analyzedFS.featureSet.name,
                recoverable: true
            ))
        }
    }

    /// Execute a state observer feature set
    private func executeStateObserver(
        _ analyzedFS: AnalyzedFeatureSet,
        program: AnalyzedProgram,
        baseContext: RuntimeContext,
        event: StateTransitionEvent
    ) async {
        // Create child context for this observer with its own business activity
        let handlerContext = RuntimeContext(
            featureSetName: analyzedFS.featureSet.name,
            businessActivity: analyzedFS.featureSet.businessActivity,
            eventBus: eventBus,
            parent: baseContext
        )

        // Bind transition data to context as "transition" with nested access
        // e.g., <Extract> the <fromState> from the <transition: fromState>
        var transitionData: [String: any Sendable] = [
            "fieldName": event.fieldName,
            "objectName": event.objectName,
            "fromState": event.fromState,
            "toState": event.toState
        ]
        if let entityId = event.entityId {
            transitionData["entityId"] = entityId
        }
        if let entity = event.entity {
            transitionData["entity"] = entity
        }
        handlerContext.bind("transition", value: transitionData)

        // Also bind transition keys directly for convenience
        handlerContext.bind("transition:fieldName", value: event.fieldName)
        handlerContext.bind("transition:objectName", value: event.objectName)
        handlerContext.bind("transition:fromState", value: event.fromState)
        handlerContext.bind("transition:toState", value: event.toState)
        if let entityId = event.entityId {
            handlerContext.bind("transition:entityId", value: entityId)
        }
        if let entity = event.entity {
            handlerContext.bind("transition:entity", value: entity)
        }

        // Copy services from base context
        services.registerAll(in: handlerContext)

        // Execute the observer
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
