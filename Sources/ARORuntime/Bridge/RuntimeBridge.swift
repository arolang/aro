// ============================================================
// RuntimeBridge.swift
// ARORuntime - C-callable Runtime Interface
// ============================================================
//
// This file provides C-callable functions for compiled ARO binaries.
// It exposes the Swift runtime functionality through @_cdecl exports.

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
    #endif

    init() {
        self.runtime = Runtime()
        // Event loop creation deferred to lazy var - no eager init needed
    }

    deinit {
        // Event loop cleanup handled by EventLoopGroupManager.shutdownAll()
    }
}

/// Opaque context handle for C interop
class AROCContextHandle {
    let context: RuntimeContext
    let runtime: AROCRuntimeHandle

    #if !os(Windows)
    // Store service references to prevent deallocation
    let fileSystemService: AROFileSystemService?
    let socketServer: AROSocketServer?
    let httpServer: AROHTTPServer?
    let templateService: AROTemplateService?
    #endif

    init(runtime: AROCRuntimeHandle, featureSetName: String) {
        self.runtime = runtime
        // CRITICAL: Pass the eventBus from runtime to enable event emission in compiled binaries
        self.context = RuntimeContext(
            featureSetName: featureSetName,
            eventBus: runtime.runtime.eventBus,
            isCompiled: true
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

        // Register template service (ARO-0045)
        let cwd = FileManager.default.currentDirectoryPath
        let templatesDirectory = (cwd as NSString).appendingPathComponent("templates")
        let ts = AROTemplateService(templatesDirectory: templatesDirectory)
        let templateExecutor = TemplateExecutor(
            actionRegistry: ActionRegistry.shared,
            eventBus: .shared
        )
        ts.setExecutor(templateExecutor)
        self.context.register(ts as TemplateService)
        self.templateService = ts

        // Set up schema registry for typed event extraction (ARO-0046)
        // Load openapi.yaml from the binary's directory if present
        Self.setupSchemaRegistry(for: self.context)
        #endif
    }

    /// Initializer that takes an existing context (for child contexts)
    init(runtime: AROCRuntimeHandle, existingContext: RuntimeContext) {
        self.runtime = runtime
        self.context = existingContext
        #if !os(Windows)
        self.fileSystemService = nil
        self.socketServer = nil
        self.httpServer = nil
        self.templateService = nil
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
                spec = try? JSONDecoder().decode(OpenAPISpec.self, from: data)
            }
        }

        // Priority 2: Fall back to file loading (interpreter mode / development)
        if spec == nil {
            let executablePath = CommandLine.arguments[0]
            let absolutePath: String
            if executablePath.hasPrefix("/") {
                absolutePath = executablePath
            } else {
                let cwd = FileManager.default.currentDirectoryPath
                absolutePath = (cwd as NSString).appendingPathComponent(executablePath)
            }

            let resolvedPath = (absolutePath as NSString).resolvingSymlinksInPath
            let binaryDir = (resolvedPath as NSString).deletingLastPathComponent
            let openapiPath = (binaryDir as NSString).appendingPathComponent("openapi.yaml")

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
private let handleLock = NSLock()

/// Global runtime pointer for use by services (HTTP server, etc.)
/// Set during aro_runtime_init(), cleared during aro_runtime_shutdown()
nonisolated(unsafe) public var globalRuntimePtr: UnsafeMutableRawPointer?

/// Global registry for compiled handler function names: eventType -> [handlerFunctionName]
/// TODO: This variable is currently unused - clarify if it's needed for future features or should be removed
nonisolated(unsafe) private var compiledHandlerRegistry: [String: [String]] = [:]

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

        semaphore.signal()
    }

    semaphore.wait()

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
        // Load legacy plugins from plugins/ directory
        try PluginLoader.shared.loadPlugins(from: directory)

        // Load managed plugins from Plugins/ directory (ARO-0045)
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
    Task.detached { @Sendable in
        let result = await runtimeHandle.runtime.awaitPendingEvents(timeout: timeout)
        resultBox.set(result)
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

/// Register a compiled event handler
/// - Parameters:
///   - runtimePtr: Runtime handle from aro_runtime_init
///   - eventType: Event type name (C string)
///   - handlerFuncName: Name of the compiled handler function (C string)
@_cdecl("aro_runtime_register_handler")
public func aro_runtime_register_handler(
    _ runtimePtr: UnsafeMutableRawPointer?,
    _ eventType: UnsafePointer<CChar>?,
    _ handlerFuncName: UnsafeMutableRawPointer?
) {
    guard let ptr = runtimePtr else { return }
    guard let eventTypeStr = eventType.map({ String(cString: $0) }) else { return }
    guard let handlerPtr = handlerFuncName else { return }

    let runtimeHandle = Unmanaged<AROCRuntimeHandle>.fromOpaque(ptr).takeUnretainedValue()

    // Capture handler pointer as Int (Sendable) for use in closure
    let handlerAddress = Int(bitPattern: handlerPtr)

    // Register the handler with the runtime
    // The handler function pointer will be called when events of this type are emitted
    runtimeHandle.runtime.registerCompiledHandler(
        eventType: eventTypeStr,
        handlerName: "compiled_handler"
    ) { @Sendable event in
        // CRITICAL: Run compiled handler on a pthread (Foundation Thread), NOT on GCD.
        // Compiled handlers call aro_action_* functions which use semaphore.wait() internally,
        // blocking the thread. GCD has a soft thread limit of 64 — recursive event chains
        // (emit -> handler -> emit -> ...) exhaust this limit because each level blocks a
        // GCD thread. Using pthreads avoids the GCD limit entirely; the gate still bounds
        // concurrent active execution to 4 * CPU count.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let pool = CompiledExecutionPool.shared
            Thread {
                pool.gate.wait()
                pool.threadHoldsSlot = true
                defer {
                    pool.threadHoldsSlot = false
                    pool.gate.signal()
                }

                // Track execution time for metrics
                let startTime = Date()
                let handlerName = "\(eventTypeStr) Handler"

                // Create a context for the handler
                let contextHandle = AROCContextHandle(runtime: runtimeHandle, featureSetName: handlerName)

                // Bind event payload to context
                contextHandle.context.bind("event", value: event.payload)
                for (key, value) in event.payload {
                    contextHandle.context.bind("event:\(key)", value: value)
                }

                // Get the context pointer
                let contextPtr = Unmanaged.passRetained(contextHandle).toOpaque()

                // Call the compiled handler function
                // The function signature is: ptr function(ptr context)
                // Convert Int back to pointer inside closure
                guard let handlerPtrReconstructed = UnsafeMutableRawPointer(bitPattern: handlerAddress) else {
                    print("[ARO Runtime] Error: Invalid handler pointer address: \(handlerAddress)")
                    // Clean up context before returning
                    Unmanaged<AROCContextHandle>.fromOpaque(contextPtr).release()
                    continuation.resume()
                    return
                }
                typealias HandlerFunc = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
                let handlerFunc = unsafeBitCast(handlerPtrReconstructed, to: HandlerFunc.self)
                let result = handlerFunc(contextPtr)

                // Emit FeatureSetCompletedEvent for metrics tracking
                let duration = Date().timeIntervalSince(startTime) * 1000
                runtimeHandle.runtime.eventBus.publish(FeatureSetCompletedEvent(
                    featureSetName: handlerName,
                    businessActivity: eventTypeStr,
                    executionId: contextHandle.context.executionId,
                    success: true,
                    durationMs: duration
                ))

                // Clean up result if needed
                if let resultPtr = result {
                    aro_value_free(resultPtr)
                }

                // Clean up context
                Unmanaged<AROCContextHandle>.fromOpaque(contextPtr).release()

                // Resume the async continuation
                continuation.resume()
            }.start()
        }
    }
}

/// Register a repository observer for compiled binaries with optional when condition
/// This function subscribes to RepositoryChangedEvent for the specified repository
/// and calls the observer function when events occur (if when condition passes)
@_cdecl("aro_register_repository_observer_with_guard")
public func aro_register_repository_observer_with_guard(
    _ runtimePtr: UnsafeMutableRawPointer?,
    _ repositoryNamePtr: UnsafePointer<CChar>?,
    _ observerFuncPtr: UnsafeMutableRawPointer?,
    _ whenConditionPtr: UnsafePointer<CChar>?
) {
    guard let runtimePtr = runtimePtr,
          let repositoryNamePtr = repositoryNamePtr,
          let observerFuncPtr = observerFuncPtr else {
        print("[RuntimeBridge] ERROR: Invalid parameters to aro_register_repository_observer_with_guard")
        return
    }

    let runtimeHandle = Unmanaged<AROCRuntimeHandle>.fromOpaque(runtimePtr).takeUnretainedValue()
    let repositoryName = String(cString: repositoryNamePtr)
    let whenCondition: String? = whenConditionPtr.map { String(cString: $0) }


    // Capture observer pointer as Int (Sendable) for use in closure
    let observerAddress = Int(bitPattern: observerFuncPtr)

    // Subscribe to RepositoryChangedEvent for this repository
    runtimeHandle.runtime.eventBus.subscribe(to: RepositoryChangedEvent.self) { event in
        guard event.repositoryName == repositoryName else { return }

        // If there's a when condition, evaluate it first
        if let condition = whenCondition, !condition.isEmpty {
            // Parse the when condition JSON
            guard let conditionData = condition.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: conditionData, options: []) as? [String: Any] else {
                return // Skip if can't parse condition
            }

            // Create a temporary context to evaluate the condition
            let tempContext = RuntimeContext(
                featureSetName: "\(repositoryName) Observer",
                businessActivity: "\(repositoryName) Observer",
                eventBus: runtimeHandle.runtime.eventBus
            )

            // Evaluate the condition
            let result = evaluateExpressionJSON(parsed, context: tempContext)

            // Check if result is truthy
            let conditionPassed: Bool
            if let boolVal = result as? Bool {
                conditionPassed = boolVal
            } else if let intVal = result as? Int {
                conditionPassed = intVal != 0
            } else {
                conditionPassed = false
            }

            if !conditionPassed {
                return // Skip observer if condition is false
            }
        }

        // CRITICAL: Run compiled observer on a pthread (Foundation Thread), NOT on GCD.
        // Same reasoning as aro_runtime_register_handler — pthreads avoid GCD's 64-thread
        // soft limit which is easily exhausted by recursive event chains.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let pool = CompiledExecutionPool.shared
            Thread {
                pool.gate.wait()
                pool.threadHoldsSlot = true
                defer {
                    pool.threadHoldsSlot = false
                    pool.gate.signal()
                }

                // Track execution time for metrics
                let startTime = Date()
                let observerName = "\(repositoryName) Observer"

                // Create event context with event data
                let contextHandle = AROCContextHandle(
                    runtime: runtimeHandle,
                    featureSetName: observerName
                )

                // Bind event as a dictionary with all properties
                // The Extract action will handle nested property access via specifiers
                var eventDict: [String: any Sendable] = [
                    "repositoryName": event.repositoryName,
                    "changeType": event.changeType.rawValue
                ]
                if let entityId = event.entityId {
                    eventDict["entityId"] = entityId
                }
                if let newValue = event.newValue {
                    eventDict["newValue"] = newValue
                }
                if let oldValue = event.oldValue {
                    eventDict["oldValue"] = oldValue
                }

                contextHandle.context.bind("event", value: eventDict)

                // Get context pointer
                let contextPtr = Unmanaged.passRetained(contextHandle).toOpaque()

                // Call observer function (compiled LLVM code)
                // The function signature is: ptr function(ptr context)
                guard let observerPtrReconstructed = UnsafeMutableRawPointer(bitPattern: observerAddress) else {
                    print("[RuntimeBridge] ERROR: Invalid observer pointer address: \(observerAddress)")
                    Unmanaged<AROCContextHandle>.fromOpaque(contextPtr).release()
                    continuation.resume()
                    return
                }

                typealias ObserverFunc = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
                let observerFunc = unsafeBitCast(observerPtrReconstructed, to: ObserverFunc.self)
                let result = observerFunc(contextPtr)

                // Emit FeatureSetCompletedEvent for metrics tracking
                let duration = Date().timeIntervalSince(startTime) * 1000
                runtimeHandle.runtime.eventBus.publish(FeatureSetCompletedEvent(
                    featureSetName: observerName,
                    businessActivity: "\(repositoryName) Observer",
                    executionId: contextHandle.context.executionId,
                    success: true,
                    durationMs: duration
                ))

                // Clean up result if needed
                if let resultPtr = result {
                    aro_value_free(resultPtr)
                }

                // Clean up context
                Unmanaged<AROCContextHandle>.fromOpaque(contextPtr).release()

                // Resume the async continuation
                continuation.resume()
            }.start()
        }
    }
}

