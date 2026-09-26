// ============================================================
// Runtime.swift
// ARO Runtime - Program lifecycle
// ============================================================
//
// The lifecycle around a run: start the program through the
// ExecutionEngine, keep the process alive while events are still arriving,
// and run Application-End on the way out. Statement execution itself is
// FeatureSetExecutor.swift; the signal plumbing that asks for shutdown is
// SignalHandling.swift.

import Foundation
import AROParser

// MARK: - Runtime

/// Main runtime that manages program execution lifecycle
///
/// Sendable-safety: every mutable stored property (`_isRunning`,
/// `_currentProgram`, `_shutdownError`, `_enteredWaitState`,
/// `_compiledHandlers`) is read/written exclusively through the `withLock(_:)`
/// helper backed by `lock` (an `NSLock`) — see the computed accessors and
/// `registerCompiledHandler` below; none is touched outside that lock. The
/// immutable dependencies (`engine`, `eventBus`, `lock`) are `let`, and
/// `globalSymbols` delegates to the `ExecutionEngine` actor. The class is
/// `@unchecked Sendable` because that lock-based discipline is invisible to the
/// compiler.
public final class Runtime: @unchecked Sendable {
    // MARK: - Properties

    private let engine: ExecutionEngine
    /// Event bus for event emission (public for C bridge access in compiled binaries)
    public let eventBus: EventBus
    /// Global symbols for sharing between feature sets (public for HTTP handlers)
    public var globalSymbols: GlobalSymbolStorage {
        get async {
            return await engine.sharedGlobalSymbols
        }
    }
    private var _isRunning: Bool = false
    private var _currentProgram: AnalyzedProgram?
    private var _shutdownError: Error?
    private var _enteredWaitState: Bool = false
    private let lock = NSLock()

    /// Registry for compiled event handlers: eventType -> [(handlerName, callback)]
    private var _compiledHandlers: [String: [(String, @Sendable (DomainEvent) async -> Void)]] = [:]

    // MARK: - Thread-safe helpers

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Set once Application-End has run for the current run (GitLab #628).
    private nonisolated(unsafe) var _didRunApplicationEnd = false

    private var isRunning: Bool {
        get { withLock { _isRunning } }
        set { withLock { _isRunning = newValue } }
    }

    /// Check if the application entered wait state (Keepalive action)
    public var enteredWaitState: Bool {
        get { withLock { _enteredWaitState } }
        set { withLock { _enteredWaitState = newValue } }
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
            _didRunApplicationEnd = false
            return true
        }
    }

    /// Whether this call is the one that gets to run Application-End.
    ///
    /// Answers `true` exactly once per run (GitLab #628).
    private func claimApplicationEnd() -> Bool {
        withLock {
            if _didRunApplicationEnd { return false }
            _didRunApplicationEnd = true
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

        // Subscribe to DomainEvent once to dispatch to compiled handlers
        eventBus.subscribe(to: DomainEvent.self) { [weak self] event in
            guard let self = self else { return }

            // Get handlers for this event type
            let handlers = self.withLock {
                self._compiledHandlers[event.domainEventType] ?? []
            }
            // Execute all matching handlers concurrently
            await withTaskGroup(of: Void.self) { group in
                for (_, callback) in handlers {
                    group.addTask {
                        await callback(event)
                    }
                }
            }
        }

        // Start metrics collection
        MetricsCollector.shared.start(eventBus: eventBus)
    }

    // MARK: - Service Registration

    /// Register a service for dependency injection
    public func register<S: Sendable>(service: S) async {
        await engine.register(service: service)
    }

    // MARK: - Compiled Handler Registration

    /// Register a compiled event handler
    /// - Parameters:
    ///   - eventType: The event type to listen for
    ///   - handlerName: Name of the handler feature set
    ///   - callback: The compiled handler function to call
    public func registerCompiledHandler(
        eventType: String,
        handlerName: String,
        callback: @escaping @Sendable (DomainEvent) async -> Void
    ) {
        withLock {
            if _compiledHandlers[eventType] == nil {
                _compiledHandlers[eventType] = []
            }
            _compiledHandlers[eventType]?.append((handlerName, callback))
        }
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
        try await run(program, entryPoint: entryPoint, runApplicationEnd: true)
    }

    /// - Parameter runApplicationEnd: whether this call owns the Application-End
    ///   handler. `runAndKeepAlive` passes `false` and fires it itself once the
    ///   keep-alive loop has finished (GitLab #628): it used to let `run` fire
    ///   it *and* fire it again afterwards, so every handler body ran twice —
    ///   a second `Log`, a second store flush, a second outbound call, and a
    ///   `Stop the <http-server>` against an already-stopped server. For a
    ///   program that does not `Keepalive`, the first of those two also ran
    ///   before the idle drain, so shutdown work happened while events were
    ///   still in flight.
    private func run(
        _ program: AnalyzedProgram,
        entryPoint: String,
        runApplicationEnd: Bool
    ) async throws -> Response {
        guard tryStartRunning() else {
            throw ActionError.runtimeError("Runtime is already running")
        }

        defer {
            isRunning = false
        }

        // Store the program for Application-End execution
        currentProgram = program

        do {
            let response = try await engine.execute(program, entryPoint: entryPoint)
            // Track if application entered wait state (for response printing suppression)
            enteredWaitState = await engine.enteredWaitState
            if runApplicationEnd {
                await executeApplicationEnd(isError: false)
            }
            return response
        } catch {
            shutdownError = error
            if runApplicationEnd {
                await executeApplicationEnd(isError: true)
            }
            throw error
        }
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
            _ = try await run(program, entryPoint: entryPoint, runApplicationEnd: false)
        } catch {
            // Store error for Application-End: Error handler
            shutdownError = error
            await executeApplicationEnd(isError: true)
            throw error
        }

        // If shutdown was already signaled during run() (e.g., Keepalive received SIGINT),
        // skip the keep-alive loop and proceed directly to Application-End.
        if !ShutdownCoordinator.shared.isShuttingDownNow {
            // Re-set isRunning since run() resets it in defer block
            isRunning = true

            // Keep running until stopped or all event processing is complete
            // For non-server applications (crawlers, batch processors), exit when idle
            var consecutiveIdleChecks = 0
            let idleThreshold = 10 // 10 consecutive checks = 1 second of idle
            while isRunning {
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms

                // Check if event bus is idle (no in-flight handlers)
                let pendingCount = await eventBus.getPendingHandlerCount()
                if pendingCount == 0 {
                    consecutiveIdleChecks += 1
                    if consecutiveIdleChecks >= idleThreshold {
                        // No events processed for 1 second - application is idle
                        // Stop the loop (equivalent to graceful shutdown)
                        break
                    }
                } else {
                    consecutiveIdleChecks = 0
                }
            }
        }

        // Execute Application-End handler on graceful shutdown
        await executeApplicationEnd(isError: shutdownError != nil)
    }

