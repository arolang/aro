// ============================================================
// ServerActions.swift
// ARO Runtime - Server and Listener Action Implementations
// ============================================================

import Foundation
import AROParser

/// Starts a server or service
///
/// The Start action initializes and starts servers, services, or other
/// long-running components. All services use the `with` preposition for
/// configuration.
///
/// ## Examples
/// ```aro
/// <Start> the <http-server> with <contract>.
/// <Start> the <socket-server> with { port: 9000 }.
/// <Start> the <file-monitor> with { directory: "." }.
/// ```
public struct StartAction: ActionImplementation {
    public static let role: ActionRole = .own
    public static let verbs: Set<String> = ["start"]
    public static let validPrepositions: Set<Preposition> = [.with]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        // Determine what to start based on result
        let serverType = result.base.lowercased()

        switch serverType {
        case "http-server", "httpserver", "server":
            return try await startHTTPServer(object: object, context: context)

        case "socket-server", "socketserver":
            return try await startSocketServer(object: object, context: context)

        case "file-monitor", "filemonitor", "watcher":
            return try await startFileMonitor(object: object, context: context)

        default:
            // Generic service start
            context.emit(ServiceStartedEvent(serviceName: serverType))
            return ServerStartResult(serverType: serverType, success: true)
        }
    }

    private func startHTTPServer(object: ObjectDescriptor, context: ExecutionContext) async throws -> any Sendable {
        // Get port from:
        // 1. Explicit port in ARO code (_with_ clause, object specifiers, or literal)
        // 2. OpenAPI spec (contract is source of truth)
        // 3. Default to 8080
        var port = 8080

        // Priority 1: Check _with_ binding (ARO-0042: with clause)
        if let withValue = context.resolveAny("_with_") {
            if let withPort = withValue as? Int {
                // Direct integer: with 8080
                port = withPort
            } else if let contract = withValue as? Contract,
                      let httpServer = contract.httpServer {
                // Contract magic object: with <contract>
                port = httpServer.port
            } else if let httpServer = withValue as? HTTPServerConfig {
                // HTTP server config: with <http-server>
                port = httpServer.port
            } else if let withConfig = withValue as? [String: any Sendable],
                      let configPort = withConfig["port"] as? Int {
                // Config object: with { port: 8080 }
                port = configPort
            } else if let specService = context.service(OpenAPISpecService.self),
                      let openAPIPort = specService.serverPort {
                // Empty config {}, use OpenAPI port
                port = openAPIPort
            } else {
                // Empty config {}, use default
                port = 8080
            }
        }
        // Priority 2: Check for explicit port in object specifiers
        if port == 8080, let portSpec = object.specifiers.first, let p = Int(portSpec) {
            port = p
        }
        // Priority 3: Check _literal_ (older syntax)
        if port == 8080, let literalPort = context.resolveAny("_literal_") as? Int {
            port = literalPort
        }
        if port == 8080, let literalStr = context.resolveAny("_literal_") as? String, let p = Int(literalStr) {
            port = p
        }
        // Priority 4: OpenAPI spec port
        if port == 8080, let specService = context.service(OpenAPISpecService.self),
           let openAPIPort = specService.serverPort {
            // Get port from OpenAPI contract (source of truth)
            port = openAPIPort
        }
        // Priority 5: Try to extract port from object base (only if still default)
        if port == 8080 {
            let portStr = object.base.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
            if let p = Int(portStr) {
                port = p
            }
        }

        // Try HTTP server service (interpreter mode with NIO)
        if let httpServerService = context.service(HTTPServerService.self) {
            try await httpServerService.start(port: port)
            return ServerStartResult(serverType: "http-server", success: true, port: port)
        }

        // For compiled binaries, use the native HTTP server (BSD sockets)
        #if !os(Windows)
        // Pass nil for context - the native server will create contexts per-request
        // via the aro_context_create() C function when invoking feature sets
        // If port is still default (8080), pass 0 to let native function extract from OpenAPI spec
        let nativePort = (port == 8080) ? 0 : port
        let result = aro_native_http_server_start_with_openapi(Int32(nativePort), nil)
        if result == 0 {
            return ServerStartResult(serverType: "http-server", success: true, port: port)
        } else {
            throw ActionError.runtimeError("Failed to start HTTP server on port \(port)")
        }
        #else
        // Emit event for external handling on Windows
        context.emit(HTTPServerStartRequestedEvent(port: port))
        return ServerStartResult(serverType: "http-server", success: true, port: port)
        #endif
    }

    private func startSocketServer(object: ObjectDescriptor, context: ExecutionContext) async throws -> any Sendable {
        // Get port from various sources:
        // 1. From "with" clause (_with_) - config object or direct value
        // 2. From "with" clause (_literal_ or _expression_) - legacy support
        // 3. From object specifiers
        // 4. Default to 9000
        let port: Int

        // Priority 1: Check _with_ binding (ARO-0042: with clause)
        if let withValue = context.resolveAny("_with_") {
            if let withPort = withValue as? Int {
                // Direct integer: with 9000
                port = withPort
            } else if let withConfig = withValue as? [String: any Sendable],
                      let configPort = withConfig["port"] as? Int {
                // Config object: with { port: 9000 }
                port = configPort
            } else {
                port = 9000 // default if with clause doesn't contain port
            }
        }
        // Priority 2: Check _literal_ (older syntax)
        else if let literalPort = context.resolveAny("_literal_") as? Int {
            port = literalPort
        } else if let literalStr = context.resolveAny("_literal_") as? String, let p = Int(literalStr) {
            port = p
        }
        // Priority 3: Check _expression_ (older syntax)
        else if let exprPort = context.resolveAny("_expression_") as? Int {
            port = exprPort
        }
        // Priority 4: Check object specifiers
        else if let portSpec = object.specifiers.first, let p = Int(portSpec) {
            port = p
        }
        // Default
        else {
            port = 9000
        }

        // Try using the SocketServerService (interpreter mode with NIO)
        if let socketService = context.service(SocketServerService.self) {
            try await socketService.start(port: port)
            return ServerStartResult(serverType: "socket-server", success: true, port: port)
        }

        // For compiled binaries, use the native socket server (BSD sockets)
        #if !os(Windows)
        let result = aro_native_socket_server_start(Int32(port))
        if result == 0 {
            return ServerStartResult(serverType: "socket-server", success: true, port: port)
        } else {
            throw ActionError.runtimeError("Failed to start socket server on port \(port)")
        }
        #else
        context.emit(SocketServerStartRequestedEvent(port: port))
        return ServerStartResult(serverType: "socket-server", success: true, port: port)
        #endif
    }

    private func startFileMonitor(object: ObjectDescriptor, context: ExecutionContext) async throws -> any Sendable {
        // Get path from various sources with the standardized "with" syntax:
        // 1. From literal string: <Start> the <file-monitor> with ".".
        // 2. From object property: <Start> the <file-monitor> with { directory: "." }.
        // 3. From variable: <Start> the <file-monitor> with <config>.
        let path: String

        if let literalPath: String = context.resolve("_literal_") {
            // Direct string literal
            path = literalPath
        } else if let objectConfig = context.resolveAny("_object_") as? [String: Any],
                  let dirPath = objectConfig["directory"] as? String {
            // Object literal with directory property
            path = dirPath
        } else if let exprValue = context.resolveAny("_expression_") as? [String: Any],
                  let dirPath = exprValue["directory"] as? String {
            // Expression that resolved to object
            path = dirPath
        } else if let specPath = object.specifiers.first {
            // Object specifier (fallback)
            path = specPath
        } else {
            // Default to current directory
            path = "."
        }

        if let fileMonitorService = context.service(FileMonitorService.self) {
            try await fileMonitorService.watch(path: path)
            return ServerStartResult(serverType: "file-monitor", success: true, path: path)
        }

        // For compiled binaries, use native file watcher
        #if !os(Windows)
        let started = NativeFileWatcher.shared.startWatching(path: path)
        if started {
            return ServerStartResult(serverType: "file-monitor", success: true, path: path)
        }
        #endif

        context.emit(FileMonitorStartRequestedEvent(path: path))
        return ServerStartResult(serverType: "file-monitor", success: true, path: path)
    }
}