/// Register a repository observer for compiled binaries (legacy, no when condition)
/// This function subscribes to RepositoryChangedEvent for the specified repository
/// and calls the observer function when events occur
@_cdecl("aro_register_repository_observer")
public func aro_register_repository_observer(
    _ runtimePtr: UnsafeMutableRawPointer?,
    _ repositoryNamePtr: UnsafePointer<CChar>?,
    _ observerFuncPtr: UnsafeMutableRawPointer?
) {
    // Delegate to the guarded version with no condition
    aro_register_repository_observer_with_guard(runtimePtr, repositoryNamePtr, observerFuncPtr, nil)
}

// MARK: - Context Management

/// Create an execution context
/// - Parameter runtimePtr: Runtime handle
/// - Returns: Opaque pointer to context handle
@_cdecl("aro_context_create")
public func aro_context_create(_ runtimePtr: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
    guard let ptr = runtimePtr else { return nil }

    let runtimeHandle = Unmanaged<AROCRuntimeHandle>.fromOpaque(ptr).takeUnretainedValue()
    let contextHandle = AROCContextHandle(runtime: runtimeHandle, featureSetName: "compiled")
    let contextPtr = Unmanaged.passRetained(contextHandle).toOpaque()

    handleLock.lock()
    runtimeHandle.contexts[contextPtr] = contextHandle
    handleLock.unlock()

    return UnsafeMutableRawPointer(contextPtr)
}

/// Create a named execution context
/// - Parameters:
///   - runtimePtr: Runtime handle
///   - name: Feature set name (C string)
/// - Returns: Opaque pointer to context handle
@_cdecl("aro_context_create_named")
public func aro_context_create_named(
    _ runtimePtr: UnsafeMutableRawPointer?,
    _ name: UnsafePointer<CChar>?
) -> UnsafeMutableRawPointer? {
    guard let ptr = runtimePtr else { return nil }
    let featureSetName = name.map { String(cString: $0) } ?? "compiled"

    let runtimeHandle = Unmanaged<AROCRuntimeHandle>.fromOpaque(ptr).takeUnretainedValue()
    let contextHandle = AROCContextHandle(runtime: runtimeHandle, featureSetName: featureSetName)
    let contextPtr = Unmanaged.passRetained(contextHandle).toOpaque()

    handleLock.lock()
    runtimeHandle.contexts[contextPtr] = contextHandle
    handleLock.unlock()

    return UnsafeMutableRawPointer(contextPtr)
}

/// Create a child execution context from a parent context
/// - Parameters:
///   - parentContextPtr: Parent context handle
///   - name: Feature set name (C string, optional)
/// - Returns: Opaque pointer to child context handle
@_cdecl("aro_context_create_child")
public func aro_context_create_child(
    _ parentContextPtr: UnsafeMutableRawPointer?,
    _ name: UnsafePointer<CChar>?
) -> UnsafeMutableRawPointer? {
    guard let parentPtr = parentContextPtr else { return nil }

    let parentHandle = Unmanaged<AROCContextHandle>.fromOpaque(parentPtr).takeUnretainedValue()
    let featureSetName = name.map { String(cString: $0) } ?? parentHandle.context.featureSetName

    // Create child context from parent
    let childContext = parentHandle.context.createChild(featureSetName: featureSetName) as! RuntimeContext

    // Wrap in a handle with the existing context
    let childHandle = AROCContextHandle(runtime: parentHandle.runtime, existingContext: childContext)
    let childPtr = Unmanaged.passRetained(childHandle).toOpaque()

    handleLock.lock()
    parentHandle.runtime.contexts[childPtr] = childHandle
    handleLock.unlock()

    return UnsafeMutableRawPointer(childPtr)
}

/// Destroy an execution context
/// - Parameter contextPtr: Context handle
@_cdecl("aro_context_destroy")
public func aro_context_destroy(_ contextPtr: UnsafeMutableRawPointer?) {
    guard let ptr = contextPtr else { return }

    let contextHandle = Unmanaged<AROCContextHandle>.fromOpaque(ptr).takeUnretainedValue()

    handleLock.lock()
    contextHandle.runtime.contexts.removeValue(forKey: ptr)
    handleLock.unlock()

    Unmanaged<AROCContextHandle>.fromOpaque(ptr).release()
}

/// Print the response from the context (for compiled binaries)
/// - Parameter contextPtr: Context handle
@_cdecl("aro_context_print_response")
public func aro_context_print_response(_ contextPtr: UnsafeMutableRawPointer?) {
    guard let ptr = contextPtr else { return }

    let contextHandle = Unmanaged<AROCContextHandle>.fromOpaque(ptr).takeUnretainedValue()

    if let response = contextHandle.context.getResponse() {
        // Use human-readable format for CLI output
        print(response.format(for: .human))
    }
}

