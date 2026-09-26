// ============================================================
// ExecutionEngine+EventHandlers.swift
// ARO Runtime - Wiring feature sets to the events that trigger them
// ============================================================

import Foundation
import AROParser

/// Every business-activity pattern that turns a feature set into an event
/// handler is subscribed here: sockets, websockets, domain events, plugin
/// domain events, notifications, file events, repository observers and
/// evictions, watches, state transitions and key presses.
extension ExecutionEngine {
    /// Subscribe every event handler the program declares.
    ///
    /// Called once, from `execute`, before the entry point runs: a feature set
    /// is never called directly, so this is what makes anything but
    /// `Application-Start` reachable.
    func registerEventHandlers(for program: AnalyzedProgram, baseContext: RuntimeContext) {
        // Socket events work on Windows via WindowsSocketServer (FlyingSocks)
        registerSocketEventHandlers(for: program, baseContext: baseContext)
        registerWebSocketEventHandlers(for: program, baseContext: baseContext)

        // Domain events (e.g., "UserCreated Handler", "OrderPlaced Handler"),
        // including the ones declared in .aro files shipped by plugins
        registerDomainEventHandlers(for: program, baseContext: baseContext)
        registerPluginEventHandlers(baseContext: baseContext)

        // "NotificationSent Handler"
        registerNotificationEventHandlers(for: program, baseContext: baseContext)

        // "Handle File Modified: File Event Handler"
        registerFileEventHandlers(for: program, baseContext: baseContext)

        // "user-repository Observer" and "cache-repository Evicted Handler"
        registerRepositoryObservers(for: program, baseContext: baseContext)
        registerEvictionHandlers(for: program, baseContext: baseContext)

        // "Dashboard Watch: TasksUpdated Handler" / "… : task-repository Observer"
        registerWatchHandlers(for: program, baseContext: baseContext)

        // "Audit Changes: status StateObserver"
        registerStateObservers(for: program, baseContext: baseContext)

        // "Navigate Menu: KeyPress Handler" / "Select Item: KeyPress Handler<key:enter>"
        registerKeyPressHandlers(for: program, baseContext: baseContext)
    }