/// Stops a server or service
///
/// The Stop action gracefully stops servers, services, or other
/// long-running components.
///
/// ## Examples
/// ```aro
/// <Stop> the <http-server> with <application>.
/// <Stop> the <socket-server> with <application>.
/// <Stop> the <file-monitor> with <application>.
/// ```
public struct StopAction: ActionImplementation {
    public static let role: ActionRole = .own
    public static let verbs: Set<String> = ["stop"]
    public static let validPrepositions: Set<Preposition> = [.with]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        // Determine what to stop based on result
        let serviceType = result.base.lowercased()

        switch serviceType {
        case "http-server", "httpserver", "server":
            return try await stopHTTPServer(context: context)

        case "socket-server", "socketserver":
            return try await stopSocketServer(context: context)

        case "file-monitor", "filemonitor", "watcher":
            return stopFileMonitor()

        default:
            // Generic service stop
            context.emit(ServiceStoppedEvent(serviceName: serviceType))
            return ServerStopResult(serverType: serviceType, success: true)
        }
    }

    private func stopHTTPServer(context: ExecutionContext) async throws -> any Sendable {
        if let httpServerService = context.service(HTTPServerService.self) {
            try await httpServerService.stop()
            return ServerStopResult(serverType: "http-server", success: true)
        }

        #if !os(Windows)
        aro_native_http_server_stop()
        #endif

        return ServerStopResult(serverType: "http-server", success: true)
    }

    private func stopSocketServer(context: ExecutionContext) async throws -> any Sendable {
        if let socketService = context.service(SocketServerService.self) {
            try await socketService.stop()
            return ServerStopResult(serverType: "socket-server", success: true)
        }

        #if !os(Windows)
        aro_native_socket_server_stop()
        #endif

        return ServerStopResult(serverType: "socket-server", success: true)
    }

    private func stopFileMonitor() -> any Sendable {
        #if !os(Windows)
        NativeFileWatcher.shared.stopWatching()
        #endif

        return ServerStopResult(serverType: "file-monitor", success: true)
    }
}