/// Check if the context has an execution error
/// - Parameter contextPtr: Context handle
/// - Returns: 1 if there's an error, 0 otherwise
@_cdecl("aro_context_has_error")
public func aro_context_has_error(_ contextPtr: UnsafeMutableRawPointer?) -> Int32 {
    guard let ptr = contextPtr else { return 0 }

    let contextHandle = Unmanaged<AROCContextHandle>.fromOpaque(ptr).takeUnretainedValue()
    return contextHandle.context.hasExecutionError() ? 1 : 0
}

/// Print the execution error from the context (for compiled binaries)
/// - Parameter contextPtr: Context handle
@_cdecl("aro_context_print_error")
public func aro_context_print_error(_ contextPtr: UnsafeMutableRawPointer?) {
    guard let ptr = contextPtr else { return }

    let contextHandle = Unmanaged<AROCContextHandle>.fromOpaque(ptr).takeUnretainedValue()

    if let error = contextHandle.context.getExecutionError() {
        // Format error message similar to interpreter
        if let actionError = error as? ActionError {
            switch actionError {
            case .thrown(let type, let reason, _):
                // Match interpreter format: "Runtime error: Runtime Error: Cannot throw the <Type> for the <reason> when <condition>."
                print("Runtime error: Runtime Error: Cannot throw the \(type) for the \(reason) when <condition>.")
            case .runtimeError(let message):
                // The error message might be from ActionError.thrown that was stringified
                // Format: "<type> in <context>: <reason>"
                // We need to convert it to: "Runtime Error: Cannot throw the <type> for the <reason> when <condition>."
                if let match = parseThrowErrorMessage(message) {
                    print("Runtime error: Runtime Error: Cannot throw the \(match.type) for the \(match.reason) when <condition>.")
                } else {
                    print("Runtime error: \(message)")
                }
            default:
                print("Runtime error: \(error.localizedDescription)")
            }
        } else {
            print("Runtime error: \(error.localizedDescription)")
        }
    }
}

/// Parse a throw error message in format "<type> in <context>: <reason>"
/// Returns the type and reason components, or nil if format doesn't match
private func parseThrowErrorMessage(_ message: String) -> (type: String, reason: String)? {
    // Pattern: "<type> in <context>: <reason>"
    // Example: "InputError in Application-Start: negative-value"
    guard let inRange = message.range(of: " in "),
          let colonRange = message.range(of: ": ", range: inRange.upperBound..<message.endIndex) else {
        return nil
    }

    let type = String(message[..<inRange.lowerBound])
    let reason = String(message[colonRange.upperBound...])

    return (type: type, reason: reason)
}

// MARK: - Variable Binding

/// Bind a string variable in the context
/// - Parameters:
///   - contextPtr: Context handle
///   - name: Variable name (C string)
///   - value: Variable value (C string)
@_cdecl("aro_variable_bind_string")
public func aro_variable_bind_string(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ name: UnsafePointer<CChar>?,
    _ value: UnsafePointer<CChar>?
) {
    guard let ptr = contextPtr,
          let nameStr = name.map({ String(cString: $0) }),
          let valueStr = value.map({ String(cString: $0) }) else { return }

    let contextHandle = Unmanaged<AROCContextHandle>.fromOpaque(ptr).takeUnretainedValue()
    contextHandle.context.bind(nameStr, value: valueStr)
}

/// Bind an integer variable in the context
/// - Parameters:
///   - contextPtr: Context handle
///   - name: Variable name (C string)
///   - value: Integer value
@_cdecl("aro_variable_bind_int")
public func aro_variable_bind_int(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ name: UnsafePointer<CChar>?,
    _ value: Int64
) {
    guard let ptr = contextPtr,
          let nameStr = name.map({ String(cString: $0) }) else { return }

    let contextHandle = Unmanaged<AROCContextHandle>.fromOpaque(ptr).takeUnretainedValue()
    contextHandle.context.bind(nameStr, value: Int(value))
}

/// Bind a double variable in the context
/// - Parameters:
///   - contextPtr: Context handle
///   - name: Variable name (C string)
///   - value: Double value
@_cdecl("aro_variable_bind_double")
public func aro_variable_bind_double(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ name: UnsafePointer<CChar>?,
    _ value: Double
) {
    guard let ptr = contextPtr,
          let nameStr = name.map({ String(cString: $0) }) else { return }

    let contextHandle = Unmanaged<AROCContextHandle>.fromOpaque(ptr).takeUnretainedValue()
    contextHandle.context.bind(nameStr, value: value)
}

/// Bind a boolean variable in the context
/// - Parameters:
///   - contextPtr: Context handle
///   - name: Variable name (C string)
///   - value: Boolean value (0 = false, non-zero = true)
@_cdecl("aro_variable_bind_bool")
public func aro_variable_bind_bool(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ name: UnsafePointer<CChar>?,
    _ value: Int32
) {
    guard let ptr = contextPtr,
          let nameStr = name.map({ String(cString: $0) }) else { return }

    let contextHandle = Unmanaged<AROCContextHandle>.fromOpaque(ptr).takeUnretainedValue()
    contextHandle.context.bind(nameStr, value: value != 0)
}

/// Bind a dictionary variable in the context (from JSON string)
/// - Parameters:
///   - contextPtr: Context handle
///   - name: Variable name (C string)
///   - json: JSON object string (e.g., '{"key": "value"}')
@_cdecl("aro_variable_bind_dict")
public func aro_variable_bind_dict(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ name: UnsafePointer<CChar>?,
    _ json: UnsafePointer<CChar>?
) {
    guard let ptr = contextPtr,
          let nameStr = name.map({ String(cString: $0) }),
          let jsonStr = json.map({ String(cString: $0) }) else { return }

    let contextHandle = Unmanaged<AROCContextHandle>.fromOpaque(ptr).takeUnretainedValue()

    // Parse JSON to dictionary
    guard let data = jsonStr.data(using: .utf8),
          let parsed = try? JSONSerialization.jsonObject(with: data, options: []),
          let dict = parsed as? [String: Any] else {
        // Fallback: bind as string (JSON parse failed)
        contextHandle.context.bind(nameStr, value: jsonStr)
        return
    }

    // Resolve $ref: prefixed values (variable references)
    let resolvedDict = resolveReferences(dict, context: contextHandle.context)

    // Convert to Sendable dictionary
    let sendableDict = convertToSendable(resolvedDict) as? [String: any Sendable] ?? [:]
    contextHandle.context.bind(nameStr, value: sendableDict)
}

/// Resolve $ref:varname values in a dictionary by looking up the variable in context
private func resolveReferences(_ dict: [String: Any], context: RuntimeContext) -> [String: Any] {
    var result: [String: Any] = [:]
    for (key, value) in dict {
        result[key] = resolveValue(value, context: context)
    }
    return result
}

/// Resolve a single value, replacing $ref:varname with actual variable values
/// Supports dot notation for nested properties: $ref:update-data.name
private func resolveValue(_ value: Any, context: RuntimeContext) -> Any {
    if let str = value as? String, str.hasPrefix("$ref:") {
        let varPath = String(str.dropFirst(5))  // Remove "$ref:" prefix

        // Handle dot notation for nested properties: update-data.name -> resolve update-data, then get "name"
        let parts = varPath.split(separator: ".")
        guard !parts.isEmpty else { return value }

        // Resolve the base variable
        var resolved: Any? = context.resolveAny(String(parts[0]))

        // Navigate through nested properties
        for part in parts.dropFirst() {
            if let dict = resolved as? [String: Any] {
                resolved = dict[String(part)]
            } else if let sendableDict = resolved as? [String: any Sendable] {
                resolved = sendableDict[String(part)]
            } else {
                resolved = nil
                break
            }
        }

        if let result = resolved {
            return result
        } else {
            // Property not found - return NSNull to signal missing value
            // This allows downstream code to handle missing properties appropriately
            return NSNull()
        }
    } else if let subDict = value as? [String: Any] {
        return resolveReferences(subDict, context: context)
    } else if let array = value as? [Any] {
        return array.map { resolveValue($0, context: context) }
    }
    return value
}

