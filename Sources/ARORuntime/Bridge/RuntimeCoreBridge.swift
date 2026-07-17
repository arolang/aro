// ============================================================
// RuntimeCoreBridge.swift
// ARORuntime - C-callable Runtime Core (handles, lifecycle, value boxing)
// ============================================================
//
// After issue #313 this file owns the shared runtime plumbing that the other
// Runtime*Bridge files build on: the RuntimeError type, the feature-set
// metadata registry state, the opaque handles (AROCRuntimeHandle,
// AROCContextHandle), global handle storage (runtimeHandles, handleLock,
// globalRuntimePtr), the runtime lifecycle entry points (init/shutdown/plugin+
// argument loading/keep-alive/await-pending-events/log-warning, including
// .store seeding inside aro_runtime_init), and the AROCValue box plus its
// pure value accessors (free/create_int/as_string/string_concat/as_int/
// as_double). The interpolation/when-guard/match functions that used to sit in
// the Value Boxing section moved to RuntimeExecutionBridge.swift because they
// depend on the expression engine.
// Extracted from RuntimeBridge.swift (issue #313) — pure move, no behaviour change.

import Foundation
import AROParser

#if canImport(Darwin)
import CoreFoundation
#endif

#if !os(Windows)
import NIO
#endif

// MARK: - Runtime Errors

/// Runtime errors for compiled code execution
enum RuntimeError: Error {
    case contextCreationFailed(String)
    case invalidFunctionPointer(String)

    init(_ message: String) {
        self = .contextCreationFailed(message)
    }
}

// MARK: - Feature Set Metadata Registry

/// Global registry for feature set metadata (name -> business activity mapping)
/// Used in compiled binaries to determine business activity for HTTP handlers
/// NSLock provides thread safety, so we can mark as nonisolated(unsafe)
// #313: widened from `private` to internal — the feature-set metadata
// register/lookup functions now live in RuntimeExecutionBridge.swift.
nonisolated(unsafe) var featureSetMetadataLock = NSLock()
nonisolated(unsafe) var featureSetBusinessActivities: [String: String] = [:]

// MARK: - Runtime Handle

/// Opaque runtime handle for C interop
final class AROCRuntimeHandle: @unchecked Sendable {
    let runtime: Runtime
    var contexts: [UnsafeMutableRawPointer: AROCContextHandle] = [:]

    #if !os(Windows)
    /// Lazy event loop group - deferred until first access to avoid
    /// crash when created before Swift async runtime is ready
    lazy var eventLoopGroup: MultiThreadedEventLoopGroup = {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        EventLoopGroupManager.shared.registerGroup(group)
        return group
    }()

    /// Keyboard service shared across all contexts — must outlive individual handler contexts
    let keyboardService: KeyboardService
    /// Terminal service shared across all contexts — section state must persist between renders
    let terminalService: TerminalService?
    #endif

    init() {
        self.runtime = Runtime()
        #if !os(Windows)
        self.keyboardService = KeyboardService(eventBus: .shared)
        self.terminalService = isatty(STDOUT_FILENO) != 0 ? TerminalService() : nil
        #endif
        // Event loop creation deferred to lazy var - no eager init needed
    }

    deinit {
        // Event loop cleanup handled by EventLoopGroupManager.shutdownAll()
    }
}

/// Opaque context handle for C interop
class AROCContextHandle: @unchecked Sendable {
    let context: RuntimeContext
    let runtime: AROCRuntimeHandle

    /// Phase 2: per-invocation async driver channel.
    let driverChannel: ActionDriverChannel
    /// True when this handle created (and owns) the channel — close it in deinit.
    private let ownsDriverChannel: Bool

    /// Reused decoder for OpenAPI spec parsing during binary-mode init.
    private static let openAPIDecoder = JSONDecoder()

    #if !os(Windows)
    // Store service references to prevent deallocation
    let fileSystemService: AROFileSystemService?
    let socketServer: AROSocketServer?
    let httpServer: AROHTTPServer?
    let templateService: AROTemplateService?
    let terminalService: TerminalService?
    #endif

    deinit {
        if ownsDriverChannel {
            driverChannel.close()
        }
    }