/// Result of a service stop operation
public struct ServerStopResult: Sendable, Equatable {
    public let serverType: String
    public let success: Bool

    public init(serverType: String, success: Bool) {
        self.serverType = serverType
        self.success = success
    }
}

/// Event emitted when a service stops
public struct ServiceStoppedEvent: RuntimeEvent {
    public static var eventType: String { "service.stopped" }
    public let timestamp: Date
    public let serviceName: String

    public init(serviceName: String) {
        self.timestamp = Date()
        self.serviceName = serviceName
    }
}

/// Listens on a port or for events
///
/// The Listen action sets up event listeners for incoming connections,
/// requests, or data.
///
/// ## Example
/// ```
/// <Listen> on port 9000 as <socket-server>.
/// ```
public struct ListenAction: ActionImplementation {
    public static let role: ActionRole = .own
    public static let verbs: Set<String> = ["listen", "await"]
    public static let validPrepositions: Set<Preposition> = [.on, .for, .to]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        // Determine what to listen for
        let listenType = object.base.lowercased()

        switch listenType {
        case "port":
            let port = Int(object.specifiers.first ?? "8080") ?? 8080
            context.emit(ListenStartedEvent(type: "port", target: String(port)))
            return ListenResult(type: "port", target: String(port))

        case "events", "event":
            let eventType = object.specifiers.first ?? "*"
            context.emit(ListenStartedEvent(type: "events", target: eventType))
            return ListenResult(type: "events", target: eventType)

        case "file", "files", "directory":
            let path = object.specifiers.first ?? "."
            context.emit(ListenStartedEvent(type: "file", target: path))
            return ListenResult(type: "file", target: path)

        default:
            context.emit(ListenStartedEvent(type: "generic", target: object.base))
            return ListenResult(type: "generic", target: object.base)
        }
    }
}

/// Native file watcher wrapper for compiled binaries
public final class NativeFileWatcher: @unchecked Sendable {
    public static let shared = NativeFileWatcher()

    private let lock = NSLock()
    private var watcherPtr: UnsafeMutableRawPointer?

    private init() {}

    /// Start watching a path
    public func startWatching(path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        // Stop any existing watcher
        if let ptr = watcherPtr {
            aro_file_watcher_stop(ptr)
            aro_file_watcher_destroy(ptr)
            watcherPtr = nil
        }

        // Create and start new watcher
        guard let ptr = path.withCString({ aro_file_watcher_create($0) }) else {
            return false
        }

        let result = aro_file_watcher_start(ptr)
        if result == 0 {
            watcherPtr = ptr
            return true
        } else {
            aro_file_watcher_destroy(ptr)
            return false
        }
    }