    /// Execute Application-End handler if defined
    /// - Parameter isError: Whether shutdown is due to an error
    private func executeApplicationEnd(isError: Bool) async {
        // Belt and braces for GitLab #628. The sequencing above is the actual
        // fix; this makes a second call from any future path a no-op rather
        // than a doubled side effect, which is the failure mode that went
        // unnoticed because nothing counted the executions.
        guard claimApplicationEnd() else { return }
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

        // Inject registered services (e.g. TerminalService) so actions like
        // "Show the <cursor>" work correctly in Application-End handlers
        await engine.registerServicesInContext(context)

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
        // The engine's own storage and registry, not fresh ones (GitLab #629).
        //
        // A new `GlobalSymbolStorage()` meant `resolveDependencies` ran against
        // an empty store, so `Publish as <config> …` in Application-Start was
        // invisible to Application-End and the documented "graceful shutdown
        // reads startup state" pattern failed with `undefinedVariable`.
        // `ActionRegistry.shared` likewise bypassed whatever registry this
        // `Runtime` was constructed with, so a test's or middleware's registry
        // did not apply during shutdown — the one moment a shutdown hook most
        // wants to be observed.
        let executor = FeatureSetExecutor(
            actionRegistry: await engine.sharedActionRegistry,
            eventBus: eventBus,
            globalSymbols: await engine.sharedGlobalSymbols
        )

        do {
            _ = try await executor.execute(exitHandler, context: context)
        } catch {
            // Log but don't propagate errors from exit handler
            print("[Runtime] Application-End handler failed: \(error)")
        }
    }

    /// Wait for all in-flight event handlers to complete
    /// - Parameter timeout: Maximum time to wait in seconds (default: 10.0)
    /// - Returns: true if all handlers completed, false if timeout occurred
    public func awaitPendingEvents(timeout: TimeInterval = 10.0) async -> Bool {
        return await eventBus.awaitPendingEvents(timeout: timeout)
    }

    /// True iff the event bus has no in-flight handlers and no pending
    /// fire-and-forget publishes. Used by shutdown loops to confirm the
    /// runtime really has drained between awaitPendingEvents timeouts.
    public func isQuiescent() async -> Bool {
        return await eventBus.isQuiescent()
    }

    /// Pass-through to the event bus's in-flight handler count.
    public func getPendingHandlerCount() async -> Int {
        return await eventBus.getPendingHandlerCount()
    }

    /// Stop the runtime
    public func stop() {
        eventBus.publish(ApplicationStoppingEvent(reason: "stop requested"))

        // Signal any waiting actions via the global coordinator
        ShutdownCoordinator.shared.signalShutdown()

        isRunning = false
    }
}