    init(runtime: AROCRuntimeHandle, featureSetName: String) {
        self.runtime = runtime

        // Phase 2: create a per-invocation channel and start the cooperative driver task.
        let channel = ActionDriverChannel()
        self.driverChannel = channel
        self.ownsDriverChannel = true
        Task.detached { await ActionRunner.shared.driveFeatureSet(channel: channel) }

        // CRITICAL: Pass the eventBus from runtime to enable event emission in compiled binaries
        self.context = RuntimeContext(
            featureSetName: featureSetName,
            eventBus: runtime.runtime.eventBus,
            isCompiled: true,
            driverChannel: channel
        )

        // Register services in context (must match aro_runtime_init registration)
        self.context.register(InMemoryRepositoryStorage.shared as RepositoryStorageService)

        #if !os(Windows)
        // Create and register file system service
        let fs = AROFileSystemService(eventBus: runtime.runtime.eventBus)
        self.context.register(fs as FileSystemService)
        self.context.register(fs as FileMonitorService)
        self.fileSystemService = fs

        // NOTE: Do NOT register AROSocketServer (NIO-based) in compiled binaries.
        // Similar to HTTPServer, we cannot wire up event handlers in binary mode because
        // the ExecutionEngine's registerSocketEventHandlers() is not called.
        // Instead, compiled binaries use the native BSD socket server via
        // aro_native_socket_server_start() which is invoked in StartAction
        // when no SocketServerService is registered.
        self.socketServer = nil

        // NOTE: Do NOT register AROHTTPServer (NIO-based) in compiled binaries.
        // SwiftNIO crashes in compiled binaries because Swift's type metadata for NIO's
        // internal socket channel types is not properly available when the Swift runtime
        // is initialized from LLVM-compiled code. The crash occurs in _swift_allocObject_
        // with a null metadata pointer when NIO tries to create socket channels.
        //
        // Instead, compiled binaries use the native BSD socket HTTP server via
        // aro_native_http_server_start_with_openapi() which is invoked in StartAction
        // when no HTTPServerService is registered.
        self.httpServer = nil

        // Register template service (ARO-0050)
        // Resolve templates/ relative to the binary's own directory so the binary
        // works regardless of which directory it is invoked from.
        let executablePath = CommandLine.arguments[0]
        let binaryDir = ToolResolver.resolveExecutableDirectory(executablePath)
        let templatesDirectory = URL(fileURLWithPath: binaryDir).appendingPathComponent("templates").path
        let ts = AROTemplateService(templatesDirectory: templatesDirectory)
        let templateExecutor = TemplateExecutor(
            actionRegistry: ActionRegistry.shared,
            eventBus: .shared
        )
        ts.setExecutor(templateExecutor)
        self.context.register(ts as TemplateService)
        self.templateService = ts

        // Register terminal service for TTY output (ARO-0052)
        // ClearAction, RenderAction, ShowAction all require this service.
        // Use the shared instance from AROCRuntimeHandle so section state
        // persists across observer invocations (each gets a fresh context handle).
        if let sharedTerminal = runtime.terminalService {
            self.context.register(sharedTerminal)
            self.terminalService = sharedTerminal
        } else {
            self.terminalService = nil
        }

        // Register keyboard service — shared instance lives on the runtime handle
        // so it survives individual handler context release cycles
        self.context.register(runtime.keyboardService)

        // Set up schema registry for typed event extraction (ARO-0046)
        // Load openapi.yaml from the binary's directory if present
        Self.setupSchemaRegistry(for: self.context)
        #endif
    }

    /// Initializer that takes an existing context (for child contexts).
    /// Borrows the parent's driver channel so child action calls go through the same driver.
    init(runtime: AROCRuntimeHandle, existingContext: RuntimeContext) {
        self.runtime = runtime
        self.context = existingContext
        // Borrow channel from the existing context (propagated via createChild).
        // Do NOT start a new driver task — the parent's driver handles this too.
        if let ch = existingContext.driverChannel {
            self.driverChannel = ch
            self.ownsDriverChannel = false
        } else {
            let ch = ActionDriverChannel()
            self.driverChannel = ch
            self.ownsDriverChannel = true
            Task.detached { await ActionRunner.shared.driveFeatureSet(channel: ch) }
        }
        #if !os(Windows)
        self.fileSystemService = nil
        self.socketServer = nil
        self.httpServer = nil
        self.templateService = nil
        self.terminalService = nil
        #endif
    }