/// Bind an array variable in the context (from JSON string)
/// - Parameters:
///   - contextPtr: Context handle
///   - name: Variable name (C string)
///   - json: JSON array string (e.g., '["a", "b", "c"]')
@_cdecl("aro_variable_bind_array")
public func aro_variable_bind_array(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ name: UnsafePointer<CChar>?,
    _ json: UnsafePointer<CChar>?
) {
    guard let ptr = contextPtr,
          let nameStr = name.map({ String(cString: $0) }),
          let jsonStr = json.map({ String(cString: $0) }) else { return }

    let contextHandle = Unmanaged<AROCContextHandle>.fromOpaque(ptr).takeUnretainedValue()

    // Parse JSON to array
    guard let data = jsonStr.data(using: .utf8),
          let parsed = try? JSONSerialization.jsonObject(with: data, options: []),
          let array = parsed as? [Any] else {
        // Fallback: bind as string
        contextHandle.context.bind(nameStr, value: jsonStr)
        return
    }

    // Convert to Sendable array
    let sendableArray = array.map { convertToSendable($0) }
    contextHandle.context.bind(nameStr, value: sendableArray)
}

/// Convert Any to Sendable recursively
private func convertToSendable(_ value: Any) -> any Sendable {
    switch value {
    case let str as String:
        return str
    // IMPORTANT: Check NSNumber BEFORE Bool
    // On macOS, CFBoolean (used for JSON true/false) is a subclass of NSNumber
    // and can match both cases. We need to check NSNumber first and use type info
    // to distinguish between boolean CFBoolean and numeric NSNumber
    case let nsNumber as NSNumber:
        let objCType = String(cString: nsNumber.objCType)
        #if canImport(Darwin)
        // On Darwin, CFBoolean has objCType "c" (signed char) and is for true/false
        // NSNumber integers also use various types like "q" (long long), "i" (int), etc.
        // Check CFBooleanGetTypeID to definitively identify JSON booleans
        if CFGetTypeID(nsNumber) == CFBooleanGetTypeID() {
            // This is a JSON boolean (true/false), not an integer
            return nsNumber.boolValue
        }
        #else
        // On Linux, JSONSerialization uses objCType "c" (signed char) for booleans
        // We need to check if it's in boolean range (0 or 1) to distinguish from
        // actual signed char integers
        if objCType == "c" || objCType == "B" {
            let intVal = nsNumber.intValue
            if intVal == 0 || intVal == 1 {
                return nsNumber.boolValue
            }
        }
        #endif
        // Check if it has a decimal point (is a double)
        if objCType == "d" || objCType == "f" {
            return nsNumber.doubleValue
        }
        // Otherwise treat as integer
        return nsNumber.intValue
    case let bool as Bool:
        // This case should not be reached on macOS (CFBoolean is NSNumber)
        // But keep it for other platforms
        return bool
    case let dict as [String: Any]:
        var result: [String: any Sendable] = [:]
        for (k, v) in dict {
            result[k] = convertToSendable(v)
        }
        return result
    case let array as [Any]:
        return array.map { convertToSendable($0) }
    default:
        return String(describing: value)
    }
}

/// Copy a resolved value to the _expression_ variable
/// This is used when a variable reference is used in a with clause
/// - Parameters:
///   - contextPtr: Context handle
///   - valuePtr: Value handle from aro_variable_resolve
@_cdecl("aro_copy_value_to_expression")
public func aro_copy_value_to_expression(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ valuePtr: UnsafeMutableRawPointer?
) {
    guard let ptr = contextPtr else { return }

    let contextHandle = Unmanaged<AROCContextHandle>.fromOpaque(ptr).takeUnretainedValue()

    // If no value was resolved, don't bind anything
    guard let valPtr = valuePtr else { return }

    let boxed = Unmanaged<AROCValue>.fromOpaque(valPtr).takeUnretainedValue()

    // Bind the resolved value to _expression_
    contextHandle.context.bind("_expression_", value: boxed.value)
}

/// Evaluate a JSON-encoded expression and bind result to _expression_
/// JSON format:
///   {"$lit": value}           - literal value
///   {"$var": "name"}          - variable reference
///   {"$binary": {"op": "+", "left": {...}, "right": {...}}}  - binary expression
/// - Parameters:
///   - contextPtr: Context handle
///   - json: JSON-encoded expression
@_cdecl("aro_evaluate_expression")
public func aro_evaluate_expression(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ json: UnsafePointer<CChar>?
) {
    guard let ptr = contextPtr,
          let jsonStr = json.map({ String(cString: $0) }) else { return }

    let contextHandle = Unmanaged<AROCContextHandle>.fromOpaque(ptr).takeUnretainedValue()

    // Parse the JSON
    guard let data = jsonStr.data(using: .utf8),
          let parsed = try? JSONSerialization.jsonObject(with: data, options: []) else {
        return
    }

    // Handle arrays (e.g., JSON array literals)
    if let array = parsed as? [Any] {
        let result = evaluateJSONArray(array, context: contextHandle.context)
        contextHandle.context.bind("_expression_", value: result)
        return
    }

    // Handle dictionaries (expressions like {"$var": ...}, {"$lit": ...}, {"$binary": ...})
    guard let dict = parsed as? [String: Any] else {
        return
    }

    let result = evaluateExpressionJSON(dict, context: contextHandle.context)
    contextHandle.context.bind("_expression_", value: result)
}

/// Evaluate a JSON expression and bind to a specific variable name
/// - Parameters:
///   - contextPtr: Context handle
///   - varName: Variable name to bind the result to
///   - json: JSON-encoded expression
@_cdecl("aro_evaluate_and_bind")
public func aro_evaluate_and_bind(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ varName: UnsafePointer<CChar>?,
    _ json: UnsafePointer<CChar>?
) {
    guard let ptr = contextPtr,
          let nameStr = varName.map({ String(cString: $0) }),
          let jsonStr = json.map({ String(cString: $0) }) else { return }

    let contextHandle = Unmanaged<AROCContextHandle>.fromOpaque(ptr).takeUnretainedValue()

    // Parse the JSON
    guard let data = jsonStr.data(using: .utf8),
          let parsed = try? JSONSerialization.jsonObject(with: data, options: []) else {
        return
    }

    // Handle arrays
    if let array = parsed as? [Any] {
        let result = evaluateJSONArray(array, context: contextHandle.context)
        contextHandle.context.bind(nameStr, value: result)
        return
    }

    // Handle dictionaries
    guard let dict = parsed as? [String: Any] else {
        return
    }

    let result = evaluateExpressionJSON(dict, context: contextHandle.context)
    contextHandle.context.bind(nameStr, value: result)
}

/// Evaluate a JSON array by recursively evaluating each element
private func evaluateJSONArray(_ array: [Any], context: RuntimeContext) -> [any Sendable] {
    return array.map { element -> any Sendable in
        if let dict = element as? [String: Any] {
            // Check if it's an expression object
            if dict["$lit"] != nil || dict["$var"] != nil || dict["$binary"] != nil {
                return evaluateExpressionJSON(dict, context: context)
            }
            // Otherwise it's a plain object - evaluate its values recursively
            return evaluateJSONObject(dict, context: context)
        } else if let nestedArray = element as? [Any] {
            return evaluateJSONArray(nestedArray, context: context)
        } else {
            return convertToSendable(element)
        }
    }
}

/// Evaluate a JSON object by recursively evaluating its values
private func evaluateJSONObject(_ obj: [String: Any], context: RuntimeContext) -> [String: any Sendable] {
    var result: [String: any Sendable] = [:]
    for (key, value) in obj {
        if let dict = value as? [String: Any] {
            // Check if it's an expression object
            if dict["$lit"] != nil || dict["$var"] != nil || dict["$binary"] != nil {
                result[key] = evaluateExpressionJSON(dict, context: context)
            } else {
                // Plain nested object
                result[key] = evaluateJSONObject(dict, context: context)
            }
        } else if let array = value as? [Any] {
            result[key] = evaluateJSONArray(array, context: context)
        } else {
            result[key] = convertToSendable(value)
        }
    }
    return result
}

