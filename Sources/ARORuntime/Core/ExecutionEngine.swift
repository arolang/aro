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

    /// The dependency injection container
    private let container: RuntimeContainer

    /// The action registry for looking up action implementations
    private let actionRegistry: ActionRegistry

    /// The event bus for event-driven communication.
    /// Internal rather than private because the handler subscriptions live in
    /// `ExecutionEngine+EventHandlers.swift`.
    let eventBus: EventBus

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

    /// Visited-URL store for CrawlPage deduplication (issue #154).
    /// Uses a bounded FIFO-evicting set so long-running crawlers cannot exhaust memory.
    /// Read by the domain-handler subscription in `ExecutionEngine+EventHandlers.swift`.
    let visitedUrls = VisitedURLStore(maxSize: RuntimeDefaults.visitedURLStoreMaxSize)

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
        eventBus: EventBus = .shared,
        container: RuntimeContainer? = nil
    ) {
        let resolvedContainer = container ?? .default
        self.container = resolvedContainer
        self.actionRegistry = resolvedContainer.actionRegistry
        self.eventBus = resolvedContainer.eventBus
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

        // ARO-0081: Register user-defined actions before the entry point runs.
        // This makes `Application.<Name>` callable from anywhere in the program,
        // including from inside Application-Start itself. The host is kept
        // alive for the duration of the run via the engine's strong reference.
        let userActionHost = UserDefinedActionHost(
            analyzedProgram: program,
            globalSymbols: globalSymbols,
            actionRegistry: actionRegistry,
            eventBus: eventBus
        )
        await userActionHost.register()

        // Emit application start event
        eventBus.publish(ApplicationStartedEvent(applicationName: entryPoint))

        // Create root context with business activity from entry feature set
        let context = RuntimeContext(
            featureSetName: entryPoint,
            businessActivity: entryFeatureSet.featureSet.businessActivity,
            eventBus: eventBus,
            container: container
        )

        // Register services in context
        await services.registerAll(in: context)

        // Set up schema registry for typed event extraction (ARO-0046)
        // If an OpenAPI spec is loaded, create a schema registry for schema-based validation
        if let specService = context.service(OpenAPISpecService.self) {
            let schemaRegistry = OpenAPISchemaRegistry(spec: specService.spec)
            context.setSchemaRegistry(schemaRegistry)
        }

        // Wire up every business-activity pattern that makes a feature set an
        // event handler (ExecutionEngine+EventHandlers.swift).
        registerEventHandlers(for: program, baseContext: context)

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
            // This ensures events emitted during Application-Start finish executing.
            //
            // Loops with stall detection so long-running cascades (e.g. a
            // crawler that keeps emitting from observer handlers) aren't cut
            // off after the per-call timeout. Uses `isQuiescent` rather than
            // the bare handler count so we don't exit in the brief lull
            // between fan-out waves while fire-and-forget publishes are
            // queued but haven't yet incremented in-flight tracking.
            // Bails only when the pending count stops decreasing across two
            // windows — that's the signal that work has stalled.
            var previousPending = -1
            while true {
                let completed = await eventBus.awaitPendingEvents(timeout: AROEventHandlerDefaultTimeout)
                if completed { break }
                if await eventBus.isQuiescent() { break }
                let pending = await eventBus.getPendingHandlerCount()
                if pending == previousPending {
                    print("[WARNING] \(pending) event handler(s) stalled — no progress within \(AROEventHandlerDefaultTimeout)s")
                    break
                }
                previousPending = pending
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

    // MARK: - Handler Wiring

    /// The collaborators an event-handler subscription captures.
    ///
    /// Read once per `register*Handlers` method and captured by the
    /// subscription closures, which must never hop back onto this actor: the
    /// actor can be blocked waiting for the very handlers it registered.
    /// The registration methods themselves live in
    /// `ExecutionEngine+EventHandlers.swift`.
    var handlerDependencies: HandlerDependencies {
        HandlerDependencies(
            actionRegistry: actionRegistry,
            eventBus: eventBus,
            globalSymbols: globalSymbols,
            services: services
        )
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