    /// Stop watching
    public func stopWatching() {
        lock.lock()
        defer { lock.unlock() }

        if let ptr = watcherPtr {
            aro_file_watcher_stop(ptr)
            aro_file_watcher_destroy(ptr)
            watcherPtr = nil
        }
    }
}

// MARK: - Supporting Types

/// HTTP server service protocol
public protocol HTTPServerService: Sendable {
    func start(port: Int) async throws
    func stop() async throws
}

/// Socket server service protocol
public protocol SocketServerService: Sendable {
    func start(port: Int) async throws
    func stop() async throws
    func send(data: Data, to connectionId: String) async throws
    func send(string: String, to connectionId: String) async throws
    func broadcast(data: Data) async throws
}

/// File monitor service protocol
public protocol FileMonitorService: Sendable {
    func watch(path: String) async throws
    func unwatch(path: String) async throws
}

/// Result of a server start operation
public struct ServerStartResult: Sendable, Equatable {
    public let serverType: String
    public let success: Bool
    public let port: Int?
    public let path: String?

    public init(serverType: String, success: Bool, port: Int? = nil, path: String? = nil) {
        self.serverType = serverType
        self.success = success
        self.port = port
        self.path = path
    }
}

/// Result of a listen operation
public struct ListenResult: Sendable, Equatable {
    public let type: String
    public let target: String
}

// MARK: - Supporting Events

/// Event emitted when a service starts
public struct ServiceStartedEvent: RuntimeEvent {
    public static var eventType: String { "service.started" }
    public let timestamp: Date
    public let serviceName: String

    public init(serviceName: String) {
        self.timestamp = Date()
        self.serviceName = serviceName
    }
}

/// Event requesting HTTP server start
public struct HTTPServerStartRequestedEvent: RuntimeEvent {
    public static var eventType: String { "http.server.start.requested" }
    public let timestamp: Date
    public let port: Int

    public init(port: Int) {
        self.timestamp = Date()
        self.port = port
    }
}

/// Event requesting socket server start
public struct SocketServerStartRequestedEvent: RuntimeEvent {
    public static var eventType: String { "socket.server.start.requested" }
    public let timestamp: Date
    public let port: Int

    public init(port: Int) {
        self.timestamp = Date()
        self.port = port
    }
}

/// Event requesting file monitor start
public struct FileMonitorStartRequestedEvent: RuntimeEvent {
    public static var eventType: String { "file.monitor.start.requested" }
    public let timestamp: Date
    public let path: String

    public init(path: String) {
        self.timestamp = Date()
        self.path = path
    }
}

/// Event emitted when listening starts
public struct ListenStartedEvent: RuntimeEvent {
    public static var eventType: String { "listen.started" }
    public let timestamp: Date
    public let type: String
    public let target: String

    public init(type: String, target: String) {
        self.timestamp = Date()
        self.type = type
        self.target = target
    }
}

/// Event emitted when file watching starts
public struct FileWatchStartedEvent: RuntimeEvent {
    public static var eventType: String { "file.watch.started" }
    public let timestamp: Date
    public let path: String

    public init(path: String) {
        self.timestamp = Date()
        self.path = path
    }
}

/// Global shutdown coordinator for long-running applications
public final class ShutdownCoordinator: @unchecked Sendable {
    public static let shared = ShutdownCoordinator()

    private let lock = NSLock()
    private var waiters: [UUID: () -> Void] = [:]
    private var isShuttingDown = false

    /// Semaphore for synchronous waiting (used by compiled binaries)
    private var syncSemaphore: DispatchSemaphore?
    private var syncWaiterCount = 0

    private init() {}