/// Recursively evaluate a JSON-encoded expression
private func evaluateExpressionJSON(_ expr: [String: Any], context: RuntimeContext) -> any Sendable {
    // Literal value
    if let lit = expr["$lit"] {
        return convertToSendable(lit)
    }

    // Variable reference (with optional specifiers)
    if let varName = expr["$var"] as? String {
        let specs = expr["$specs"] as? [String] ?? []

        // Special handling for repository count access: <repository-name: count>
        if specs == ["count"] && InMemoryRepositoryStorage.isRepositoryName(varName) {
            // Get count synchronously using the actor's sync count method
            let businessActivity = context.businessActivity
            return InMemoryRepositoryStorage.shared.countSync(
                repository: varName,
                businessActivity: businessActivity
            )
        }

        var value = context.resolveAny(varName) ?? ""

        // Handle specifiers for expressions like <user: active>
        for spec in specs {
            if let dict = value as? [String: any Sendable], let propVal = dict[spec] {
                value = propVal
            } else {
                return "" // Property not found
            }
        }
        return value
    }

    // Binary expression
    if let binary = expr["$binary"] as? [String: Any],
       let op = binary["op"] as? String,
       let leftExpr = binary["left"] as? [String: Any],
       let rightExpr = binary["right"] as? [String: Any] {

        let left = evaluateExpressionJSON(leftExpr, context: context)
        let right = evaluateExpressionJSON(rightExpr, context: context)

        return evaluateBinaryOp(op: op, left: left, right: right)
    }

    // Interpolated string: {"$interpolated":"Hello ${name}!"}
    if let template = expr["$interpolated"] as? String {
        return interpolateString(template, context: context)
    }

    // Object literal: {"key1": expr1, "key2": expr2, ...}
    // When no special marker is found, treat it as an object literal
    // and recursively evaluate each value
    if !expr.isEmpty && !expr.keys.contains(where: { $0.hasPrefix("$") }) {
        var result: [String: any Sendable] = [:]
        for (key, value) in expr {
            if let nestedDict = value as? [String: Any] {
                result[key] = evaluateExpressionJSON(nestedDict, context: context)
            } else if let nestedArray = value as? [Any] {
                result[key] = evaluateJSONArray(nestedArray, context: context)
            } else {
                result[key] = convertToSendable(value)
            }
        }
        return result
    }

    return ""
}

/// Interpolate a string template with ${varname} or ${<base: specifier>} placeholders
private func interpolateString(_ template: String, context: RuntimeContext) -> String {
    var result = ""
    var i = template.startIndex

    while i < template.endIndex {
        // Look for ${
        if template[i] == "$" {
            let nextIdx = template.index(after: i)
            if nextIdx < template.endIndex && template[nextIdx] == "{" {
                // Find the closing }
                var endIdx = template.index(after: nextIdx)
                while endIdx < template.endIndex && template[endIdx] != "}" {
                    endIdx = template.index(after: endIdx)
                }

                if endIdx < template.endIndex {
                    // Extract variable expression
                    let varStart = template.index(after: nextIdx)
                    let varExpr = String(template[varStart..<endIdx])

                    // Resolve with property access support
                    let resolved = resolveVariableExpression(varExpr, context: context)
                    result += resolved

                    // Move past the closing }
                    i = template.index(after: endIdx)
                    continue
                }
            }
        }

        result.append(template[i])
        i = template.index(after: i)
    }

    return result
}

/// Resolve a variable expression, handling property access syntax
/// Supports: varname, <varname>, <base: property>, <base: prop1: prop2>
private func resolveVariableExpression(_ expr: String, context: RuntimeContext) -> String {
    var varExpr = expr.trimmingCharacters(in: .whitespaces)

    // Handle <base: specifier> syntax
    if varExpr.hasPrefix("<") && varExpr.hasSuffix(">") {
        // Remove angle brackets
        varExpr = String(varExpr.dropFirst().dropLast())

        // Parse base and specifiers (split by ": ")
        let parts = varExpr.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        let base = parts[0]
        let specifiers = parts.count > 1 ? parts[1].split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces) } : []

        // Resolve base variable
        guard var value = context.resolveAny(base) else {
            return ""  // Variable not found
        }

        // Navigate through property path
        for specifier in specifiers {
            if let dict = value as? [String: any Sendable], let nested = dict[specifier] {
                value = nested
            } else if let dict = value as? [String: Any], let nested = dict[specifier] {
                value = nested as! any Sendable
            } else {
                return ""  // Property not found
            }
        }

        return stringValue(value)
    }

    // Simple variable reference
    if let value = context.resolveAny(varExpr) {
        return stringValue(value)
    }

    return ""
}

/// Convert any value to its string representation
private func stringValue(_ value: any Sendable) -> String {
    switch value {
    case let s as String:
        return s
    case let i as Int:
        return String(i)
    case let d as Double:
        if d.truncatingRemainder(dividingBy: 1) == 0 {
            return String(Int(d))
        }
        return String(d)
    case let b as Bool:
        return b ? "true" : "false"
    case let arr as [any Sendable]:
        let items = arr.map { stringValue($0) }.joined(separator: ", ")
        return "[\(items)]"
    case let dict as [String: any Sendable]:
        let items = dict.map { "\($0.key): \(stringValue($0.value))" }.joined(separator: ", ")
        return "{\(items)}"
    default:
        return String(describing: value)
    }
}

/// Evaluate a binary operation
private func evaluateBinaryOp(op: String, left: any Sendable, right: any Sendable) -> any Sendable {
    switch op {
    // Arithmetic
    case "+":
        if let l = asDouble(left), let r = asDouble(right) {
            // Preserve int type if both are ints
            if let li = left as? Int, let ri = right as? Int {
                return li + ri
            }
            return l + r
        }
        return 0

    case "-":
        if let l = asDouble(left), let r = asDouble(right) {
            if let li = left as? Int, let ri = right as? Int {
                return li - ri
            }
            return l - r
        }
        return 0

    case "*":
        if let l = asDouble(left), let r = asDouble(right) {
            if let li = left as? Int, let ri = right as? Int {
                return li * ri
            }
            return l * r
        }
        return 0

    case "/":
        if let l = asDouble(left), let r = asDouble(right), r != 0 {
            if let li = left as? Int, let ri = right as? Int, li % ri == 0 {
                return li / ri
            }
            return l / r
        }
        return 0

    case "%":
        if let li = left as? Int, let ri = right as? Int, ri != 0 {
            return li % ri
        }
        return 0

    // String concatenation
    case "++":
        let l = asString(left)
        let r = asString(right)
        return l + r

    // Comparison
    case "==", "is":
        // "is" is used for equality comparison with true/false
        if let lb = left as? Bool, let rb = right as? Bool {
            return lb == rb
        }
        return asString(left) == asString(right)

    case "!=", "isNot":
        if let lb = left as? Bool, let rb = right as? Bool {
            return lb != rb
        }
        return asString(left) != asString(right)

    case "<":
        // Try date comparison first (ARO-0041)
        if let leftDate = parseARODate(left), let rightDate = parseARODate(right) {
            return leftDate.date < rightDate.date
        }
        if let l = asDouble(left), let r = asDouble(right) {
            return l < r
        }
        // Fallback to string comparison (works for ISO 8601 dates)
        return asString(left) < asString(right)

    case ">":
        // Try date comparison first (ARO-0041)
        if let leftDate = parseARODate(left), let rightDate = parseARODate(right) {
            return leftDate.date > rightDate.date
        }
        if let l = asDouble(left), let r = asDouble(right) {
            return l > r
        }
        // Fallback to string comparison (works for ISO 8601 dates)
        return asString(left) > asString(right)

    case "<=":
        // Try date comparison first (ARO-0041)
        if let leftDate = parseARODate(left), let rightDate = parseARODate(right) {
            return leftDate.date <= rightDate.date
        }
        if let l = asDouble(left), let r = asDouble(right) {
            return l <= r
        }
        // Fallback to string comparison (works for ISO 8601 dates)
        return asString(left) <= asString(right)

    case ">=":
        // Try date comparison first (ARO-0041)
        if let leftDate = parseARODate(left), let rightDate = parseARODate(right) {
            return leftDate.date >= rightDate.date
        }
        if let l = asDouble(left), let r = asDouble(right) {
            return l >= r
        }
        // Fallback to string comparison (works for ISO 8601 dates)
        return asString(left) >= asString(right)

    // String containment
    case "contains":
        let leftStr = asString(left)
        let rightStr = asString(right)
        return leftStr.contains(rightStr)

    // Logical
    case "and":
        return asBool(left) && asBool(right)

    case "or":
        return asBool(left) || asBool(right)

    // Containment
    case "contains":
        if let array = left as? [any Sendable] {
            let rightStr = asString(right)
            return array.contains { asString($0) == rightStr }
        }
        if let str = left as? String, let substr = right as? String {
            return str.contains(substr)
        }
        if let dict = left as? [String: any Sendable], let key = right as? String {
            return dict[key] != nil
        }
        return false

    // Regex matching
    case "matches":
        let str = asString(left)
        let pattern = asString(right)
        do {
            let regex = try NSRegularExpression(pattern: pattern)
            let range = NSRange(str.startIndex..., in: str)
            return regex.firstMatch(in: str, range: range) != nil
        } catch {
            return false
        }

    default:
        return ""
    }
}

/// Convert value to Double for arithmetic
private func asDouble(_ value: any Sendable) -> Double? {
    switch value {
    case let i as Int: return Double(i)
    case let d as Double: return d
    case let s as String: return Double(s)
    default: return nil
    }
}

/// Convert value to String
private func asString(_ value: any Sendable) -> String {
    switch value {
    case let s as String: return s
    case let i as Int: return String(i)
    case let d as Double:
        // Format nicely - no trailing zeros
        if d == floor(d) {
            return String(Int(d))
        }
        return String(format: "%.2f", d)
    case let b as Bool: return b ? "true" : "false"
    default: return String(describing: value)
    }
}