    /// Set up schema registry for typed event extraction (ARO-0046)
    /// Uses embedded spec (compiled into binary) or falls back to file loading
    private static func setupSchemaRegistry(for context: RuntimeContext) {
        var spec: OpenAPISpec? = nil

        // Priority 1: Use embedded spec (compiled into binary)
        // This is set by aro_set_embedded_openapi() called from generated main()
        if let embeddedJSON = embeddedOpenAPISpec {
            if let data = embeddedJSON.data(using: .utf8) {
                spec = try? openAPIDecoder.decode(OpenAPISpec.self, from: data)
            }
        }

        // Priority 2: Fall back to file loading (interpreter mode / development)
        if spec == nil {
            let executablePath = CommandLine.arguments[0]
            let binaryDir = ToolResolver.resolveExecutableDirectory(executablePath)
            let openapiPath = URL(fileURLWithPath: binaryDir).appendingPathComponent("openapi.yaml").path

            if FileManager.default.fileExists(atPath: openapiPath) {
                spec = try? OpenAPILoader.load(from: URL(fileURLWithPath: openapiPath))
            }
        }

        // Register schema registry if spec was loaded
        if let loadedSpec = spec {
            let registry = OpenAPISchemaRegistry(spec: loadedSpec)
            context.setSchemaRegistry(registry)
        }
    }

}

// MARK: - Global Storage

/// Global storage for runtime handles (prevents deallocation)
/// Using nonisolated(unsafe) as this is protected by handleLock
nonisolated(unsafe) private var runtimeHandles: [UnsafeMutableRawPointer: AROCRuntimeHandle] = [:]
// #313: widened from `private` to internal — the context-management functions
// (create/child/destroy) now live in RuntimeExecutionBridge.swift and guard
// `runtimeHandle.contexts` with this same lock.
let handleLock = NSLock()

/// Global runtime pointer for use by services (HTTP server, etc.)
/// Set during aro_runtime_init(), cleared during aro_runtime_shutdown()
nonisolated(unsafe) public var globalRuntimePtr: UnsafeMutableRawPointer?

// MARK: - Runtime Lifecycle

/// Initialize the ARO runtime
/// - Returns: Opaque pointer to runtime handle
@_cdecl("aro_runtime_init")
public func aro_runtime_init() -> UnsafeMutableRawPointer? {
    let handle = AROCRuntimeHandle()
    let pointer = Unmanaged.passRetained(handle).toOpaque()

    // Register default services (same as Application.registerDefaultServices)
    // Use semaphore pattern to bridge sync @_cdecl to async actor methods
    let semaphore = DispatchSemaphore(value: 0)

    // Start metrics collection for compiled binaries
    // This enables <Log> the <metrics: table> to the <console>
    MetricsCollector.shared.start(eventBus: handle.runtime.eventBus)

    Task.detached {
        await handle.runtime.register(service: InMemoryRepositoryStorage.shared as RepositoryStorageService)

        #if !os(Windows)
        // Register file system service for file operations and monitoring
        let fileSystemService = AROFileSystemService(eventBus: handle.runtime.eventBus)
        await handle.runtime.register(service: fileSystemService as FileSystemService)
        await handle.runtime.register(service: fileSystemService as FileMonitorService)

        // NOTE: Do NOT register AROSocketServer (NIO-based) in compiled binaries.
        // We cannot wire up event handlers in binary mode, so use native BSD socket server instead.

        // NOTE: Do NOT register AROHTTPServer (NIO-based) in compiled binaries.
        // But we keep it registered here for backward compatibility with the interpreter mode
        // when accessed via aro_runtime_init. The BridgeRuntimeContext init skips HTTPServer.
        // Register HTTP server service for web APIs
        let httpServer = AROHTTPServer(eventBus: handle.runtime.eventBus)
        await handle.runtime.register(service: httpServer as HTTPServerService)
        #endif

        // Seed repositories from .store files (read-only in compiled binaries)
        let execPath = CommandLine.arguments[0]
        let binDir = ToolResolver.resolveExecutableDirectory(execPath)
        let storeLoader = StoreFileLoader()
        if let storeFiles = try? storeLoader.discover(in: URL(fileURLWithPath: binDir)) {
            let repoStorage = InMemoryRepositoryStorage.shared
            for descriptor in storeFiles {
                for entry in descriptor.entries {
                    await repoStorage.store(
                        value: entry as [String: any Sendable],
                        in: descriptor.repositoryName,
                        businessActivity: "store-seed"
                    )
                }
            }
        }

        semaphore.signal()
    }

    semaphore.wait()

    // Install SIGINT/SIGTERM handlers so Ctrl-C always terminates compiled binaries,
    // even for apps that don't use the Keepalive action.
    KeepaliveSignalHandler.shared.setup()

    handleLock.lock()
    runtimeHandles[pointer] = handle
    // Set global runtime for services to use
    globalRuntimePtr = UnsafeMutableRawPointer(pointer)
    handleLock.unlock()

    return UnsafeMutableRawPointer(pointer)
}