    /// Register socket event handlers for feature sets with "Socket Event Handler" business activity
    /// Socket events work on all platforms via platform-specific implementations
    private func registerSocketEventHandlers(for program: AnalyzedProgram, baseContext: RuntimeContext) {
        let socketHandlers = program.socketHandlers


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
                        baseContext: baseContext,
                        connectionId: event.connectionId,
                        transport: "socket",
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
                        baseContext: baseContext,
                        connectionId: event.connectionId,
                        transport: "socket",
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
                        baseContext: baseContext,
                        connectionId: event.connectionId,
                        transport: "socket",
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

    /// Run a handler on this actor: child context, handler-specific binding,
    /// services, execute, report a failure as a recoverable error event.
    ///
    /// `prepare` binds whatever the event carries and answers whether the
    /// handler should run at all — that is where a feature-set-level `when`
    /// condition is evaluated for the handler kinds that support one.
    ///
    /// Unlike `HandlerDependencies.run`, this stays actor-isolated, because
    /// the socket, websocket, file and notification subscriptions hop back
    /// onto the engine (`[weak self]`) rather than capturing their
    /// dependencies.
    private func executeInChildContext(
        _ analyzedFS: AnalyzedFeatureSet,
        baseContext: RuntimeContext,
        caller: CallerIdentity? = nil,
        prepare: (RuntimeContext) async -> Bool
    ) async {
        let deps = handlerDependencies
        let handlerContext = deps.makeContext(for: analyzedFS, parent: baseContext, caller: caller)

        guard await prepare(handlerContext) else { return }

        // Copy services from base context
        await deps.services.registerAll(in: handlerContext)

        await deps.runReportingErrors(analyzedFS, context: handlerContext)
    }

    /// Execute a socket or websocket event handler feature set.
    /// Socket events bind their payload under its own names (`connection`,
    /// `packet`, `event`) rather than under an `event` dictionary.
    private func executeSocketHandler(
        _ analyzedFS: AnalyzedFeatureSet,
        baseContext: RuntimeContext,
        connectionId: String? = nil,
        transport: String = "socket",
        eventData: [String: any Sendable]
    ) async {
        // ARO-0094 §4.2/§4.3: the handler runs as whoever the connection is.
        // A WebSocket that presented a valid cookie at upgrade, or a socket
        // promoted by `Attach`, is a session; anything else is a bare
        // connection, which identifies nobody and must not reach a
        // session-scoped repository.
        var caller: CallerIdentity?
        if let connectionId {
            caller = await SessionService.shared.caller(forConnection: connectionId)
        }

        await executeInChildContext(analyzedFS, baseContext: baseContext, caller: caller) { handlerContext in
            if let connectionId {
                // So `Attach … to the <connection>` knows which connection it
                // is promoting, rather than taking an id as an argument.
                handlerContext.register(ConnectionIdentity(id: connectionId, transport: transport))
            }
            for (key, value) in eventData {
                handlerContext.bind(key, value: value)
            }
            return true
        }
    }

    /// Register WebSocket event handlers for feature sets with "WebSocket Event Handler" business activity
    private func registerWebSocketEventHandlers(for program: AnalyzedProgram, baseContext: RuntimeContext) {
        let wsHandlers = program.webSocketHandlers

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
                        baseContext: baseContext,
                        connectionId: event.connectionId,
                        transport: "websocket",
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
                        baseContext: baseContext,
                        connectionId: event.connectionId,
                        transport: "websocket",
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
                        baseContext: baseContext,
                        connectionId: event.connectionId,
                        transport: "websocket",
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
    /// and a dedupe declaration: "CrawlPage Handler<dedupe:url>" (ARO-0007 §3.6)
    private func registerDomainEventHandlers(for program: AnalyzedProgram, baseContext: RuntimeContext) {
        let domainHandlers = program.domainHandlers

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
            let deps = handlerDependencies

            // A handler that declares `<dedupe:field>` sees each distinct value
            // of that field once (ARO-0007 §3.6). The store belongs to this
            // handler, and is bounded with FIFO eviction so a crawl that never
            // ends cannot exhaust memory (GitLab #154).
            let seen = DedupeGuard.field(in: activity).map { field in
                (field: field, store: VisitedURLStore(maxSize: RuntimeDefaults.visitedURLStoreMaxSize))
            }

            eventBus.subscribe(to: DomainEvent.self) { event in
                // Only handle events that match this handler's event type
                guard event.domainEventType == eventType else { return }

                if let seen,
                   let identity = DedupeGuard.identity(ofField: seen.field, in: event.payload) {
                    guard seen.store.tryInsert(identity) else { return }
                }

                // Apply state guards if present
                if !guardSet.isEmpty {
                    guard guardSet.allMatch(payload: event.payload) else { return }
                }

                // Execute handler WITHOUT actor isolation to avoid deadlock
                await deps.runDomainEventHandler(
                    analyzedFS,
                    baseContext: baseContext,
                    event: event
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
            let deps = handlerDependencies

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

                await deps.runDomainEventHandler(
                    analyzedFS,
                    baseContext: baseContext,
                    event: event
                )
            }
        }
    }

    /// Register notification event handlers for feature sets with "NotificationSent Handler" business activity
    private func registerNotificationEventHandlers(for program: AnalyzedProgram, baseContext: RuntimeContext) {
        let notificationHandlers = program.notificationHandlers

        for analyzedFS in notificationHandlers {
            // Subscribe to NotificationSentEvent
            eventBus.subscribe(to: NotificationSentEvent.self) { [weak self] event in
                guard let self = self else { return }
                await self.executeNotificationEventHandler(
                    analyzedFS,
                    baseContext: baseContext,
                    event: event
                )
            }
        }
    }

    /// Execute a notification event handler feature set
    private func executeNotificationEventHandler(
        _ analyzedFS: AnalyzedFeatureSet,
        baseContext: RuntimeContext,
        event: NotificationSentEvent
    ) async {
        await executeInChildContext(analyzedFS, baseContext: baseContext) { handlerContext in
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
                    guard passes else { return false }
                } catch {
                    return false // Skip handler silently if condition evaluation fails
                }
            }

            return true
        }
    }