/// Convert value to Bool
private func asBool(_ value: any Sendable) -> Bool {
    switch value {
    case let b as Bool: return b
    case let i as Int: return i != 0
    case let s as String: return s.lowercased() == "true"
    default: return false
    }
}

/// Parse a value as an ARODate (ARO-0041)
/// Handles ARODate objects and ISO8601 date strings
private func parseARODate(_ value: any Sendable) -> ARODate? {
    if let date = value as? ARODate {
        return date
    }
    if let str = value as? String {
        return try? ARODate.parse(str)
    }
    return nil
}

/// Resolve a variable from the context
/// - Parameters:
///   - contextPtr: Context handle
///   - name: Variable name (C string)
/// - Returns: Opaque pointer to value (must be freed with aro_value_free)
@_cdecl("aro_variable_resolve")
public func aro_variable_resolve(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ name: UnsafePointer<CChar>?
) -> UnsafeMutableRawPointer? {
    guard let ptr = contextPtr,
          let nameStr = name.map({ String(cString: $0) }) else { return nil }

    let contextHandle = Unmanaged<AROCContextHandle>.fromOpaque(ptr).takeUnretainedValue()

    guard let value = contextHandle.context.resolveAny(nameStr) else {
        // Debug: Log when resolving end-date fails (ARO-0041 diagnostics)
        if nameStr == "end-date" && ProcessInfo.processInfo.environment["ARO_DEBUG"] != nil {
            FileHandle.standardError.write("[RuntimeBridge] DEBUG: aro_variable_resolve(end-date) returned nil - variable not bound\n".data(using: .utf8)!)
        }
        return nil
    }

    // Wrap value in a box
    let boxedValue = AROCValue(value: value)
    return UnsafeMutableRawPointer(Unmanaged.passRetained(boxedValue).toOpaque())
}