/// Shutdown the ARO runtime
/// - Parameter runtimePtr: Runtime handle from aro_runtime_init
@_cdecl("aro_runtime_shutdown")
public func aro_runtime_shutdown(_ runtimePtr: UnsafeMutableRawPointer?) {
    guard let ptr = runtimePtr else { return }

    handleLock.lock()
    if let handle = runtimeHandles.removeValue(forKey: ptr) {
        // Clean up all contexts
        for (contextPtr, _) in handle.contexts {
            Unmanaged<AROCContextHandle>.fromOpaque(contextPtr).release()
        }
        handle.runtime.stop()
    }
    // Clear global runtime if it matches
    if globalRuntimePtr == ptr {
        globalRuntimePtr = nil
    }
    handleLock.unlock()

    Unmanaged<AROCRuntimeHandle>.fromOpaque(ptr).release()
}

/// Load plugins from the application directory
/// - Parameter path: Path to the application directory (C string)
/// - Returns: 1 on success, 0 on failure
@_cdecl("aro_load_plugins")
public func aro_load_plugins(_ path: UnsafePointer<CChar>?) -> Int32 {
    guard let path = path else { return 0 }

    let pathString = String(cString: path)
    let directory = URL(fileURLWithPath: pathString)

    do {
        // UnifiedPluginLoader handles both managed Plugins/ and legacy plugins/ directories.
        // It passes managed plugin names to the legacy loader so they aren't double-loaded.
        try UnifiedPluginLoader.shared.loadPlugins(from: directory)

        return 1
    } catch {
        print("[aro_load_plugins] Failed to load plugins: \(error)")
        return 0
    }
}

/// Parse command-line arguments into ParameterStorage (ARO-0047)
/// - Parameters:
///   - argc: Argument count from main()
///   - argv: Argument vector from main()
@_cdecl("aro_parse_arguments")
public func aro_parse_arguments(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) {
    var args: [String] = []
    // Skip argv[0] (executable name)
    for i in 1..<Int(argc) {
        if let arg = argv?[i] {
            args.append(String(cString: arg))
        }
    }
    ParameterStorage.shared.parseArguments(args)
}

/// Check if --keep-alive flag was passed
/// - Returns: 1 if keep-alive flag is set, 0 otherwise
@_cdecl("aro_has_keep_alive")
public func aro_has_keep_alive() -> Int32 {
    return ParameterStorage.shared.has("keep-alive") ? 1 : 0
}

/// Wait for all in-flight event handlers to complete
/// - Parameters:
///   - runtimePtr: Runtime handle from aro_runtime_init
///   - timeout: Maximum time to wait in seconds (default: 10.0)
/// - Returns: 1 if all handlers completed, 0 if timeout occurred
@_cdecl("aro_runtime_await_pending_events")
public func aro_runtime_await_pending_events(_ runtimePtr: UnsafeMutableRawPointer?, _ timeout: Double) -> Int32 {
    guard let ptr = runtimePtr else { return 0 }

    let runtimeHandle = Unmanaged<AROCRuntimeHandle>.fromOpaque(ptr).takeUnretainedValue()

    // Use a thread-safe box to pass the result between async and sync contexts
    final class ResultBox: @unchecked Sendable {
        var completed: Bool = false
        let lock = NSLock()

        func set(_ value: Bool) {
            lock.lock()
            completed = value
            lock.unlock()
        }

        func get() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return completed
        }
    }

    let resultBox = ResultBox()
    let semaphore = DispatchSemaphore(value: 0)

    // Use Task.detached to ensure the task runs on the concurrent executor
    // rather than inheriting the current task context. This prevents deadlocks
    // on Linux where the default Task might try to use the blocked thread.
    //
    // Loops with stall detection so long-running cascades (e.g. a crawler
    // driven by fire-and-forget repository observers) aren't cut off after
    // the per-call timeout. Uses `isQuiescent` rather than the raw handler
    // count so we don't exit during the lull between fan-out waves while
    // fire-and-forget publishes are queued but haven't yet incremented
    // in-flight tracking. Bails only when the pending count stops decreasing
    // across two windows — that's the signal that work has stalled.
    Task.detached { @Sendable in
        var previousPending = -1
        var finalResult = true
        while true {
            let completed = await runtimeHandle.runtime.awaitPendingEvents(timeout: timeout)
            if completed { finalResult = true; break }
            if await runtimeHandle.runtime.isQuiescent() { finalResult = true; break }
            let pending = await runtimeHandle.runtime.getPendingHandlerCount()
            if pending == previousPending {
                finalResult = false
                break
            }
            previousPending = pending
        }
        resultBox.set(finalResult)
        semaphore.signal()
    }

    semaphore.wait()
    return resultBox.get() ? 1 : 0
}