    /// Check if already shutting down (synchronous helper)
    private func checkShuttingDown() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isShuttingDown
    }

    /// Public synchronous check for native code
    public var isShuttingDownNow: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isShuttingDown
    }

    /// Register a waiter and return whether we should wait
    private func registerWaiter(id: UUID, resume: @escaping () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if isShuttingDown {
            return false // Don't wait, already shutting down
        }

        waiters[id] = resume
        return true // Should wait
    }

    /// Wait for shutdown signal (blocks until signaled) - async version
    public func waitForShutdown() async {
        // Quick check before setting up continuation
        if checkShuttingDown() {
            return
        }

        // Safety timeout in test environments
        let isTestEnvironment = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestSessionIdentifier"] != nil

        if isTestEnvironment {
            // In test environments, use a timeout to prevent hanging
            try? await withThrowingTaskGroup(of: Void.self) { group in
                // Add wait task
                group.addTask {
                    let id = UUID()
                    await withUnsafeContinuation { (continuation: UnsafeContinuation<Void, Never>) in
                        let shouldWait = self.registerWaiter(id: id) {
                            continuation.resume()
                        }
                        if !shouldWait {
                            continuation.resume()
                        }
                    }
                }

                // Add timeout task (1 second)
                group.addTask {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }

                // Wait for first one to complete
                try await group.next()
                group.cancelAll()
            }
            return
        }

        // Production: wait indefinitely
        let id = UUID()
        await withUnsafeContinuation { (continuation: UnsafeContinuation<Void, Never>) in
            let shouldWait = self.registerWaiter(id: id) {
                continuation.resume()
            }

            if !shouldWait {
                continuation.resume()
            }
        }
    }

    /// Wait for shutdown signal synchronously (blocks the calling thread)
    /// This is used by compiled binaries where async/await may not work correctly
    /// Uses RunLoop to allow event processing (FSEvents, timers, etc.)
    public func waitForShutdownSync() {
        // Quick check before blocking
        if checkShuttingDown() {
            return
        }

        // Register as sync waiter
        lock.lock()
        if syncSemaphore == nil {
            syncSemaphore = DispatchSemaphore(value: 0)
        }
        syncWaiterCount += 1
        let sem = syncSemaphore!
        lock.unlock()

        // Safety timeout: don't block forever in test environments
        // If we're running tests, limit blocking time to avoid hanging the test runner
        let isTestEnvironment = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestSessionIdentifier"] != nil
        let maxIterations = isTestEnvironment ? 10 : Int.max  // ~1 second in tests, unlimited in production

        var iterations = 0
        // Run the RunLoop to allow event processing (FSEvents, dispatch queues, etc.)
        // Check periodically if shutdown was signaled
        while !isShuttingDownNow && iterations < maxIterations {
            iterations += 1

            // Process events for a short time
            let result = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))

            // If RunLoop had no sources and exited, try with semaphore timeout
            if !result {
                // Try to acquire semaphore with timeout to allow checking shutdown flag
                let waitResult = sem.wait(timeout: .now() + .milliseconds(100))
                if waitResult == .success {
                    // Semaphore was signaled
                    break
                }
            }
        }
    }

    /// Signal shutdown to all waiting tasks
    public func signalShutdown() {
        lock.lock()
        isShuttingDown = true
        let waiting = waiters
        waiters.removeAll()
        let syncCount = syncWaiterCount
        let sem = syncSemaphore
        syncWaiterCount = 0
        lock.unlock()

        // Resume async waiters
        for (_, resume) in waiting {
            resume()
        }

        // Signal sync waiters
        if let sem = sem {
            for _ in 0..<syncCount {
                sem.signal()
            }
        }
    }

    /// Reset for new application run
    public func reset() {
        lock.lock()
        isShuttingDown = false
        waiters.removeAll()
        syncWaiterCount = 0
        syncSemaphore = nil
        lock.unlock()
    }
}

/// Waits for events, keeping the application alive
///
/// The Wait action blocks execution until a shutdown signal is received,
/// allowing the application to process events from started services.
///
/// ## Example
/// ```
/// <Wait> for <shutdown-signal>.
/// ```
///
/// The `shutdown-signal` event is triggered by SIGINT (Ctrl+C) or SIGTERM.
/// Legacy syntax `<Keepalive> the <application> for the <events>.` is still supported.
public struct WaitForEventsAction: ActionImplementation {
    public static let role: ActionRole = .own
    public static let verbs: Set<String> = ["wait", "keepalive", "block"]
    public static let validPrepositions: Set<Preposition> = [.for]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        // Set up signal handling (idempotent)
        KeepaliveSignalHandler.shared.setup()

        // Enter wait state
        context.enterWaitState()

        // Emit event to signal we're waiting
        context.emit(WaitStateEnteredEvent())

        // Block until shutdown is signaled via the global coordinator
        await ShutdownCoordinator.shared.waitForShutdown()

        return WaitResult(completed: true, reason: "shutdown")
    }
}