/// Resolve a string variable from the context
/// - Parameters:
///   - contextPtr: Context handle
///   - name: Variable name (C string)
/// - Returns: C string (caller must free) or NULL
@_cdecl("aro_variable_resolve_string")
public func aro_variable_resolve_string(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ name: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>? {
    guard let ptr = contextPtr,
          let nameStr = name.map({ String(cString: $0) }) else { return nil }

    let contextHandle = Unmanaged<AROCContextHandle>.fromOpaque(ptr).takeUnretainedValue()

    guard let value: String = contextHandle.context.resolve(nameStr) else { return nil }

    return strdup(value)
}

/// Resolve an integer variable from the context
/// - Parameters:
///   - contextPtr: Context handle
///   - name: Variable name (C string)
///   - outValue: Pointer to store the result
/// - Returns: 1 if found, 0 if not found
@_cdecl("aro_variable_resolve_int")
public func aro_variable_resolve_int(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ name: UnsafePointer<CChar>?,
    _ outValue: UnsafeMutablePointer<Int64>?
) -> Int32 {
    guard let ptr = contextPtr,
          let nameStr = name.map({ String(cString: $0) }),
          let out = outValue else { return 0 }

    let contextHandle = Unmanaged<AROCContextHandle>.fromOpaque(ptr).takeUnretainedValue()

    guard let value: Int = contextHandle.context.resolve(nameStr) else { return 0 }

    out.pointee = Int64(value)
    return 1
}

// MARK: - Value Boxing

/// Boxed value for C interop
final class AROCValue {
    let value: any Sendable

    init(value: any Sendable) {
        self.value = value
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

    if let str = boxed.value as? String {
        return strdup(str)
    }
    return strdup(String(describing: boxed.value))
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

/// Interpolate a string template with variables from context
/// Replaces ${variable} placeholders with resolved values
/// Supports property access syntax: ${<base: property>} or ${base}
/// - Parameters:
///   - contextPtr: Execution context handle
///   - templatePtr: String template with ${...} placeholders
/// - Returns: Interpolated C string (caller must free)
@_cdecl("aro_interpolate_string")
public func aro_interpolate_string(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ templatePtr: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>? {
    guard let ptr = contextPtr, let templateStr = templatePtr.map({ String(cString: $0) }) else {
        return strdup("")
    }


    let contextHandle = Unmanaged<AROCContextHandle>.fromOpaque(ptr).takeUnretainedValue()

    // Parse and interpolate the template
    var result = ""
    var current = templateStr

    while !current.isEmpty {
        // Find next ${
        if let startRange = current.range(of: "${") {
            // Add literal part before ${
            result += current[..<startRange.lowerBound]
            current = String(current[startRange.upperBound...])

            // Find matching }
            if let endRange = current.range(of: "}") {
                let varExpr = String(current[..<endRange.lowerBound])
                current = String(current[endRange.upperBound...])

                // Resolve variable with property access support
                let resolved = resolveInterpolationExpression(varExpr, context: contextHandle.context)
                result += resolved
            } else {
                // No closing }, treat as literal
                result += "${"
            }
        } else {
            // No more interpolations
            result += current
            break
        }
    }

    return strdup(result)
}

/// Resolve an interpolation expression, handling property access syntax
/// Supports: ${varname}, ${<varname>}, ${<base: property>}, ${<base: prop1: prop2>}
private func resolveInterpolationExpression(_ expr: String, context: RuntimeContext) -> String {
    var varExpr = expr.trimmingCharacters(in: .whitespaces)

    // Handle <base: specifier> syntax
    if varExpr.hasPrefix("<") && varExpr.hasSuffix(">") {
        // Remove angle brackets
        varExpr = String(varExpr.dropFirst().dropLast())

        // Parse base and specifiers (split by ": ")
        let parts = varExpr.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        let base = parts[0]
        let specifiers = parts.count > 1 ? parts[1].split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces) } : []

        // Resolve base variable
        guard var value = context.resolveAny(base) else {
            return ""  // Variable not found
        }

        // Navigate through property path
        for specifier in specifiers {
            // Try [String: any Sendable] first
            if let dict = value as? [String: any Sendable], let nested = dict[specifier] {
                value = nested
            }
            // Also try [String: Any] for dictionaries from JSON parsing
            else if let dict = value as? [String: Any], let nested = dict[specifier] {
                value = nested as! any Sendable
            } else {
                return ""  // Property not found
            }
        }

        return formatInterpolatedValue(value)
    }

    // Simple variable reference
    if let value = context.resolveAny(varExpr) {
        return formatInterpolatedValue(value)
    }

    return ""
}

/// Format a value for string interpolation
private func formatInterpolatedValue(_ value: any Sendable) -> String {
    switch value {
    case let s as String:
        return s
    case let i as Int:
        return String(i)
    case let d as Double:
        if d.truncatingRemainder(dividingBy: 1) == 0 {
            return String(Int(d))
        }
        return String(d)
    case let b as Bool:
        return b ? "true" : "false"
    default:
        return String(describing: value)
    }
}

/// Evaluate a when guard condition
/// - Parameters:
///   - contextPtr: Execution context handle
///   - guardJSON: JSON-encoded guard expression
/// - Returns: 1 if condition is true, 0 if false
@_cdecl("aro_evaluate_when_guard")
public func aro_evaluate_when_guard(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ guardJSON: UnsafePointer<CChar>?
) -> Int32 {
    guard let ptr = contextPtr,
          let jsonStr = guardJSON.map({ String(cString: $0) }) else {
        return 0
    }

    let contextHandle = Unmanaged<AROCContextHandle>.fromOpaque(ptr).takeUnretainedValue()

    // Parse the guard expression
    guard let data = jsonStr.data(using: .utf8),
          let parsed = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
        return 0
    }

    // Evaluate the expression
    let result = evaluateExpressionJSON(parsed, context: contextHandle.context)

    // Check if result is truthy
    if let boolVal = result as? Bool {
        return boolVal ? 1 : 0
    }
    if let intVal = result as? Int {
        return intVal != 0 ? 1 : 0
    }
    if let strVal = result as? String {
        return !strVal.isEmpty ? 1 : 0
    }

    // Non-nil value is truthy
    return 1
}

/// Evaluate if a match case pattern matches the subject value
/// - Parameters:
///   - contextPtr: Execution context handle
///   - subjectNameJSON: JSON-encoded subject variable name
///   - patternJSON: JSON-encoded pattern to match
/// - Returns: 1 if pattern matches, 0 if not
@_cdecl("aro_match_pattern")
public func aro_match_pattern(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ subjectNameJSON: UnsafePointer<CChar>?,
    _ patternJSON: UnsafePointer<CChar>?
) -> Int32 {
    guard let ptr = contextPtr,
          let subjectStr = subjectNameJSON.map({ String(cString: $0) }),
          let patternStr = patternJSON.map({ String(cString: $0) }) else {
        return 0
    }

    let contextHandle = Unmanaged<AROCContextHandle>.fromOpaque(ptr).takeUnretainedValue()

    // Parse subject name and pattern JSON
    guard let subjectData = subjectStr.data(using: .utf8),
          let patternData = patternStr.data(using: .utf8),
          let subjectInfo = try? JSONSerialization.jsonObject(with: subjectData, options: []) as? [String: Any],
          let patternInfo = try? JSONSerialization.jsonObject(with: patternData, options: []) as? [String: Any] else {
        return 0
    }

    // Get subject value from context
    guard let subjectName = subjectInfo["name"] as? String,
          let subjectValue = contextHandle.context.resolveAny(subjectName) else {
        return 0
    }

    // Match based on pattern type
    guard let patternType = patternInfo["type"] as? String else {
        return 0
    }

    switch patternType {
    case "literal":
        // Compare with literal value
        if let literalValue = patternInfo["value"] {
            return valuesEqual(subjectValue, literalValue) ? 1 : 0
        }
        return 0

    case "wildcard":
        // Wildcard matches everything
        return 1

    case "variable":
        // Variable pattern - bind and match
        if let varName = patternInfo["name"] as? String,
           let varValue = contextHandle.context.resolveAny(varName) {
            return valuesEqual(subjectValue, varValue) ? 1 : 0
        }
        return 0

    case "regex":
        // Regex pattern matching
        guard let pattern = patternInfo["pattern"] as? String,
              let stringValue = subjectValue as? String else {
            return 0
        }
        let flags = patternInfo["flags"] as? String ?? ""
        var options: NSRegularExpression.Options = []
        if flags.contains("i") { options.insert(.caseInsensitive) }
        if flags.contains("m") { options.insert(.anchorsMatchLines) }

        do {
            let regex = try NSRegularExpression(pattern: pattern, options: options)
            let range = NSRange(stringValue.startIndex..., in: stringValue)
            return regex.firstMatch(in: stringValue, options: [], range: range) != nil ? 1 : 0
        } catch {
            return 0
        }

    default:
        return 0
    }
}

/// Helper function to compare two values for equality
private func valuesEqual(_ lhs: Any, _ rhs: Any) -> Bool {
    // String comparison
    if let l = lhs as? String, let r = rhs as? String {
        return l == r
    }
    // Integer comparison (handle various int types)
    if let l = lhs as? Int {
        if let r = rhs as? Int { return l == r }
        if let r = rhs as? Int64 { return Int64(l) == r }
        if let r = rhs as? Double { return Double(l) == r }
    }
    if let l = lhs as? Int64 {
        if let r = rhs as? Int64 { return l == r }
        if let r = rhs as? Int { return l == Int64(r) }
        if let r = rhs as? Double { return Double(l) == r }
    }
    // Double comparison
    if let l = lhs as? Double, let r = rhs as? Double {
        return l == r
    }
    // Boolean comparison
    if let l = lhs as? Bool, let r = rhs as? Bool {
        return l == r
    }
    // Fallback to string comparison
    return String(describing: lhs) == String(describing: rhs)
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

    if let intVal = boxed.value as? Int {
        out.pointee = Int64(intVal)
        return 1
    }
    if let intVal = boxed.value as? Int64 {
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

    if let doubleVal = boxed.value as? Double {
        out.pointee = doubleVal
        return 1
    }
    if let intVal = boxed.value as? Int {
        out.pointee = Double(intVal)
        return 1
    }
    return 0
}

// MARK: - Event Emission

/// Emit a custom event
/// - Parameters:
///   - contextPtr: Context handle
///   - eventType: Event type name (C string)
///   - data: Event data (C string, JSON format)
@_cdecl("aro_emit_event")
public func aro_emit_event(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ eventType: UnsafePointer<CChar>?,
    _ data: UnsafePointer<CChar>?
) {
    guard let ptr = contextPtr,
          let eventTypeStr = eventType.map({ String(cString: $0) }) else { return }

    let contextHandle = Unmanaged<AROCContextHandle>.fromOpaque(ptr).takeUnretainedValue()
    let dataStr = data.map { String(cString: $0) }

    contextHandle.context.emit(CustomRuntimeEvent(type: eventTypeStr, data: dataStr))
}

/// Custom event for C interop
struct CustomRuntimeEvent: RuntimeEvent {
    static var eventType: String { "custom" }
    let timestamp: Date
    let type: String
    let data: String?

    init(type: String, data: String?) {
        self.timestamp = Date()
        self.type = type
        self.data = data
    }
}

// MARK: - Plugin Loading

/// Load pre-compiled plugins relative to the binary's location
/// This is used by native compiled binaries - no compilation occurs at runtime
/// - Returns: 0 on success, non-zero on failure
@_cdecl("aro_load_precompiled_plugins")
public func aro_load_precompiled_plugins() -> Int32 {
    // Get the path to the current executable
    let executablePath = CommandLine.arguments[0]
    let executableURL: URL

    // Handle both absolute and relative paths
    if executablePath.hasPrefix("/") {
        executableURL = URL(fileURLWithPath: executablePath)
    } else {
        let cwd = FileManager.default.currentDirectoryPath
        executableURL = URL(fileURLWithPath: cwd).appendingPathComponent(executablePath)
    }

    // Resolve any symlinks to get the real path
    let resolvedURL = executableURL.resolvingSymlinksInPath()

    do {
        // Load local plugins from plugins/ directory
        try PluginLoader.shared.loadPrecompiledPlugins(relativeTo: resolvedURL)
        // Load managed plugins from Plugins/ directory
        try PluginLoader.shared.loadPrecompiledManagedPlugins(relativeTo: resolvedURL)
        return 0
    } catch {
        print("[ARO] Plugin loading error: \(error)")
        return 1
    }
}

// MARK: - Array/Collection Operations for ForEach

/// Get the count of elements in an array value
/// - Parameter valuePtr: Value handle (must be an array)
/// - Returns: Number of elements, or -1 if not an array
@_cdecl("aro_array_count")
public func aro_array_count(_ valuePtr: UnsafeMutableRawPointer?) -> Int64 {
    guard let ptr = valuePtr else { return -1 }
    let boxed = Unmanaged<AROCValue>.fromOpaque(ptr).takeUnretainedValue()

    if let array = boxed.value as? [any Sendable] {
        return Int64(array.count)
    }
    return -1
}

/// Get an element from an array value at the specified index
/// - Parameters:
///   - valuePtr: Value handle (must be an array)
///   - index: Zero-based index
/// - Returns: Value handle for the element (must be freed with aro_value_free), or NULL if out of bounds
@_cdecl("aro_array_get")
public func aro_array_get(
    _ valuePtr: UnsafeMutableRawPointer?,
    _ index: Int64
) -> UnsafeMutableRawPointer? {
    guard let ptr = valuePtr else { return nil }
    let boxed = Unmanaged<AROCValue>.fromOpaque(ptr).takeUnretainedValue()

    guard let array = boxed.value as? [any Sendable],
          index >= 0 && index < array.count else { return nil }

    let element = array[Int(index)]
    let boxedElement = AROCValue(value: element)
    return UnsafeMutableRawPointer(Unmanaged.passRetained(boxedElement).toOpaque())
}

/// Bind a value to a variable name in the context
/// - Parameters:
///   - contextPtr: Context handle
///   - name: Variable name (C string)
///   - valuePtr: Value handle from aro_array_get or aro_variable_resolve
@_cdecl("aro_variable_bind_value")
public func aro_variable_bind_value(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ name: UnsafePointer<CChar>?,
    _ valuePtr: UnsafeMutableRawPointer?
) {
    // Debug: Log when binding _to_ to help diagnose ARO-0041 issues
    let nameStr = name.map { String(cString: $0) }
    if nameStr == "_to_" && ProcessInfo.processInfo.environment["ARO_DEBUG"] != nil {
        let hasValue = valuePtr != nil
        FileHandle.standardError.write("[RuntimeBridge] DEBUG: aro_variable_bind_value(_to_) called, valuePtr=\(hasValue ? "valid" : "NULL")\n".data(using: .utf8)!)
    }

    guard let ctxPtr = contextPtr,
          let nameStr,
          let valPtr = valuePtr else { return }

    let contextHandle = Unmanaged<AROCContextHandle>.fromOpaque(ctxPtr).takeUnretainedValue()
    let boxed = Unmanaged<AROCValue>.fromOpaque(valPtr).takeUnretainedValue()

    contextHandle.context.bind(nameStr, value: boxed.value)
}

/// Unbind a variable from the context (for loop variable rebinding)
/// - Parameters:
///   - contextPtr: Context handle
///   - name: Variable name (C string)
@_cdecl("aro_variable_unbind")
public func aro_variable_unbind(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ name: UnsafePointer<CChar>?
) {
    guard let ctxPtr = contextPtr,
          let nameStr = name.map({ String(cString: $0) }) else { return }

    let contextHandle = Unmanaged<AROCContextHandle>.fromOpaque(ctxPtr).takeUnretainedValue()
    contextHandle.context.unbind(nameStr)
}

/// Get a property from a dictionary value
/// - Parameters:
///   - valuePtr: Value handle (must be a dictionary)
///   - property: Property name (C string)
/// - Returns: Value handle for the property (must be freed with aro_value_free), or NULL if not found
@_cdecl("aro_dict_get")
public func aro_dict_get(
    _ valuePtr: UnsafeMutableRawPointer?,
    _ property: UnsafePointer<CChar>?
) -> UnsafeMutableRawPointer? {
    guard let ptr = valuePtr,
          let propStr = property.map({ String(cString: $0) }) else { return nil }

    let boxed = Unmanaged<AROCValue>.fromOpaque(ptr).takeUnretainedValue()

    if let dict = boxed.value as? [String: any Sendable],
       let value = dict[propStr] {
        let boxedValue = AROCValue(value: value)
        return UnsafeMutableRawPointer(Unmanaged.passRetained(boxedValue).toOpaque())
    }

    return nil
}

/// Execute a parallel for-each loop with true concurrency
/// - Parameters:
///   - runtimePtr: Runtime handle
///   - contextPtr: Parent context handle
///   - collectionPtr: Array value handle
///   - loopBodyFn: Function pointer for loop body: (context, item, index) -> ptr
///   - concurrency: Maximum concurrent tasks (0 = System.coreCount)
///   - itemVarName: Variable name for loop item (C string)
///   - indexVarName: Variable name for loop index (C string), or NULL if none
/// - Returns: 0 on success, -1 on error
@_cdecl("aro_parallel_for_each_execute")
public func aro_parallel_for_each_execute(
    _ runtimePtr: UnsafeMutableRawPointer?,
    _ contextPtr: UnsafeMutableRawPointer?,
    _ collectionPtr: UnsafeMutableRawPointer?,
    _ loopBodyFn: UnsafeMutableRawPointer?,
    _ concurrency: Int64,
    _ itemVarName: UnsafePointer<CChar>?,
    _ indexVarName: UnsafePointer<CChar>?
) -> Int32 {
    guard runtimePtr != nil,
          let ctxPtr = contextPtr,
          let collPtr = collectionPtr,
          let bodyFn = loopBodyFn else {
        return -1
    }

    // Get collection as array
    let boxed = Unmanaged<AROCValue>.fromOpaque(collPtr).takeUnretainedValue()
    guard let items = boxed.value as? [any Sendable] else {
        return -1
    }

    // Convert pointers to Int addresses for concurrent capture
    let ctxAddress = Int(bitPattern: ctxPtr)
    let bodyFnAddress = Int(bitPattern: bodyFn)

    // Function pointer type definition
    typealias LoopBodyFunc = @convention(c) (
        UnsafeMutableRawPointer?,  // context
        UnsafeMutableRawPointer?,  // item
        Int64                       // index
    ) -> UnsafeMutableRawPointer?

    // Thread-safe error tracking
    final class ErrorBox: @unchecked Sendable {
        var error: Error?
        let lock = NSLock()

        func setError(_ err: Error) {
            lock.lock()
            defer { lock.unlock() }
            if error == nil {
                error = err
            }
        }

        func getError() -> Error? {
            lock.lock()
            defer { lock.unlock() }
            return error
        }
    }

    let errorBox = ErrorBox()

    // Use the global execution pool to prevent GCD thread pool exhaustion.
    // Each iteration may block its thread via semaphore.wait() when calling
    // aro_action_* functions. The global gate limits total concurrent compiled
    // code to 4 * CPU count, and the yield pattern in executeSyncWithResult
    // releases slots while blocked, allowing other work to proceed.
    //
    // The localLimit caps in-flight iterations (dispatched + blocked) to prevent
    // GCD thread exhaustion. Recursive event chains (emit -> handler -> emit -> ...)
    // create blocked GCD threads at each level. With branching factor B and depth D,
    // total threads grow as ~B^D. A small localLimit (2) keeps this manageable:
    // depth 5 ≈ 375 threads, well within GCD's ~512 limit.
    // Unlike the gate, localLimit is only released when an iteration COMPLETES,
    // not when it yields — this bounds total GCD threads per loop.
    let pool = CompiledExecutionPool.shared
    let localLimit = DispatchSemaphore(value: 2)
    let group = DispatchGroup()

    // Yield our gate slot for the duration of the parallel-for-each.
    // The calling thread just dispatches work and waits — it doesn't need
    // a gate slot. Freeing it allows iterations and handlers to use it.
    let hadSlot = pool.threadHoldsSlot
    if hadSlot {
        pool.gate.signal()
        pool.threadHoldsSlot = false
    }

    for (index, item) in items.enumerated() {
        // Reconstruct context pointer
        guard let parentCtxPtr = UnsafeMutableRawPointer(bitPattern: ctxAddress) else {
            print("[ARO] Invalid context pointer")
            return -1
        }

        // Create child context for this iteration
        let childCtxPtr = aro_context_create_child(parentCtxPtr, nil)
        guard let childPtr = childCtxPtr else {
            print("[ARO] Failed to create child context")
            return -1
        }

        // Box the item value
        let itemBoxed = AROCValue(value: item)
        let itemPtr = UnsafeMutableRawPointer(
            Unmanaged.passRetained(itemBoxed).toOpaque()
        )

        // Convert to Int addresses for concurrent capture
        let childAddress = Int(bitPattern: childPtr)
        let itemAddress = Int(bitPattern: itemPtr)

        // Local limit caps total in-flight iterations to prevent thread explosion
        localLimit.wait()
        // Global gate bounds concurrent compiled code execution
        pool.gate.wait()

        // Dispatch work on a pthread (Foundation Thread) to avoid GCD's 64-thread limit.
        // Each iteration may block its thread via semaphore.wait() when calling
        // aro_action_* functions; pthreads don't count against GCD's dispatch limit.
        group.enter()
        Thread {
            pool.threadHoldsSlot = true
            defer {
                pool.threadHoldsSlot = false
                pool.gate.signal()
                localLimit.signal()
                group.leave()
            }

            // Reconstruct pointers
            guard let fnPtr = UnsafeMutableRawPointer(bitPattern: bodyFnAddress),
                  let childCtx = UnsafeMutableRawPointer(bitPattern: childAddress),
                  let itemValue = UnsafeMutableRawPointer(bitPattern: itemAddress) else {
                errorBox.setError(RuntimeError("Invalid pointer reconstruction"))
                return
            }

            let fn = unsafeBitCast(fnPtr, to: LoopBodyFunc.self)

            // Call loop body function
            let result = fn(childCtx, itemValue, Int64(index))

            // Clean up
            if let resultPtr = result {
                aro_value_free(resultPtr)
            }
            Unmanaged<AROCValue>.fromOpaque(itemValue).release()
            aro_context_destroy(childCtx)
        }.start()
    }

    // Wait for all iterations to complete
    group.wait()

    // Re-acquire gate slot if we had one before the loop
    if hadSlot {
        pool.gate.wait()
        pool.threadHoldsSlot = true
    }

    // Check for errors
    if let error = errorBox.getError() {
        print("[ARO] Parallel loop error: \(error)")
        return -1
    }

    return 0
}

/// Evaluate a filter expression (where clause) for a value
/// - Parameters:
///   - contextPtr: Context handle
///   - filterJSON: JSON-encoded filter expression
/// - Returns: 1 if filter passes, 0 if not
@_cdecl("aro_evaluate_filter")
public func aro_evaluate_filter(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ filterJSON: UnsafePointer<CChar>?
) -> Int32 {
    guard let ptr = contextPtr,
          let jsonStr = filterJSON.map({ String(cString: $0) }) else { return 0 }

    let contextHandle = Unmanaged<AROCContextHandle>.fromOpaque(ptr).takeUnretainedValue()

    // Parse and evaluate the expression
    guard let data = jsonStr.data(using: .utf8),
          let parsed = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
        return 0
    }

    let result = evaluateExpressionJSON(parsed, context: contextHandle.context)

    // Convert result to bool
    if let b = result as? Bool {
        return b ? 1 : 0
    }
    if let i = result as? Int {
        return i != 0 ? 1 : 0
    }
    if let s = result as? String {
        return s.lowercased() == "true" ? 1 : 0
    }

    return 0
}
