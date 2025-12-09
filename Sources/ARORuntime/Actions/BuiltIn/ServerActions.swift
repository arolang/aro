// ============================================================
// ServerActions.swift
// ARO Runtime - Server and Listener Action Implementations
// ============================================================

import Foundation
import AROParser

/// Starts a server or service
///
/// The Start action initializes and starts servers, services, or other
/// long-running components.
///
/// ## Example
/// ```
/// <Start> the <http-server> on port 8080.
/// ```
public struct StartAction: ActionImplementation {
    public static let role: ActionRole = .own
    public static let verbs: Set<String> = ["start", "initialize", "boot"]
    public static let validPrepositions: Set<Preposition> = [.with, .on]

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
        // 1. Explicit port in ARO code (object specifiers or literal)
        // 2. OpenAPI spec (contract is source of truth)
        // 3. Default to 8080
        let port: Int

        // Check for explicit port in code
        if let portSpec = object.specifiers.first, let p = Int(portSpec) {
            port = p
        } else if let literalPort = context.resolveAny("_literal_") as? Int {
            port = literalPort
        } else if let literalStr = context.resolveAny("_literal_") as? String, let p = Int(literalStr) {
            port = p
        } else if let specService = context.service(OpenAPISpecService.self),
                  let openAPIPort = specService.serverPort {
            // Get port from OpenAPI contract (source of truth)
            port = openAPIPort
        } else {
            let portStr = object.base.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
            if let p = Int(portStr) {
                port = p
            } else {
                port = 8080 // default
            }
        }

        // Try HTTP server service
        if let httpServerService = context.service(HTTPServerService.self) {
            try await httpServerService.start(port: port)
            return ServerStartResult(serverType: "http-server", success: true, port: port)
        }