/// Signal handler for Keepalive action
public final class KeepaliveSignalHandler: @unchecked Sendable {
    public static let shared = KeepaliveSignalHandler()

    private let lock = NSLock()
    private var isSetup = false

    private init() {}

    /// Set up signal handlers (idempotent)
    public func setup() {
        lock.lock()
        defer { lock.unlock() }

        if isSetup { return }
        isSetup = true

        // If RuntimeSignalHandler is already active, don't override its handlers.
        // Runtime.stop() already calls ShutdownCoordinator.signalShutdown(),
        // so the keepalive wait will unblock through the normal shutdown flow
        // which also executes Application-End handlers.
        guard !RuntimeSignalHandler.shared.isActive else { return }

        signal(SIGINT) { _ in
            ShutdownCoordinator.shared.signalShutdown()
            // Exit after a brief delay to allow cleanup
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                exit(0)
            }
        }

        signal(SIGTERM) { _ in
            ShutdownCoordinator.shared.signalShutdown()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                exit(0)
            }
        }
    }
}

/// Result of a wait operation
public struct WaitResult: Sendable, Equatable {
    public let completed: Bool
    public let reason: String
}

/// Event emitted when entering wait state
public struct WaitStateEnteredEvent: RuntimeEvent {
    public static var eventType: String { "wait.state.entered" }
    public let timestamp: Date

    public init() {
        self.timestamp = Date()
    }
}

// MARK: - Socket Actions

/// Connects to a remote socket server
///
/// The Connect action establishes a TCP connection to a remote host.
///
/// ## Example
/// ```
/// <Connect> to <host: "192.168.1.100"> on port 8080 as <server-connection>.
/// ```
public struct ConnectAction: ActionImplementation {
    public static let role: ActionRole = .own
    public static let verbs: Set<String> = ["connect"]
    public static let validPrepositions: Set<Preposition> = [.to, .with]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        // Parse host and port from object
        // Expected format: <host: "hostname"> or host specified in object.base
        let host: String
        let port: Int

        // Check for host in object specifiers
        if object.base.lowercased() == "host" {
            // <Connect> to <host: "192.168.1.100"> on port 8080
            if let hostSpec = object.specifiers.first {
                host = hostSpec.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            } else {
                host = "localhost"
            }
        } else if let resolvedHost: String = context.resolve(object.base) {
            host = resolvedHost
        } else {
            host = object.base
        }

        // Get port from various sources (matching StartAction pattern)
        // Priority 1: Check _with_ binding (ARO-0042: with clause)
        if let withValue = context.resolveAny("_with_") {
            if let withPort = withValue as? Int {
                port = withPort
            } else if let withConfig = withValue as? [String: any Sendable],
                      let configPort = withConfig["port"] as? Int {
                port = configPort
            } else {
                port = 8080 // default if with clause doesn't contain port
            }
        }
        // Priority 2: Check _literal_
        else if let portValue = context.resolveAny("_literal_") as? Int {
            port = portValue
        } else if let portStr = context.resolveAny("_literal_") as? String, let p = Int(portStr) {
            port = p
        }
        // Priority 3: Try to find port in specifiers
        else if let portSpec = object.specifiers.dropFirst().first, let p = Int(portSpec) {
            port = p
        }
        // Default
        else {
            port = 8080
        }

        #if !os(Windows)
        // Create and connect socket client
        let client = AROSocketClient(eventBus: .shared)
        try await client.connect(host: host, port: port)

        // Store connection in context
        let connectionId = client.connectionId
        context.bind(result.base, value: connectionId)

        // Register the client for later use
        context.register(client)

        return ConnectResult(connectionId: connectionId, host: host, port: port, success: true)
        #else
        throw ActionError.runtimeError("Socket client not available on Windows")
        #endif
    }
}

/// Result of a connect operation
public struct ConnectResult: Sendable, Equatable {
    public let connectionId: String
    public let host: String
    public let port: Int
    public let success: Bool
}

/// Broadcasts data to all connected clients
///
/// The Broadcast action sends data to all clients connected to a socket server.
///
/// ## Example
/// ```
/// <Broadcast> the <message> to the <socket-server>.
/// ```
public struct BroadcastAction: ActionImplementation {
    public static let role: ActionRole = .response
    public static let verbs: Set<String> = ["broadcast"]
    public static let validPrepositions: Set<Preposition> = [.to, .via]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        // Get data to broadcast
        guard let data = context.resolveAny(result.base) else {
            throw ActionError.undefinedVariable(result.base)
        }

