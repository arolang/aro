// ============================================================
// AROAsyncRuntime.swift
// ARORuntime - Async Event Loop for Compiled Binaries
// ============================================================
//
// This module provides the async event loop that enables compiled ARO
// binaries to handle concurrent requests properly, rather than using
// blocking semaphores.
//
// Architecture:
// - Compiled main() calls aro_async_run() after Application-Start
// - The event loop processes HTTP requests, file events, etc. concurrently
// - Feature sets are spawned as async tasks
// - Signal handling enables graceful shutdown

import Foundation

#if !os(Windows)
import NIO
import NIOHTTP1
#endif

// MARK: - Async Runtime

/// The async runtime manages the event loop for compiled ARO binaries
///
/// This enables compiled binaries to handle concurrent requests without
/// blocking threads via semaphores. Instead:
/// - HTTP requests spawn async feature set executions
/// - File events trigger async handlers
/// - Socket events are processed asynchronously
/// - The event loop runs until shutdown signal
public final class AROAsyncRuntime: @unchecked Sendable {
    /// Shared instance for C bridge access
    public static let shared = AROAsyncRuntime()

    #if !os(Windows)
    /// NIO event loop group for async I/O - lazily initialized
    private var _eventLoopGroup: MultiThreadedEventLoopGroup?
    private let eventLoopLock = NSLock()

    private var eventLoopGroup: MultiThreadedEventLoopGroup {
        eventLoopLock.lock()
        defer { eventLoopLock.unlock() }
        if let group = _eventLoopGroup { return group }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        _eventLoopGroup = group
        return group
    }
    #endif

    /// Active task group for feature set executions
    private var activeTasks: [UUID: Task<Void, Never>] = [:]
    private let taskLock = NSLock()

    /// Shutdown flag
    private var isShuttingDown = false
    private let shutdownLock = NSLock()

    /// Runtime context for the main execution
    public var mainContext: RuntimeContext?

    /// Feature set handlers registered for HTTP routes
    public var httpHandlers: [String: (RuntimeContext) async throws -> Response] = [:]
    private let handlerLock = NSLock()

    private init() {
        // Event loop creation deferred to lazy initialization
    }

    // MARK: - Event Loop

    /// Run the async event loop until shutdown
    ///
    /// This method blocks the calling thread while processing events
    /// asynchronously. It returns when a shutdown signal is received.
    public func runEventLoop() {
        setupSignalHandlers()

        // Run the event loop
        let semaphore = DispatchSemaphore(value: 0)

        Task {
            await self.eventLoopMain()
            semaphore.signal()
        }

        semaphore.wait()
    }

    /// Main async event loop
    private func eventLoopMain() async {
        // Keep running until shutdown is requested
        while !isShuttingDownNow {
            // Process any pending work
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms

            // Check for shutdown
            if isShuttingDownNow {
                break
            }
        }

        // Cleanup
        await shutdown()
    }

    // MARK: - Feature Set Spawning

    /// Spawn a feature set for async execution
    /// - Parameters:
    ///   - name: The feature set name (operationId)
    ///   - context: The execution context
    /// - Returns: The response from the feature set
    public func spawnFeatureSet(
        _ name: String,
        context: RuntimeContext
    ) async throws -> Response {
        // Look up the handler (sync operation, use wrapper)
        let handler = getHandler(name)

        guard let handler = handler else {
            return Response(status: "NotFound", reason: "Feature set '\(name)' not found")
        }

        // Execute the handler
        return try await handler(context)
    }

    /// Get a handler thread-safely
    private func getHandler(_ name: String) -> ((RuntimeContext) async throws -> Response)? {
        handlerLock.lock()
        defer { handlerLock.unlock() }
        return httpHandlers[name]
    }

    /// Register a feature set handler
    /// - Parameters:
    ///   - name: The feature set name (operationId)
    ///   - handler: The async handler function
    public func registerHandler(
        _ name: String,
        handler: @escaping (RuntimeContext) async throws -> Response
    ) {
        handlerLock.lock()
        defer { handlerLock.unlock() }
        httpHandlers[name] = handler
    }

    // MARK: - Task Management

    /// Spawn a background task
    /// - Parameter work: The async work to perform
    /// - Returns: Task ID for tracking
    @discardableResult
    public func spawnTask(_ work: @Sendable @escaping () async -> Void) -> UUID {
        let taskId = UUID()

        let task = Task { @Sendable in
            await work()
            self.removeTask(taskId)
        }

        taskLock.lock()
        activeTasks[taskId] = task
        taskLock.unlock()

        return taskId
    }

    private func removeTask(_ id: UUID) {
        taskLock.lock()
        activeTasks.removeValue(forKey: id)
        taskLock.unlock()
    }