        // Emit event for external handling
        context.emit(HTTPServerStartRequestedEvent(port: port))
        return ServerStartResult(serverType: "http-server", success: true, port: port)
    }

    private func startSocketServer(object: ObjectDescriptor, context: ExecutionContext) async throws -> any Sendable {
        // Get port from various sources:
        // 1. From "with" clause (_literal_ or _expression_)
        // 2. From object specifiers
        // 3. Default to 9000
        let port: Int
        if let literalPort = context.resolveAny("_literal_") as? Int {
            port = literalPort
        } else if let literalStr = context.resolveAny("_literal_") as? String, let p = Int(literalStr) {
            port = p
        } else if let exprPort = context.resolveAny("_expression_") as? Int {
            port = exprPort
        } else if let portSpec = object.specifiers.first, let p = Int(portSpec) {
            port = p
        } else {
            port = 9000 // default
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
        let path = object.base

        if let fileMonitorService = context.service(FileMonitorService.self) {
            try await fileMonitorService.watch(path: path)
            return ServerStartResult(serverType: "file-monitor", success: true, path: path)
        }

        context.emit(FileMonitorStartRequestedEvent(path: path))
        return ServerStartResult(serverType: "file-monitor", success: true, path: path)
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

/// Routes a request to a handler
///
/// The Route action dispatches incoming requests to appropriate handlers
/// based on path, method, or other criteria.
///
/// ## Example
/// ```
/// <Route> the <request> through <router>.
/// ```
public struct RouteAction: ActionImplementation {
    public static let role: ActionRole = .own
    public static let verbs: Set<String> = ["route", "dispatch", "forward"]
    public static let validPrepositions: Set<Preposition> = [.through, .via, .to]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        // Get request to route
        guard let request = context.resolveAny(result.base) else {
            throw ActionError.undefinedVariable(result.base)
        }

        // Get router
        let routerName = object.base

        // Try routing service
        if let routerService = context.service(RouterService.self) {
            return try await routerService.route(request: request)
        }

        // Emit routing event
        context.emit(RouteRequestedEvent(requestType: String(describing: type(of: request)), router: routerName))

        return RouteResult(router: routerName, success: true)
    }
}

/// Watches a file or directory for changes
///
/// The Watch action sets up file system monitoring for changes.
///
/// ## Example
/// ```
/// <Watch> the <directory: "./watched"> as <file-monitor>.
/// ```
public struct WatchAction: ActionImplementation {
    public static let role: ActionRole = .own
    public static let verbs: Set<String> = ["watch", "monitor", "observe"]
    public static let validPrepositions: Set<Preposition> = [.for, .on]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        // Get path to watch - check literal value first, then object specifiers, then result
        let path: String
        if let literalPath: String = context.resolve("_literal_") {
            // Path provided via "with" clause: <Watch> the <x> for the <y> with "."
            path = literalPath
        } else if let specPath = object.specifiers.first {
            // Path in object specifier
            path = specPath
        } else if let resolvedPath: String = context.resolve(result.base) {
            // Path from resolved variable
            path = resolvedPath
        } else {
            // Fallback to current directory
            path = "."
        }

        // Try file monitor service
        if let fileMonitorService = context.service(FileMonitorService.self) {
            try await fileMonitorService.watch(path: path)
            return WatchResult(path: path, success: true)
        }

        // Emit watch event
        context.emit(FileWatchStartedEvent(path: path))

        return WatchResult(path: path, success: true)
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

/// Router service protocol
public protocol RouterService: Sendable {
    func route(request: Any) async throws -> any Sendable
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

/// Result of a route operation
public struct RouteResult: Sendable, Equatable {
    public let router: String
    public let success: Bool
}

/// Result of a watch operation
public struct WatchResult: Sendable, Equatable {
    public let path: String
    public let success: Bool
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

/// Event requesting route handling
public struct RouteRequestedEvent: RuntimeEvent {
    public static var eventType: String { "route.requested" }
    public let timestamp: Date
    public let requestType: String
    public let router: String

    public init(requestType: String, router: String) {
        self.timestamp = Date()
        self.requestType = requestType
        self.router = router
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

    /// Wait for shutdown signal (blocks until signaled)
    public func waitForShutdown() async {
        // Quick check before setting up continuation
        if checkShuttingDown() {
            return
        }

        let id = UUID()

        // Use withUnsafeContinuation for proper blocking
        await withUnsafeContinuation { (continuation: UnsafeContinuation<Void, Never>) in
            let shouldWait = self.registerWaiter(id: id) {
                continuation.resume()
            }

            if !shouldWait {
                continuation.resume()
            }
        }
    }

    /// Signal shutdown to all waiting tasks
    public func signalShutdown() {
        lock.lock()
        isShuttingDown = true
        let waiting = waiters
        waiters.removeAll()
        lock.unlock()

        for (_, resume) in waiting {
            resume()
        }
    }

    /// Reset for new application run
    public func reset() {
        lock.lock()
        isShuttingDown = false
        waiters.removeAll()
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

        // Get port from literal or context
        if let portValue = context.resolveAny("_literal_") as? Int {
            port = portValue
        } else if let portStr = context.resolveAny("_literal_") as? String, let p = Int(portStr) {
            port = p
        } else {
            // Try to find port in specifiers
            if let portSpec = object.specifiers.dropFirst().first, let p = Int(portSpec) {
                port = p
            } else {
                port = 8080 // default
            }
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

        #if !os(Windows)
        // Try socket server service
        if let socketServer = context.service(SocketServerService.self) {
            let dataToSend: Data
            if let d = data as? Data {
                dataToSend = d
            } else if let s = data as? String {
                dataToSend = s.data(using: .utf8) ?? Data()
            } else {
                dataToSend = String(describing: data).data(using: .utf8) ?? Data()
            }

            try await socketServer.broadcast(data: dataToSend)
            return BroadcastResult(success: true, clientCount: -1) // Count not available
        }
        #endif

        // Emit broadcast event
        context.emit(BroadcastRequestedEvent(data: String(describing: data)))

        return BroadcastResult(success: true, clientCount: 0)
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