/// Log a warning message from compiled code
/// - Parameter messagePtr: C string pointer to the warning message
@_cdecl("aro_log_warning")
public func aro_log_warning(_ messagePtr: UnsafePointer<CChar>?) {
    guard let messagePtr = messagePtr else { return }
    let message = String(cString: messagePtr)
    print("[ARO WARNING] \(message)")
}

// MARK: - Value Boxing

/// Boxed value for C interop
final class AROCValue: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: any Sendable
    var value: any Sendable { lock.withLock { _value } }
    /// Atomically replace the value (used to lazily upgrade LazyDirectoryList → PipelinedDirectoryIterator).
    func upgradeValue(_ newValue: any Sendable) { lock.withLock { _value = newValue } }

    init(value: any Sendable) { _value = value }

    /// The boxed value with any AROFuture transparently forced (Issue #55,
    /// phase 3). Use this from C ABI value-accessors so that a future
    /// stored as the box payload materializes before being inspected.
    /// Falls back to "" on force failure (matches resolveAny semantics).
    var materializedValue: any Sendable {
        let v = value
        if let future = v as? AROFuture {
            return (try? future.force()) ?? ""
        }
        return v
    }
}

/// Free a value returned by aro_variable_resolve
@_cdecl("aro_value_free")
public func aro_value_free(_ valuePtr: UnsafeMutableRawPointer?) {
    guard let ptr = valuePtr else { return }
    Unmanaged<AROCValue>.fromOpaque(ptr).release()
}

/// Create a boxed integer value
/// - Parameter value: Integer value
/// - Returns: Opaque pointer to value (must be freed with aro_value_free)
@_cdecl("aro_value_create_int")
public func aro_value_create_int(_ value: Int64) -> UnsafeMutableRawPointer {
    let boxed = AROCValue(value: Int(value))
    return Unmanaged.passRetained(boxed).toOpaque()
}

/// Get value as string
/// - Parameter valuePtr: Value handle
/// - Returns: C string (caller must free) or NULL
@_cdecl("aro_value_as_string")
public func aro_value_as_string(_ valuePtr: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>? {
    guard let ptr = valuePtr else { return nil }
    let boxed = Unmanaged<AROCValue>.fromOpaque(ptr).takeUnretainedValue()

    let v = boxed.materializedValue
    if let str = v as? String {
        return strdup(str)
    }
    return strdup(String(describing: v))
}

/// Concatenate two C strings and return the result
/// - Parameters:
///   - str1: First string
///   - str2: Second string
/// - Returns: New C string (caller must free) containing concatenation
@_cdecl("aro_string_concat")
public func aro_string_concat(
    _ str1: UnsafePointer<CChar>?,
    _ str2: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>? {
    let s1 = str1.map { String(cString: $0) } ?? ""
    let s2 = str2.map { String(cString: $0) } ?? ""
    return strdup(s1 + s2)
}

/// Get value as integer
/// - Parameters:
///   - valuePtr: Value handle
///   - outValue: Pointer to store result
/// - Returns: 1 if conversion succeeded, 0 if failed
@_cdecl("aro_value_as_int")
public func aro_value_as_int(
    _ valuePtr: UnsafeMutableRawPointer?,
    _ outValue: UnsafeMutablePointer<Int64>?
) -> Int32 {
    guard let ptr = valuePtr, let out = outValue else { return 0 }
    let boxed = Unmanaged<AROCValue>.fromOpaque(ptr).takeUnretainedValue()

    let v = boxed.materializedValue
    if let intVal = v as? Int {
        out.pointee = Int64(intVal)
        return 1
    }
    if let intVal = v as? Int64 {
        out.pointee = intVal
        return 1
    }
    return 0
}

/// Get value as double
/// - Parameters:
///   - valuePtr: Value handle
///   - outValue: Pointer to store result
/// - Returns: 1 if conversion succeeded, 0 if failed
@_cdecl("aro_value_as_double")
public func aro_value_as_double(
    _ valuePtr: UnsafeMutableRawPointer?,
    _ outValue: UnsafeMutablePointer<Double>?
) -> Int32 {
    guard let ptr = valuePtr, let out = outValue else { return 0 }
    let boxed = Unmanaged<AROCValue>.fromOpaque(ptr).takeUnretainedValue()

    let v = boxed.materializedValue
    if let doubleVal = v as? Double {
        out.pointee = doubleVal
        return 1
    }
    if let intVal = v as? Int {
        out.pointee = Double(intVal)
        return 1
    }
    return 0
}