    /// Wait for all active tasks to complete
    public func waitForActiveTasks() async {
        let tasks = getActiveTasks()

        for task in tasks {
            await task.value
        }
    }

    /// Get active tasks thread-safely
    private func getActiveTasks() -> [Task<Void, Never>] {
        taskLock.lock()
        defer { taskLock.unlock() }
        return Array(activeTasks.values)
    }

    // MARK: - Shutdown

    private var isShuttingDownNow: Bool {
        shutdownLock.lock()
        defer { shutdownLock.unlock() }
        return isShuttingDown
    }

    /// Request shutdown of the event loop
    public func requestShutdown() {
        shutdownLock.lock()
        isShuttingDown = true
        shutdownLock.unlock()
    }

    /// Perform graceful shutdown
    private func shutdown() async {
        // Cancel all active tasks
        cancelAllTasks()

        #if !os(Windows)
        // Shutdown NIO event loop group if it was created
        // Safe to read _eventLoopGroup directly - it's only written once during lazy init
        if let group = _eventLoopGroup {
            try? await group.shutdownGracefully()
        }
        #endif
    }

    /// Cancel all active tasks thread-safely
    private func cancelAllTasks() {
        taskLock.lock()
        defer { taskLock.unlock() }
        for (_, task) in activeTasks {
            task.cancel()
        }
        activeTasks.removeAll()
    }

    // MARK: - Signal Handling

    private func setupSignalHandlers() {
        // Set up SIGINT handler (Ctrl+C)
        signal(SIGINT) { _ in
            AROAsyncRuntime.shared.requestShutdown()
        }

        // Set up SIGTERM handler
        signal(SIGTERM) { _ in
            AROAsyncRuntime.shared.requestShutdown()
        }
    }
}

// MARK: - C Bridge Functions

/// Run the async event loop from C code
/// - Parameter runtimePtr: The runtime handle (can be nil, uses shared instance)
/// - Returns: 0 on success, non-zero on error
@_cdecl("aro_async_run")
public func aro_async_run(_ runtimePtr: UnsafeMutableRawPointer?) -> Int32 {
    AROAsyncRuntime.shared.runEventLoop()
    return 0
}

/// Request shutdown of the async event loop
@_cdecl("aro_async_shutdown")
public func aro_async_shutdown() {
    AROAsyncRuntime.shared.requestShutdown()
}

/// Thread-safe response holder for C bridge
private final class ResponseHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var _response: Response?

    var response: Response? {
        lock.lock()
        defer { lock.unlock() }
        return _response
    }

    func setResponse(_ r: Response) {
        lock.lock()
        defer { lock.unlock() }
        _response = r
    }
}

/// Spawn a feature set for async execution
/// - Parameters:
///   - name: Feature set name (C string)
///   - contextPtr: Context handle
/// - Returns: Response handle, or nil on error
@_cdecl("aro_async_spawn_feature_set")
public func aro_async_spawn_feature_set(
    _ name: UnsafePointer<CChar>?,
    _ contextPtr: UnsafeMutableRawPointer?
) -> UnsafeMutableRawPointer? {
    guard let nameStr = name.map({ String(cString: $0) }),
          let ctxPtr = contextPtr else { return nil }

    let ctxHandle = Unmanaged<AROCContextHandle>.fromOpaque(ctxPtr).takeUnretainedValue()
    let context = ctxHandle.context  // Capture the context, not the handle

    let holder = ResponseHolder()
    let semaphore = DispatchSemaphore(value: 0)

    // Use Task.detached to ensure the task runs on the concurrent executor
    // rather than inheriting the current task context. This prevents deadlocks
    // on Linux where the default Task might try to use the blocked thread.
    Task.detached { @Sendable in
        do {
            let resp = try await AROAsyncRuntime.shared.spawnFeatureSet(
                nameStr,
                context: context
            )
            holder.setResponse(resp)
        } catch {
            holder.setResponse(Response(status: "Error", reason: String(describing: error)))
        }
        semaphore.signal()
    }

    semaphore.wait()

    guard let resp = holder.response else { return nil }

    // Box and return the response
    let boxed = AROCValue(value: resp)
    return UnsafeMutableRawPointer(Unmanaged.passRetained(boxed).toOpaque())
}

/// Register a native feature set handler
/// - Parameters:
///   - name: Feature set name (C string)
///   - handler: Function pointer for the handler
@_cdecl("aro_async_register_handler")
public func aro_async_register_handler(
    _ name: UnsafePointer<CChar>?,
    _ handler: UnsafeMutableRawPointer?
) {
    guard let nameStr = name.map({ String(cString: $0) }) else { return }

    // Store the handler for later invocation
    // The actual implementation would need to call through dlsym
    // For now, we just register the name
    AROAsyncRuntime.shared.registerHandler(nameStr) { context in
        // This will be replaced with actual feature set execution
        return Response.ok()
    }
}