        // Convert data to bytes
        let dataToSend: Data
        if let d = data as? Data {
            dataToSend = d
        } else if let s = data as? String {
            dataToSend = s.data(using: .utf8) ?? Data()
        } else {
            dataToSend = String(describing: data).data(using: .utf8) ?? Data()
        }

        #if !os(Windows)
        // Try socket server service (interpreter mode)
        if let socketServer = context.service(SocketServerService.self) {
            try await socketServer.broadcast(data: dataToSend)
            return BroadcastResult(success: true, clientCount: -1) // Count not available
        }

        // For compiled binaries, use native socket broadcast
        let count = NativeSocketBroadcaster.shared.broadcast(data: dataToSend)
        if count >= 0 {
            return BroadcastResult(success: true, clientCount: count)
        }
        #endif

        // Emit broadcast event as fallback
        context.emit(BroadcastRequestedEvent(data: String(describing: data)))

        return BroadcastResult(success: true, clientCount: 0)
    }
}

/// Native socket broadcaster wrapper for compiled binaries
public final class NativeSocketBroadcaster: @unchecked Sendable {
    public static let shared = NativeSocketBroadcaster()

    private init() {}

    /// Broadcast data to all connected clients
    public func broadcast(data: Data) -> Int {
        return data.withUnsafeBytes { buffer in
            guard let ptr = buffer.baseAddress else { return -1 }
            return Int(aro_native_socket_broadcast(ptr.assumingMemoryBound(to: UInt8.self), data.count))
        }
    }
}

/// Result of a broadcast operation
public struct BroadcastResult: Sendable, Equatable {
    public let success: Bool
    public let clientCount: Int
}

/// Event emitted when broadcast is requested
public struct BroadcastRequestedEvent: RuntimeEvent {
    public static var eventType: String { "broadcast.requested" }
    public let timestamp: Date
    public let data: String

    public init(data: String) {
        self.timestamp = Date()
        self.data = data
    }
}

/// Closes a connection or server
///
/// The Close action terminates a socket connection or stops a server.
///
/// ## Example
/// ```
/// <Close> the <connection>.
/// <Close> the <socket-server>.
/// ```
public struct CloseAction: ActionImplementation {
    public static let role: ActionRole = .own
    public static let verbs: Set<String> = ["close", "disconnect", "terminate"]
    public static let validPrepositions: Set<Preposition> = [.with, .from]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        // Get what to close from result
        let target = result.base.lowercased()

        #if !os(Windows)
        switch target {
        case "socket-server", "socketserver", "server":
            // Close socket server
            if let socketServer = context.service(SocketServerService.self) {
                try await socketServer.stop()
                return CloseResult(target: target, success: true)
            }

        case "connection":
            // Close a specific connection
            if let connectionId: String = context.resolve(object.base) {
                if let socketServer = context.service(SocketServerService.self) {
                    if let server = socketServer as? AROSocketServer {
                        try await server.disconnect(connectionId)
                        return CloseResult(target: connectionId, success: true)
                    }
                }
            }

        default:
            // Try to resolve as connection ID and disconnect
            if let connectionId: String = context.resolve(result.base) {
                if let socketServer = context.service(SocketServerService.self) {
                    if let server = socketServer as? AROSocketServer {
                        try await server.disconnect(connectionId)
                        return CloseResult(target: connectionId, success: true)
                    }
                }
            }
        }
        #endif

        // Emit close event
        context.emit(CloseRequestedEvent(target: target))

        return CloseResult(target: target, success: true)
    }
}

/// Result of a close operation
public struct CloseResult: Sendable, Equatable {
    public let target: String
    public let success: Bool
}

/// Event emitted when close is requested
public struct CloseRequestedEvent: RuntimeEvent {
    public static var eventType: String { "close.requested" }
    public let timestamp: Date
    public let target: String

    public init(target: String) {
        self.timestamp = Date()
        self.target = target
    }
}

// MARK: - Preposition Extension

extension Preposition {
    /// Additional preposition for routing
    public static var through: Preposition { .via }
    public static var `in`: Preposition { .into }
}
