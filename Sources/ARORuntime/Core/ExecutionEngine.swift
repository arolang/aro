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
///
/// Converted to actor for Swift 6.2 concurrency safety (Issue #2).
public actor ExecutionEngine {
    // MARK: - Properties

    /// The action registry for looking up action implementations
    private let actionRegistry: ActionRegistry

    /// The event bus for event-driven communication
    private let eventBus: EventBus

    /// Global symbol registry for published variables
    private let globalSymbols: GlobalSymbolStorage

    /// Public accessor for global symbols (needed for HTTP handlers)
    public var sharedGlobalSymbols: GlobalSymbolStorage {
        get async {
            return globalSymbols
        }
    }

    /// Service registry for dependency injection
    private let services: ServiceRegistry

    /// URLs currently being processed (for deduplication of CrawlPage events)
    /// This prevents multiple parallel handlers from processing the same URL
    private var processingUrls: Set<String> = []

    /// Track if the application entered wait state (Keepalive action)
    private var _enteredWaitState: Bool = false

    /// Check if the application entered wait state (Keepalive action)
    public var enteredWaitState: Bool {
        get { _enteredWaitState }
    }

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
    public func register<S: Sendable>(service: S) async {
        await services.register(service)
    }

    /// Inject all registered services into an existing context
    /// Used by Runtime.executeApplicationEnd so Application-End handlers can access services
    public func registerServicesInContext(_ context: ExecutionContext) async {
        await services.registerAll(in: context)
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

        // Find entry point — O(1) via byName index
        guard let entryFeatureSet = program.byName[entryPoint] else {
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
        await services.registerAll(in: context)

        // Set up schema registry for typed event extraction (ARO-0046)
        // If an OpenAPI spec is loaded, create a schema registry for schema-based validation
        if let specService = context.service(OpenAPISpecService.self) {
            let schemaRegistry = OpenAPISchemaRegistry(spec: specService.spec)
            context.setSchemaRegistry(schemaRegistry)
        }

        // Wire up event handlers for Socket Event Handler feature sets
        // Socket events work on Windows via WindowsSocketServer (FlyingSocks)
        registerSocketEventHandlers(for: program, baseContext: context)

        // Wire up event handlers for WebSocket Event Handler feature sets
        registerWebSocketEventHandlers(for: program, baseContext: context)

        // Wire up domain event handlers (e.g., "UserCreated Handler", "OrderPlaced Handler")
        registerDomainEventHandlers(for: program, baseContext: context)

        // Wire up plugin event handlers (from .aro files in plugins)
        registerPluginEventHandlers(baseContext: context)

        // Wire up notification event handlers (e.g., "NotificationSent Handler")
        registerNotificationEventHandlers(for: program, baseContext: context)

        // Wire up file event handlers (e.g., "Handle File Modified: File Event Handler")
        registerFileEventHandlers(for: program, baseContext: context)

        // Wire up repository observers (e.g., "user-repository Observer")
        registerRepositoryObservers(for: program, baseContext: context)

        // Wire up repository eviction handlers (e.g., "cache-repository Evicted Handler")
        registerEvictionHandlers(for: program, baseContext: context)

        // Wire up watch handlers (e.g., "Dashboard Watch: TasksUpdated Handler" or "Dashboard Watch: task-repository Observer")
        registerWatchHandlers(for: program, baseContext: context)

        // Wire up state transition observers (e.g., "Audit Changes: status StateObserver")
        registerStateObservers(for: program, baseContext: context)

        // Wire up key press handlers (e.g., "Navigate Menu: KeyPress Handler" or "Select Item: KeyPress Handler<key:enter>")
        registerKeyPressHandlers(for: program, baseContext: context)

        // Execute entry point
        let executor = FeatureSetExecutor(
            actionRegistry: actionRegistry,
            eventBus: eventBus,
            globalSymbols: globalSymbols
        )

        do {
            let response = try await executor.execute(entryFeatureSet, context: context)

            // Check if application entered wait state (for response printing suppression)
            _enteredWaitState = context.isWaiting

            // CRITICAL: Wait for all in-flight event handlers to complete
            // This ensures events emitted during Application-Start finish executing
            let completed = await eventBus.awaitPendingEvents(timeout: AROEventHandlerDefaultTimeout)
            if !completed {
                let pending = await eventBus.getPendingHandlerCount()
                print("[WARNING] \(pending) event handler(s) did not complete within \(AROEventHandlerDefaultTimeout)s timeout")
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

    /// Register socket event handlers for feature sets with "Socket Event Handler" business activity
    /// Socket events work on all platforms via platform-specific implementations
    private func registerSocketEventHandlers(for program: AnalyzedProgram, baseContext: RuntimeContext) {
        // Use byActivity index: O(k) key scan instead of O(n) linear filter
        let socketHandlers = program.byActivity
            .filter { $0.key.contains("Socket Event Handler") }
            .flatMap { $0.value }


        for analyzedFS in socketHandlers {
            let featureSetName = analyzedFS.featureSet.name
            let lowercaseName = featureSetName.lowercased()
            // Determine which event type this handler should respond to.
            // Check "disconnect" before "connect" since "disconnect" contains "connect".
            if lowercaseName.contains("disconnect") {
                // Subscribe to ClientDisconnectedEvent
                // Matches: "Handle Client Disconnected", "Handle Socket Disconnect", etc.
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
            } else if lowercaseName.contains("connect") {
                // Subscribe to ClientConnectedEvent
                // Matches: "Handle Client Connected", "Handle Socket Connect", etc.
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
            } else if lowercaseName.contains("data") || lowercaseName.contains("message") || lowercaseName.contains("received") {
                // Subscribe to DataReceivedEvent
                // Matches: "Handle Data Received", "Handle Socket Message", etc.
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
        await services.registerAll(in: handlerContext)

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

    /// Register WebSocket event handlers for feature sets with "WebSocket Event Handler" business activity
    private func registerWebSocketEventHandlers(for program: AnalyzedProgram, baseContext: RuntimeContext) {
        // Use byActivity index: O(k) key scan
        let wsHandlers = program.byActivity
            .filter { $0.key.contains("WebSocket Event Handler") }
            .flatMap { $0.value }

        for analyzedFS in wsHandlers {
            let featureSetName = analyzedFS.featureSet.name
            let lowercaseName = featureSetName.lowercased()

            // Determine which event type this handler should respond to
            if lowercaseName.contains("message") {
                // Subscribe to WebSocketMessageEvent
                eventBus.subscribe(to: WebSocketMessageEvent.self) { [weak self] event in
                    guard let self = self else { return }
                    await self.executeSocketHandler(
                        analyzedFS,
                        program: program,
                        baseContext: baseContext,
                        eventData: [
                            "event": [
                                "connectionId": event.connectionId,
                                "message": event.message
                            ] as [String: any Sendable]
                        ]
                    )
                }
            } else if lowercaseName.contains("connect") && !lowercaseName.contains("disconnect") {
                // Subscribe to WebSocketConnectedEvent
                eventBus.subscribe(to: WebSocketConnectedEvent.self) { [weak self] event in
                    guard let self = self else { return }
                    await self.executeSocketHandler(
                        analyzedFS,
                        program: program,
                        baseContext: baseContext,
                        eventData: [
                            "event": [
                                "connectionId": event.connectionId,
                                "path": event.path,
                                "remoteAddress": event.remoteAddress
                            ] as [String: any Sendable]
                        ]
                    )
                }
            } else if lowercaseName.contains("disconnect") {
                // Subscribe to WebSocketDisconnectedEvent
                eventBus.subscribe(to: WebSocketDisconnectedEvent.self) { [weak self] event in
                    guard let self = self else { return }
                    await self.executeSocketHandler(
                        analyzedFS,
                        program: program,
                        baseContext: baseContext,
                        eventData: [
                            "event": [
                                "connectionId": event.connectionId,
                                "reason": event.reason
                            ] as [String: any Sendable]
                        ]
                    )
                }
            }
        }
    }

    /// Register domain event handlers for feature sets with "Handler" business activity pattern
    /// For example: "UserCreated Handler", "OrderPlaced Handler"
    /// Supports state guards: "UserCreated Handler<status:active>"
    private func registerDomainEventHandlers(for program: AnalyzedProgram, baseContext: RuntimeContext) {
        // Use byActivity index: iterate keys instead of all feature sets
        let domainHandlers = program.byActivity
            .filter { key, _ in
                let hasHandler = key.contains(" Handler")
                let isSpecialHandler = key.contains("Socket Event Handler") ||
                                       key.contains("WebSocket Event Handler") ||
                                       key.contains("File Event Handler") ||
                                       key.contains("KeyPress Handler") ||
                                       key.contains("Application-End")
                return hasHandler && !isSpecialHandler
            }
            .flatMap { $0.value }

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
            // CRITICAL: Capture all needed values to avoid actor reentrancy deadlock.
            // The handler must NOT call back into the actor since the actor may be
            // blocked waiting for handlers to complete (via publishAndTrack).
            let capturedActionRegistry = actionRegistry
            let capturedEventBus = eventBus
            let capturedGlobalSymbols = globalSymbols
            let capturedServices = services

            eventBus.subscribe(to: DomainEvent.self) { event in
                // Only handle events that match this handler's event type
                guard event.domainEventType == eventType else { return }

                // Apply state guards if present
                if !guardSet.isEmpty {
                    guard guardSet.allMatch(payload: event.payload) else { return }
                }

                // Execute handler WITHOUT actor isolation to avoid deadlock
                await ExecutionEngine.executeDomainEventHandlerStatic(
                    analyzedFS,
                    baseContext: baseContext,
                    event: event,
                    actionRegistry: capturedActionRegistry,
                    eventBus: capturedEventBus,
                    globalSymbols: capturedGlobalSymbols,
                    services: capturedServices
                )
            }
        }
    }

    /// Register event handlers from plugin feature sets
    /// Plugins can provide .aro files with event handler feature sets
    private func registerPluginEventHandlers(baseContext: RuntimeContext) {
        // Get all plugin feature sets
        let pluginFeatureSets = PluginFeatureSetRegistry.shared.getAll()

        if ProcessInfo.processInfo.environment["ARO_DEBUG"] != nil {
            FileHandle.standardError.write(Data("[ExecutionEngine] Found \(pluginFeatureSets.count) plugin feature sets\n".utf8))
        }

        // Filter for domain event handlers
        let domainHandlers = pluginFeatureSets.filter { registered in
            let activity = registered.analyzedFeatureSet.featureSet.businessActivity
            let hasHandler = activity.contains(" Handler")
            let isSpecialHandler = activity.contains("Socket Event Handler") ||
                                   activity.contains("WebSocket Event Handler") ||
                                   activity.contains("File Event Handler") ||
                                   activity.contains("Application-End")
            return hasHandler && !isSpecialHandler
        }

        if ProcessInfo.processInfo.environment["ARO_DEBUG"] != nil {
            FileHandle.standardError.write(Data("[ExecutionEngine] Found \(domainHandlers.count) plugin domain handlers\n".utf8))
            for handler in domainHandlers {
                FileHandle.standardError.write(Data("[ExecutionEngine] - \(handler.qualifiedName) (\(handler.analyzedFeatureSet.featureSet.businessActivity))\n".utf8))
            }
        }

        for registered in domainHandlers {
            let analyzedFS = registered.analyzedFeatureSet
            let activity = analyzedFS.featureSet.businessActivity

            // Extract event type from business activity
            let eventType: String
            if let handlerRange = activity.range(of: " Handler") {
                eventType = String(activity[..<handlerRange.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
            } else {
                continue
            }

            // Parse state guards
            let guardSet = StateGuardSet.parse(from: activity)

            // Capture values for closure
            let capturedActionRegistry = actionRegistry
            let capturedEventBus = eventBus
            let capturedGlobalSymbols = globalSymbols
            let capturedServices = services

            let capturedEventType = eventType
            eventBus.subscribe(to: DomainEvent.self) { event in
                if ProcessInfo.processInfo.environment["ARO_DEBUG"] != nil {
                    FileHandle.standardError.write(Data("[ExecutionEngine] Plugin handler received event: \(event.domainEventType), expecting: \(capturedEventType)\n".utf8))
                }
                guard event.domainEventType == capturedEventType else { return }

                if !guardSet.isEmpty {
                    guard guardSet.allMatch(payload: event.payload) else { return }
                }

                if ProcessInfo.processInfo.environment["ARO_DEBUG"] != nil {
                    FileHandle.standardError.write(Data("[ExecutionEngine] Executing plugin handler for: \(capturedEventType)\n".utf8))
                }

                await ExecutionEngine.executeDomainEventHandlerStatic(
                    analyzedFS,
                    baseContext: baseContext,
                    event: event,
                    actionRegistry: capturedActionRegistry,
                    eventBus: capturedEventBus,
                    globalSymbols: capturedGlobalSymbols,
                    services: capturedServices
                )
            }
        }
    }

    /// Generic event handler executor (static version to avoid actor deadlock) - ARO-0054
    /// This is called from event subscriptions and must NOT require actor isolation
    /// to prevent deadlock when the actor is blocked waiting for handlers.
    private static func executeHandler<E: RuntimeEvent>(
        _ analyzedFS: AnalyzedFeatureSet,
        baseContext: RuntimeContext,
        event: E,
        actionRegistry: ActionRegistry,
        eventBus: EventBus,
        globalSymbols: GlobalSymbolStorage,
        services: ServiceRegistry,
        bindEventData: @Sendable (RuntimeContext, E) -> Void
    ) async {
        // Create child context for this event handler with its business activity
        let handlerContext = RuntimeContext(
            featureSetName: analyzedFS.featureSet.name,
            businessActivity: analyzedFS.featureSet.businessActivity,
            eventBus: eventBus,
            parent: baseContext
        )

        // Bind event-specific data using the provided closure
        bindEventData(handlerContext, event)

        // Copy services from base context
        await services.registerAll(in: handlerContext)

        // Evaluate optional when-guard on the feature set declaration
        // e.g., `(Handler Name: Event Handler) when <trigger> = "startup" { ... }`
        if let whenCondition = analyzedFS.featureSet.whenCondition {
            let evaluator = ExpressionEvaluator()
            do {
                let condResult = try await evaluator.evaluate(whenCondition, context: handlerContext)
                let passes: Bool
                if let b = condResult as? Bool { passes = b }
                else if let i = condResult as? Int { passes = i != 0 }
                else { passes = !String(describing: condResult).isEmpty }
                guard passes else { return }
            } catch {
                // Guard evaluation error: skip this handler (don't crash)
                return
            }
        }

        // Execute the handler
        let executor = FeatureSetExecutor(
            actionRegistry: actionRegistry,
            eventBus: eventBus,
            globalSymbols: globalSymbols
        )

        do {
            AROLogger.debug("About to execute handler: \(analyzedFS.featureSet.name)")
            _ = try await executor.execute(analyzedFS, context: handlerContext)
            AROLogger.debug("Handler executed successfully: \(analyzedFS.featureSet.name)")
        } catch {
            AROLogger.error("Handler error: \(error)")
            eventBus.publish(ErrorOccurredEvent(
                error: String(describing: error),
                context: analyzedFS.featureSet.name,
                recoverable: true
            ))
        }
    }

    /// Execute a domain event handler feature set (static version to avoid actor deadlock)
    private static func executeDomainEventHandlerStatic(
        _ analyzedFS: AnalyzedFeatureSet,
        baseContext: RuntimeContext,
        event: DomainEvent,
        actionRegistry: ActionRegistry,
        eventBus: EventBus,
        globalSymbols: GlobalSymbolStorage,
        services: ServiceRegistry
    ) async {
        await executeHandler(
            analyzedFS,
            baseContext: baseContext,
            event: event,
            actionRegistry: actionRegistry,
            eventBus: eventBus,
            globalSymbols: globalSymbols,
            services: services
        ) { context, event in
            // Bind event payload to context as "event" with nested access
            context.bind("event", value: event.payload)

            // Also bind payload keys directly for convenience
            for (key, value) in event.payload {
                context.bind("event:\(key)", value: value)
            }
        }
    }

    /// Execute a repository observer feature set (static version to avoid actor deadlock)
    private static func executeRepositoryObserverStatic(
        _ analyzedFS: AnalyzedFeatureSet,
        baseContext: RuntimeContext,
        event: RepositoryChangedEvent,
        actionRegistry: ActionRegistry,
        eventBus: EventBus,
        globalSymbols: GlobalSymbolStorage,
        services: ServiceRegistry
    ) async {
        await executeHandler(
            analyzedFS,
            baseContext: baseContext,
            event: event,
            actionRegistry: actionRegistry,
            eventBus: eventBus,
            globalSymbols: globalSymbols,
            services: services
        ) { context, event in
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
            context.bind("event", value: eventPayload)

            // Also bind event keys directly for convenience
            for (key, value) in eventPayload {
                context.bind("event:\(key)", value: value)
            }
        }
    }

    /// Register notification event handlers for feature sets with "NotificationSent Handler" business activity
    private func registerNotificationEventHandlers(for program: AnalyzedProgram, baseContext: RuntimeContext) {
        // Use byActivity index for O(1) key lookup
        let notificationHandlers = program.byActivity
            .filter { $0.key.contains("NotificationSent Handler") }
            .flatMap { $0.value }

        for analyzedFS in notificationHandlers {
            // Subscribe to NotificationSentEvent
            eventBus.subscribe(to: NotificationSentEvent.self) { [weak self] event in
                guard let self = self else { return }
                await self.executeNotificationEventHandler(
                    analyzedFS,
                    program: program,
                    baseContext: baseContext,
                    event: event
                )
            }
        }
    }

    /// Execute a notification event handler feature set
    private func executeNotificationEventHandler(
        _ analyzedFS: AnalyzedFeatureSet,
        program: AnalyzedProgram,
        baseContext: RuntimeContext,
        event: NotificationSentEvent
    ) async {
        // Create child context for this event handler with its business activity
        let handlerContext = RuntimeContext(
            featureSetName: analyzedFS.featureSet.name,
            businessActivity: analyzedFS.featureSet.businessActivity,
            eventBus: eventBus,
            parent: baseContext
        )

        // Bind event properties to context
        // e.g., <Extract> the <message> from the <event: message>
        // Include the target value in the event dict so handlers can use:
        //   Extract the <user> from the <event: user>.
        // This mirrors how domain event handlers access payload via Extract.
        var eventDict: [String: any Sendable] = [
            "message": event.message,
            "target": event.target
        ]
        if let targetValue = event.targetValue {
            eventDict[event.target] = targetValue
            if event.target != "user" {
                eventDict["user"] = targetValue
            }
        }
        handlerContext.bind("event", value: eventDict as [String: any Sendable])
        handlerContext.bind("event:message", value: event.message)
        handlerContext.bind("event:target", value: event.target)

        // Also bind colon-keyed variants for backward compatibility:
        //   Extract the <user> from the <event: user>.  (via event["user"] in dict above)
        //   context.resolveAny("event:user")            (via explicit colon-key below)
        if let targetValue = event.targetValue {
            handlerContext.bind("event:\(event.target)", value: targetValue)
            if event.target != "user" {
                handlerContext.bind("event:user", value: targetValue)
            }
        }

        // Evaluate feature-set-level when/where condition if present.
        // Bind the target object's fields directly so `where <age> >= 16` works
        // without requiring a fully qualified `<event: user: age>` expression.
        if let condition = analyzedFS.featureSet.whenCondition {
            if let targetValue = event.targetValue as? [String: any Sendable] {
                for (key, value) in targetValue {
                    handlerContext.bind(key, value: value)
                }
            }
            let evaluator = ExpressionEvaluator()
            do {
                let result = try await evaluator.evaluate(condition, context: handlerContext)
                let passes: Bool
                if let b = result as? Bool { passes = b }
                else if let i = result as? Int { passes = i != 0 }
                else { passes = false }
                guard passes else { return }
            } catch {
                return // Skip handler silently if condition evaluation fails
            }
        }

        // Copy services from base context
        await services.registerAll(in: handlerContext)

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
        // Use byActivity index: O(k) key scan
        let fileHandlers = program.byActivity
            .filter { $0.key.contains("File Event Handler") }
            .flatMap { $0.value }

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
        await services.registerAll(in: handlerContext)

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
        // Use byActivity index: O(k) key scan
        let observers = program.byActivity
            .filter { $0.key.contains(" Observer") && $0.key.contains("-repository") }
            .flatMap { $0.value }

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
            // CRITICAL: Capture values to avoid actor reentrancy deadlock
            let capturedActionRegistry = actionRegistry
            let capturedEventBus = eventBus
            let capturedGlobalSymbols = globalSymbols
            let capturedServices = services

            // Capture the feature-set-level when condition for evaluation
            let whenCondition = analyzedFS.featureSet.whenCondition

            eventBus.subscribe(to: RepositoryChangedEvent.self) { event in
                // Only handle events that match this observer's repository
                guard event.repositoryName == repositoryName else { return }

                // Evaluate feature-set-level when condition (e.g., when <message-repository: count> > 40)
                if let condition = whenCondition {
                    // Create temporary context for condition evaluation
                    let evalContext = RuntimeContext(
                        featureSetName: analyzedFS.featureSet.name,
                        businessActivity: analyzedFS.featureSet.businessActivity,
                        eventBus: capturedEventBus,
                        parent: baseContext
                    )

                    let evaluator = ExpressionEvaluator()
                    do {
                        let conditionResult = try await evaluator.evaluate(condition, context: evalContext)
                        // Convert condition result to boolean
                        let isTrue: Bool
                        if let b = conditionResult as? Bool {
                            isTrue = b
                        } else if let i = conditionResult as? Int {
                            isTrue = i != 0
                        } else {
                            isTrue = false
                        }
                        guard isTrue else {
                            return  // Condition is false - skip this observer
                        }
                    } catch {
                        // Log error but skip observer silently on evaluation failure
                        return
                    }
                }

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

                // Execute observer WITHOUT actor isolation to avoid deadlock
                await ExecutionEngine.executeRepositoryObserverStatic(
                    analyzedFS,
                    baseContext: baseContext,
                    event: event,
                    actionRegistry: capturedActionRegistry,
                    eventBus: capturedEventBus,
                    globalSymbols: capturedGlobalSymbols,
                    services: capturedServices
                )
            }
        }
    }

    /// Register eviction handlers for feature sets with "Evicted Handler" business activity pattern.
    /// For example: "cache-repository Evicted Handler"
    private func registerEvictionHandlers(for program: AnalyzedProgram, baseContext: RuntimeContext) {
        // Use byActivity index: O(k) key scan
        let handlers = program.byActivity
            .filter { $0.key.hasSuffix(" Evicted Handler") && $0.key.contains("-repository") }
            .flatMap { $0.value }

        for analyzedFS in handlers {
            let activity = analyzedFS.featureSet.businessActivity
            guard let range = activity.range(of: " Evicted Handler") else { continue }
            let repositoryName = String(activity[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)

            let capturedActionRegistry = actionRegistry
            let capturedEventBus = eventBus
            let capturedGlobalSymbols = globalSymbols
            let capturedServices = services

            eventBus.subscribe(to: RepositoryEvictedEvent.self) { event in
                guard event.repositoryName == repositoryName else { return }

                let context = RuntimeContext(
                    featureSetName: analyzedFS.featureSet.name,
                    businessActivity: analyzedFS.featureSet.businessActivity,
                    eventBus: capturedEventBus,
                    parent: baseContext
                )

                // Bind event payload so Extract works
                let payload: [String: any Sendable] = [
                    "evictedItem": event.evictedItem,
                    "repositoryName": event.repositoryName,
                    "reason": event.reason,
                    "timestamp": event.timestamp.timeIntervalSince1970
                ]
                context.bind("event", value: payload)

                let executor = FeatureSetExecutor(
                    actionRegistry: capturedActionRegistry,
                    eventBus: capturedEventBus,
                    globalSymbols: capturedGlobalSymbols
                )
                do {
                    _ = try await executor.execute(analyzedFS, context: context)
                } catch {
                    FileHandle.standardError.write(
                        Data("[ExecutionEngine] Eviction handler '\(analyzedFS.featureSet.name)' error: \(error)\n".utf8)
                    )
                }
            }
        }
    }

    /// Register watch handlers for feature sets with " Watch:" business activity pattern (ARO-0052)
    /// Supports two patterns:
    /// - Event-based: "{Name} Watch: {EventType} Handler" - triggered by domain events
    /// - Repository-based: "{Name} Watch: {repository} Observer" - triggered by repository changes
    /// Examples: "Dashboard Watch: TasksUpdated Handler", "Dashboard Watch: task-repository Observer"
    private func registerWatchHandlers(for program: AnalyzedProgram, baseContext: RuntimeContext) {
        // Find all feature sets with " Watch:" in business activity
        let watchHandlers = program.featureSets.filter { analyzedFS in
            analyzedFS.featureSet.businessActivity.contains(" Watch:")
        }

        for analyzedFS in watchHandlers {
            let activity = analyzedFS.featureSet.businessActivity

            // Extract pattern after " Watch:"
            guard let watchRange = activity.range(of: " Watch:") else { continue }
            let pattern = String(activity[watchRange.upperBound...]).trimmingCharacters(in: .whitespaces)

            // Determine if Handler or Observer pattern
            if pattern.hasSuffix(" Handler") {
                // Event-based watch: "{Name} Watch: {EventType} Handler"
                let eventType = pattern.replacingOccurrences(of: " Handler", with: "")
                    .trimmingCharacters(in: .whitespaces)

                // CRITICAL: Capture values to avoid actor reentrancy deadlock
                let capturedActionRegistry = actionRegistry
                let capturedEventBus = eventBus
                let capturedGlobalSymbols = globalSymbols
                let capturedServices = services

                eventBus.subscribe(to: DomainEvent.self) { event in
                    // Only handle events that match this watch handler's event type
                    guard event.domainEventType == eventType else { return }

                    await ExecutionEngine.executeHandler(
                        analyzedFS,
                        baseContext: baseContext,
                        event: event,
                        actionRegistry: capturedActionRegistry,
                        eventBus: capturedEventBus,
                        globalSymbols: capturedGlobalSymbols,
                        services: capturedServices
                    ) { context, event in
                        let eventPayload: [String: any Sendable] = [
                            "timestamp": event.timestamp,
                            "domainEventType": event.domainEventType,
                            "payload": event.payload
                        ]
                        context.bind("event", value: eventPayload)
                        for (key, value) in eventPayload {
                            context.bind("event:\(key)", value: value)
                        }
                    }
                }

            } else if pattern.hasSuffix(" Observer") {
                // Repository-based watch: "{Name} Watch: {repository} Observer"
                let repositoryName = pattern.replacingOccurrences(of: " Observer", with: "")
                    .trimmingCharacters(in: .whitespaces)

                // CRITICAL: Capture values to avoid actor reentrancy deadlock
                let capturedActionRegistry = actionRegistry
                let capturedEventBus = eventBus
                let capturedGlobalSymbols = globalSymbols
                let capturedServices = services

                eventBus.subscribe(to: RepositoryChangedEvent.self) { event in
                    // Only handle events that match this watch handler's repository
                    guard event.repositoryName == repositoryName else { return }

                    await ExecutionEngine.executeHandler(
                        analyzedFS,
                        baseContext: baseContext,
                        event: event,
                        actionRegistry: capturedActionRegistry,
                        eventBus: capturedEventBus,
                        globalSymbols: capturedGlobalSymbols,
                        services: capturedServices
                    ) { context, event in
                        var eventPayload: [String: any Sendable] = [
                            "timestamp": event.timestamp,
                            "repositoryName": event.repositoryName,
                            "changeType": event.changeType.rawValue
                        ]
                        if let entityId = event.entityId { eventPayload["entityId"] = entityId }
                        if let newValue = event.newValue { eventPayload["newValue"] = newValue }
                        if let oldValue = event.oldValue { eventPayload["oldValue"] = oldValue }
                        context.bind("event", value: eventPayload)
                        for (key, value) in eventPayload {
                            context.bind("event:\(key)", value: value)
                        }
                    }
                }
            }
        }
    }

    /// Register state transition observers for feature sets with "StateObserver" or "StateTransition Handler" business activity
    /// Supports:
    ///   - "status StateObserver<draft_to_placed>"  (legacy syntax, binds as "transition")
    ///   - "StateTransition Handler<toState:approved>"  (new syntax, binds as "event")
    private func registerStateObservers(for program: AnalyzedProgram, baseContext: RuntimeContext) {
        // Find all feature sets with state-transition business activity
        let stateObservers = program.featureSets.filter { analyzedFS in
            let activity = analyzedFS.featureSet.businessActivity
            return activity.contains("StateObserver") || activity.contains("StateTransition Handler")
        }

        for analyzedFS in stateObservers {
            let activity = analyzedFS.featureSet.businessActivity
            let isHandlerStyle = activity.contains("StateTransition Handler")

            // CRITICAL: Capture values to avoid actor reentrancy deadlock
            let capturedActionRegistry = actionRegistry
            let capturedEventBus = eventBus
            let capturedGlobalSymbols = globalSymbols
            let capturedServices = services

            if isHandlerStyle {
                // New syntax: "StateTransition Handler<toState:approved>"
                // Parse <key:value> guard, e.g. toState:approved
                var guardKey: String? = nil
                var guardValue: String? = nil

                if let angleStart = activity.firstIndex(of: "<"),
                   let angleEnd = activity.firstIndex(of: ">") {
                    let guardExpr = String(activity[activity.index(after: angleStart)..<angleEnd])
                    let parts = guardExpr.split(separator: ":", maxSplits: 1).map(String.init)
                    if parts.count == 2 {
                        guardKey = parts[0].trimmingCharacters(in: .whitespaces)
                        guardValue = parts[1].trimmingCharacters(in: .whitespaces)
                    }
                }

                let capturedGuardKey = guardKey
                let capturedGuardValue = guardValue

                eventBus.subscribe(to: StateTransitionEvent.self) { event in
                    // Apply guard filter if specified
                    let shouldHandle: Bool
                    if let key = capturedGuardKey, let value = capturedGuardValue {
                        switch key {
                        case "toState":   shouldHandle = event.toState.lowercased() == value.lowercased()
                        case "fromState": shouldHandle = event.fromState.lowercased() == value.lowercased()
                        case "fieldName": shouldHandle = event.fieldName.lowercased() == value.lowercased()
                        case "objectName": shouldHandle = event.objectName.lowercased() == value.lowercased()
                        default:          shouldHandle = true
                        }
                    } else {
                        shouldHandle = true
                    }

                    if shouldHandle {
                        await ExecutionEngine.executeStateTransitionHandlerStatic(
                            analyzedFS,
                            baseContext: baseContext,
                            event: event,
                            actionRegistry: capturedActionRegistry,
                            eventBus: capturedEventBus,
                            globalSymbols: capturedGlobalSymbols,
                            services: capturedServices
                        )
                    }
                }
            } else {
                // Legacy syntax: "status StateObserver" or "status StateObserver<draft_to_placed>"
                var fieldName = ""
                var transitionFilter: String? = nil

                if let angleStart = activity.firstIndex(of: "<"),
                   let angleEnd = activity.firstIndex(of: ">") {
                    transitionFilter = String(activity[activity.index(after: angleStart)..<angleEnd])
                    let beforeAngle = String(activity[..<angleStart])
                    fieldName = beforeAngle
                        .replacingOccurrences(of: " StateObserver", with: "")
                        .replacingOccurrences(of: "StateObserver", with: "")
                        .trimmingCharacters(in: .whitespaces)
                        .lowercased()
                } else {
                    fieldName = activity
                        .replacingOccurrences(of: " StateObserver", with: "")
                        .replacingOccurrences(of: "StateObserver", with: "")
                        .trimmingCharacters(in: .whitespaces)
                        .lowercased()
                }

                let capturedFieldName = fieldName
                let capturedTransitionFilter = transitionFilter

                eventBus.subscribe(to: StateTransitionEvent.self) { event in
                    let fieldMatches = capturedFieldName.isEmpty || event.fieldName.lowercased() == capturedFieldName

                    let transitionMatches: Bool
                    if let filter = capturedTransitionFilter {
                        let expectedTransition = "\(event.fromState)_to_\(event.toState)"
                        transitionMatches = expectedTransition.lowercased() == filter.lowercased()
                    } else {
                        transitionMatches = true
                    }

                    if fieldMatches && transitionMatches {
                        await ExecutionEngine.executeStateObserverStatic(
                            analyzedFS,
                            baseContext: baseContext,
                            event: event,
                            actionRegistry: capturedActionRegistry,
                            eventBus: capturedEventBus,
                            globalSymbols: capturedGlobalSymbols,
                            services: capturedServices
                        )
                    }
                }
            }
        }
    }

    /// Register key press handlers for feature sets with "KeyPress Handler" business activity
    /// Supports optional key guard: "Select Item: KeyPress Handler<key:enter>"
    private func registerKeyPressHandlers(for program: AnalyzedProgram, baseContext: RuntimeContext) {
        let keyPressHandlers = program.featureSets.filter { analyzedFS in
            analyzedFS.featureSet.businessActivity.contains("KeyPress Handler")
        }

        for analyzedFS in keyPressHandlers {
            let activity = analyzedFS.featureSet.businessActivity

            // Parse optional key guard: <key:enter> from activity string
            var keyGuard: String? = nil
            if let angleStart = activity.firstIndex(of: "<"),
               let angleEnd = activity.firstIndex(of: ">") {
                let guardExpr = String(activity[activity.index(after: angleStart)..<angleEnd])
                let parts = guardExpr.split(separator: ":", maxSplits: 1).map(String.init)
                if parts.count == 2 && parts[0].trimmingCharacters(in: .whitespaces) == "key" {
                    keyGuard = parts[1].trimmingCharacters(in: .whitespaces)
                }
            }

            let capturedKeyGuard = keyGuard
            let capturedActionRegistry = actionRegistry
            let capturedEventBus = eventBus
            let capturedGlobalSymbols = globalSymbols
            let capturedServices = services

            eventBus.subscribe(to: KeyPressEvent.self) { event in
                // Apply key guard filter if specified
                if let keyFilter = capturedKeyGuard {
                    guard event.key.lowercased() == keyFilter.lowercased() else { return }
                }

                await ExecutionEngine.executeKeyPressHandlerStatic(
                    analyzedFS,
                    baseContext: baseContext,
                    event: event,
                    actionRegistry: capturedActionRegistry,
                    eventBus: capturedEventBus,
                    globalSymbols: capturedGlobalSymbols,
                    services: capturedServices
                )
            }
        }
    }

    /// Execute a KeyPress Handler feature set — binds event key as "event"
    private static func executeKeyPressHandlerStatic(
        _ analyzedFS: AnalyzedFeatureSet,
        baseContext: RuntimeContext,
        event: KeyPressEvent,
        actionRegistry: ActionRegistry,
        eventBus: EventBus,
        globalSymbols: GlobalSymbolStorage,
        services: ServiceRegistry
    ) async {
        await executeHandler(
            analyzedFS,
            baseContext: baseContext,
            event: event,
            actionRegistry: actionRegistry,
            eventBus: eventBus,
            globalSymbols: globalSymbols,
            services: services
        ) { context, event in
            let eventData: [String: any Sendable] = ["key": event.key]
            context.bind("event", value: eventData)
            context.bind("event:key", value: event.key)
        }
    }

    /// Execute a StateTransition Handler feature set — binds event data as "event" (consistent with other handlers)
    private static func executeStateTransitionHandlerStatic(
        _ analyzedFS: AnalyzedFeatureSet,
        baseContext: RuntimeContext,
        event: StateTransitionEvent,
        actionRegistry: ActionRegistry,
        eventBus: EventBus,
        globalSymbols: GlobalSymbolStorage,
        services: ServiceRegistry
    ) async {
        await executeHandler(
            analyzedFS,
            baseContext: baseContext,
            event: event,
            actionRegistry: actionRegistry,
            eventBus: eventBus,
            globalSymbols: globalSymbols,
            services: services
        ) { context, event in
            var eventData: [String: any Sendable] = [
                "fieldName": event.fieldName,
                "objectName": event.objectName,
                "fromState": event.fromState,
                "toState": event.toState
            ]
            if let entityId = event.entityId { eventData["entityId"] = entityId }
            if let entity = event.entity { eventData["entity"] = entity }

            context.bind("event", value: eventData)
            context.bind("event:fieldName", value: event.fieldName)
            context.bind("event:objectName", value: event.objectName)
            context.bind("event:fromState", value: event.fromState)
            context.bind("event:toState", value: event.toState)
            if let entityId = event.entityId { context.bind("event:entityId", value: entityId) }
            if let entity = event.entity { context.bind("event:entity", value: entity) }
        }
    }

    /// Execute a state observer feature set (static version to avoid actor deadlock)
    private static func executeStateObserverStatic(
        _ analyzedFS: AnalyzedFeatureSet,
        baseContext: RuntimeContext,
        event: StateTransitionEvent,
        actionRegistry: ActionRegistry,
        eventBus: EventBus,
        globalSymbols: GlobalSymbolStorage,
        services: ServiceRegistry
    ) async {
        await executeHandler(
            analyzedFS,
            baseContext: baseContext,
            event: event,
            actionRegistry: actionRegistry,
            eventBus: eventBus,
            globalSymbols: globalSymbols,
            services: services
        ) { context, event in
            // Bind transition data to context as "transition" with nested access
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
            context.bind("transition", value: transitionData)

            // Also bind transition keys directly for convenience
            context.bind("transition:fieldName", value: event.fieldName)
            context.bind("transition:objectName", value: event.objectName)
            context.bind("transition:fromState", value: event.fromState)
            context.bind("transition:toState", value: event.toState)
            if let entityId = event.entityId {
                context.bind("transition:entityId", value: entityId)
            }
            if let entity = event.entity {
                context.bind("transition:entity", value: entity)
            }
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

/// A single published symbol entry.
public struct PublishedSymbol: Sendable {
    public let value: any Sendable
    public let featureSet: String
    public let businessActivity: String
    /// Unique ID of the feature-set invocation that published this symbol.
    /// Used by `evict(executionId:)` to remove symbols when their execution ends.
    public let executionId: String
}

/// Thread-safe storage for published symbols with business activity enforcement.
/// Converted to actor for Swift 6.2 concurrency safety (Issue #2).
///
/// Symbols are scoped to their publishing execution. When `evict(executionId:)`
/// is called after a feature set completes, its symbols are removed unless a
/// newer invocation has overwritten them (ownership guard prevents stale eviction).
/// Application-lifecycle feature sets (Application-Start / Application-End) are
/// intentionally excluded from eviction so their symbols persist for the entire
/// process lifetime.
public actor GlobalSymbolStorage {
    private var symbols: [String: PublishedSymbol] = [:]

    /// Reverse index: executionId → symbol names it owns.
    /// Enables O(1) bulk eviction without scanning the entire symbol table.
    private var executionIndex: [String: Set<String>] = [:]

    public init() {}

    // MARK: - Write

    /// Store a published symbol with its business activity and execution owner.
    public func publish(
        name: String,
        value: any Sendable,
        fromFeatureSet: String,
        businessActivity: String,
        executionId: String
    ) {
        // If a previous entry exists under the same name, remove it from the
        // old execution's index to keep the index clean.
        if let existing = symbols[name], existing.executionId != executionId {
            executionIndex[existing.executionId]?.remove(name)
        }
        symbols[name] = PublishedSymbol(
            value: value,
            featureSet: fromFeatureSet,
            businessActivity: businessActivity,
            executionId: executionId
        )
        executionIndex[executionId, default: []].insert(name)
    }

    /// Remove all symbols published by a specific execution.
    ///
    /// The ownership guard ensures that a late-arriving eviction cannot remove
    /// a symbol that was overwritten by a newer invocation: the stored
    /// `executionId` is checked before deleting.
    public func evict(executionId: String) {
        guard let names = executionIndex.removeValue(forKey: executionId) else { return }
        for name in names {
            if symbols[name]?.executionId == executionId {
                symbols.removeValue(forKey: name)
            }
        }
    }

    // MARK: - Read

    /// Resolve a published symbol (validates business activity)
    /// - Parameters:
    ///   - name: The symbol name
    ///   - forBusinessActivity: The business activity of the requesting feature set
    /// - Returns: The value if found and accessible, nil otherwise
    public func resolve<T: Sendable>(_ name: String, forBusinessActivity: String) -> T? {
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
        return symbols[name]?.featureSet
    }

    /// Get the business activity that a symbol belongs to
    public func businessActivity(for name: String) -> String? {
        return symbols[name]?.businessActivity
    }

    /// Check if accessing a symbol would be denied due to business activity mismatch
    public func isAccessDenied(_ name: String, forBusinessActivity: String) -> Bool {
        guard let entry = symbols[name] else { return false }

        // Access is denied if both have non-empty business activities that don't match
        return !entry.businessActivity.isEmpty &&
               !forBusinessActivity.isEmpty &&
               entry.businessActivity != forBusinessActivity
    }

    /// Get all published symbols (for eager binding in feature sets)
    public func allSymbols() -> [String: PublishedSymbol] {
        return symbols
    }

    /// Total number of currently stored symbols. Useful for memory monitoring.
    public var count: Int { symbols.count }
}

// MARK: - Service Registry

/// Registry for dependency injection.
/// Converted to actor for Swift 6.2 concurrency safety (Issue #2).
public actor ServiceRegistry {
    private var services: [ObjectIdentifier: any Sendable] = [:]

    public init() {}

    /// Register a service
    public func register<S: Sendable>(_ service: S) {
        services[ObjectIdentifier(S.self)] = service
    }

    /// Resolve a service
    public func resolve<S>(_ type: S.Type) -> S? {
        services[ObjectIdentifier(type)] as? S
    }

    /// Register all services in a context
    public func registerAll(in context: ExecutionContext) {
        for (typeId, service) in services {
            // Preserve type ID to avoid type erasure
            context.registerWithTypeId(typeId, service: service)
        }
    }
}