    /// Register file event handlers for feature sets with "File Event Handler" business activity
    private func registerFileEventHandlers(for program: AnalyzedProgram, baseContext: RuntimeContext) {
        let fileHandlers = program.fileHandlers

        for analyzedFS in fileHandlers {
            let lowercaseName = analyzedFS.featureSet.name.lowercased()

            // Which of the three the name asks for. A name that asks for none
            // gets all three.
            //
            // There used to be no `else`: a handler whose name contained
            // neither "created", "modified" nor "deleted" matched no branch and
            // subscribed to *nothing*. It compiled, `aro check` reported no
            // problem, and it simply never ran — with no output at any log
            // level to say so (GitLab #570, #571). The issue's own repro,
            // `(File Changed: File Event Handler)`, is the natural thing to
            // write and was dead code.
            //
            // Subscribing to all three is what such a name asks for, and it
            // cannot break a working program: the alternative was firing never.
            let wantsCreated = lowercaseName.contains("created")
            let wantsModified = lowercaseName.contains("modified")
            let wantsDeleted = lowercaseName.contains("deleted")
            let named = wantsCreated || wantsModified || wantsDeleted

            if wantsCreated || !named {
                eventBus.subscribe(to: FileCreatedEvent.self) { [weak self] event in
                    guard let self = self else { return }
                    await self.executeFileEventHandler(
                        analyzedFS,
                        baseContext: baseContext,
                        eventData: ["path": event.path, "kind": "created"]
                    )
                }
            }

            if wantsModified || !named {
                eventBus.subscribe(to: FileModifiedEvent.self) { [weak self] event in
                    guard let self = self else { return }
                    // Skip temp files (hidden files starting with .)
                    let filename = (event.path as NSString).lastPathComponent
                    guard !filename.hasPrefix(".") else {
                        return
                    }
                    await self.executeFileEventHandler(
                        analyzedFS,
                        baseContext: baseContext,
                        eventData: ["path": event.path, "kind": "modified"]
                    )
                }
            }

            if wantsDeleted || !named {
                eventBus.subscribe(to: FileDeletedEvent.self) { [weak self] event in
                    guard let self = self else { return }
                    await self.executeFileEventHandler(
                        analyzedFS,
                        baseContext: baseContext,
                        eventData: ["path": event.path, "kind": "deleted"]
                    )
                }
            }
        }
    }

    /// Execute a file event handler feature set
    private func executeFileEventHandler(
        _ analyzedFS: AnalyzedFeatureSet,
        baseContext: RuntimeContext,
        eventData: [String: any Sendable]
    ) async {
        await executeInChildContext(analyzedFS, baseContext: baseContext) { handlerContext in
            // Bind event data to context as "event" with nested access
            // e.g., <Extract> the <path> from the <event: path>
            handlerContext.bind("event", value: eventData)

            // Also bind event keys directly for convenience
            for (key, value) in eventData {
                handlerContext.bind("event:\(key)", value: value)
            }
            return true
        }
    }

    /// Register repository observers for feature sets with "Observer" business activity pattern
    /// For example: "user-repository Observer", "order-repository Observer"
    /// Supports state guards: "user-repository Observer<status:active>"
    private func registerRepositoryObservers(for program: AnalyzedProgram, baseContext: RuntimeContext) {
        let observers = program.repositoryObservers

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
            let deps = handlerDependencies

            // Capture the feature-set-level when condition for evaluation
            let whenCondition = analyzedFS.featureSet.whenCondition

            eventBus.subscribe(to: RepositoryChangedEvent.self) { event in
                // Only handle events that match this observer's repository
                guard event.repositoryName == repositoryName else { return }

                // Evaluate feature-set-level when condition (e.g., when <message-repository: count> > 40)
                if let condition = whenCondition {
                    // Create temporary context for condition evaluation
                    let evalContext = deps.makeContext(for: analyzedFS, parent: baseContext)

                    // Bind event fields so conditions like `where <event: changeType> == "created"`
                    // can resolve event data during evaluation
                    let changeTypeValue = event.changeType.rawValue
                    let eventDict: [String: any Sendable] = [
                        "changeType": changeTypeValue,
                        "repositoryName": event.repositoryName
                    ]
                    evalContext.bind("event", value: eventDict)
                    evalContext.bind("event:changeType", value: changeTypeValue)
                    evalContext.bind("event:repositoryName", value: event.repositoryName)
                    evalContext.bind("changeType", value: changeTypeValue)

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
                await deps.runRepositoryObserver(
                    analyzedFS,
                    baseContext: baseContext,
                    event: event
                )
            }
        }
    }

    /// Register eviction handlers for feature sets with "Evicted Handler" business activity pattern.
    /// For example: "cache-repository Evicted Handler"
    private func registerEvictionHandlers(for program: AnalyzedProgram, baseContext: RuntimeContext) {
        let handlers = program.evictionHandlers

        for analyzedFS in handlers {
            let activity = analyzedFS.featureSet.businessActivity
            guard let range = activity.range(of: " Evicted Handler") else { continue }
            let repositoryName = String(activity[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)

            let deps = handlerDependencies

            eventBus.subscribe(to: RepositoryEvictedEvent.self) { event in
                guard event.repositoryName == repositoryName else { return }

                let context = deps.makeContext(for: analyzedFS, parent: baseContext)

                // Bind event payload so Extract works
                let payload: [String: any Sendable] = [
                    "evictedItem": event.evictedItem,
                    "repositoryName": event.repositoryName,
                    "reason": event.reason,
                    "timestamp": event.timestamp.timeIntervalSince1970
                ]
                context.bind("event", value: payload)

                let executor = deps.makeExecutor()
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
        let watchHandlers = program.watchHandlers

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
                let deps = handlerDependencies

                eventBus.subscribe(to: DomainEvent.self) { event in
                    // Only handle events that match this watch handler's event type
                    guard event.domainEventType == eventType else { return }

                    await deps.run(
                        analyzedFS,
                        baseContext: baseContext,
                        event: event
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
                let deps = handlerDependencies

                eventBus.subscribe(to: RepositoryChangedEvent.self) { event in
                    // Only handle events that match this watch handler's repository
                    guard event.repositoryName == repositoryName else { return }

                    await deps.run(
                        analyzedFS,
                        baseContext: baseContext,
                        event: event
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
        let stateObservers = program.stateObservers

        for analyzedFS in stateObservers {
            let activity = analyzedFS.featureSet.businessActivity
            let isHandlerStyle = activity.contains("StateTransition Handler")

            // CRITICAL: Capture values to avoid actor reentrancy deadlock
            let deps = handlerDependencies

            if isHandlerStyle {
                // New syntax: "StateTransition Handler<toState:approved>"
                // Parse <key:value> guard, e.g. toState:approved
                let parsedGuard = ActivityGuard.keyValue(of: activity)
                let capturedGuardKey = parsedGuard?.key
                let capturedGuardValue = parsedGuard?.value

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
                        await deps.runStateTransitionHandler(
                            analyzedFS,
                            baseContext: baseContext,
                            event: event
                        )
                    }
                }
            } else {
                // Legacy syntax: "status StateObserver" or "status StateObserver<draft_to_placed>"
                // The bracket holds a whole transition, not a field:value guard,
                // so this one is not a StateGuardSet.
                let (beforeAngle, transitionFilter) = ActivityGuard.split(activity)
                let fieldName = beforeAngle
                    .replacingOccurrences(of: " StateObserver", with: "")
                    .replacingOccurrences(of: "StateObserver", with: "")
                    .trimmingCharacters(in: .whitespaces)
                    .lowercased()

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
                        await deps.runStateObserver(
                            analyzedFS,
                            baseContext: baseContext,
                            event: event
                        )
                    }
                }
            }
        }
    }

    /// Register key press handlers for feature sets with "KeyPress Handler" business activity
    /// Supports optional key guard: "Select Item: KeyPress Handler<key:enter>"
    private func registerKeyPressHandlers(for program: AnalyzedProgram, baseContext: RuntimeContext) {
        let keyPressHandlers = program.keyPressHandlers

        for analyzedFS in keyPressHandlers {
            let activity = analyzedFS.featureSet.businessActivity

            // Parse optional key guard: <key:enter> from activity string
            let parsedGuard = ActivityGuard.keyValue(of: activity)
            let capturedKeyGuard = parsedGuard?.key == "key" ? parsedGuard?.value : nil
            let deps = handlerDependencies

            eventBus.subscribe(to: KeyPressEvent.self) { event in
                // Apply key guard filter if specified
                if let keyFilter = capturedKeyGuard {
                    guard event.key.lowercased() == keyFilter.lowercased() else { return }
                }

                await deps.runKeyPressHandler(
                    analyzedFS,
                    baseContext: baseContext,
                    event: event
                )
            }
        }
    }

}


// MARK: - Per-Event Bindings

/// What each kind of event puts into the handler's context before it runs.
/// The surrounding plumbing — child context, services, `when` guard, error
/// reporting — is `HandlerDependencies.run`; these say only what a
/// `UserCreated Handler` or a `task-repository Observer` gets to read.
private extension HandlerDependencies {
    /// Execute a domain event handler feature set (static version to avoid actor deadlock)
    func runDomainEventHandler(
        _ analyzedFS: AnalyzedFeatureSet,
        baseContext: RuntimeContext,
        event: DomainEvent,
    ) async {
        await run(
            analyzedFS,
            baseContext: baseContext,
            event: event,
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
    func runRepositoryObserver(
        _ analyzedFS: AnalyzedFeatureSet,
        baseContext: RuntimeContext,
        event: RepositoryChangedEvent,
    ) async {
        await run(
            analyzedFS,
            baseContext: baseContext,
            event: event,
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

    /// Execute a KeyPress Handler feature set — binds event key as "event"
    func runKeyPressHandler(
        _ analyzedFS: AnalyzedFeatureSet,
        baseContext: RuntimeContext,
        event: KeyPressEvent,
    ) async {
        await run(
            analyzedFS,
            baseContext: baseContext,
            event: event,
        ) { context, event in
            let eventData: [String: any Sendable] = ["key": event.key]
            context.bind("event", value: eventData)
            context.bind("event:key", value: event.key)
            // Also bind plain "key" so `where <key> = "down"` works
            // (consistent with binary mode which binds all payload keys)
            context.bind("key", value: event.key)
        }
    }

    /// Execute a StateTransition Handler feature set — binds event data as "event" (consistent with other handlers)
    func runStateTransitionHandler(
        _ analyzedFS: AnalyzedFeatureSet,
        baseContext: RuntimeContext,
        event: StateTransitionEvent,
    ) async {
        await run(
            analyzedFS,
            baseContext: baseContext,
            event: event,
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
    func runStateObserver(
        _ analyzedFS: AnalyzedFeatureSet,
        baseContext: RuntimeContext,
        event: StateTransitionEvent,
    ) async {
        await run(
            analyzedFS,
            baseContext: baseContext,
            event: event,
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
}
