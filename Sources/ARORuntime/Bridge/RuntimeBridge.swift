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
        #endif
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
    handle.runtime.register(service: InMemoryRepositoryStorage.shared as RepositoryStorageService)

    #if !os(Windows)
    // Register file system service for file operations and monitoring
    let fileSystemService = AROFileSystemService(eventBus: handle.runtime.eventBus)
    handle.runtime.register(service: fileSystemService as FileSystemService)
    handle.runtime.register(service: fileSystemService as FileMonitorService)

    // NOTE: Do NOT register AROSocketServer (NIO-based) in compiled binaries.
    // We cannot wire up event handlers in binary mode, so use native BSD socket server instead.

    // NOTE: Do NOT register AROHTTPServer (NIO-based) in compiled binaries.
    // But we keep it registered here for backward compatibility with the interpreter mode
    // when accessed via aro_runtime_init. The BridgeRuntimeContext init skips HTTPServer.
    // Register HTTP server service for web APIs
    let httpServer = AROHTTPServer(eventBus: handle.runtime.eventBus)
    handle.runtime.register(service: httpServer as HTTPServerService)
    #endif

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
        // CRITICAL: Run compiled handler on a GCD thread, NOT on Swift's cooperative executor.
        // Compiled handlers call aro_action_* functions which use semaphore.wait() internally.
        // If these block executor threads, we get deadlock on Linux where the executor has limited threads.
        // By dispatching to GCD (which has many threads), we ensure blocking doesn't starve the executor.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                // Create a context for the handler
                let contextHandle = AROCContextHandle(runtime: runtimeHandle, featureSetName: "handler")

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

                // Clean up result if needed
                if let resultPtr = result {
                    aro_value_free(resultPtr)
                }

                // Clean up context
                Unmanaged<AROCContextHandle>.fromOpaque(contextPtr).release()

                // Resume the async continuation
                continuation.resume()
            }
        }
    }
}

/// Register a repository observer for compiled binaries
/// This function subscribes to RepositoryChangedEvent for the specified repository
/// and calls the observer function when events occur
@_cdecl("aro_register_repository_observer")
public func aro_register_repository_observer(
    _ runtimePtr: UnsafeMutableRawPointer?,
    _ repositoryNamePtr: UnsafePointer<CChar>?,
    _ observerFuncPtr: UnsafeMutableRawPointer?
) {
    guard let runtimePtr = runtimePtr,
          let repositoryNamePtr = repositoryNamePtr,
          let observerFuncPtr = observerFuncPtr else {
        print("[RuntimeBridge] ERROR: Invalid parameters to aro_register_repository_observer")
        return
    }

    let runtimeHandle = Unmanaged<AROCRuntimeHandle>.fromOpaque(runtimePtr).takeUnretainedValue()
    let repositoryName = String(cString: repositoryNamePtr)

    // Capture observer pointer as Int (Sendable) for use in closure
    let observerAddress = Int(bitPattern: observerFuncPtr)

    // Subscribe to RepositoryChangedEvent for this repository
    runtimeHandle.runtime.eventBus.subscribe(to: RepositoryChangedEvent.self) { event in
        guard event.repositoryName == repositoryName else { return }

        // CRITICAL: Run compiled observer on a GCD thread, NOT on Swift's cooperative executor.
        // Same reasoning as aro_runtime_register_handler - avoid deadlock from semaphore blocking.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                // Create event context with event data
                let contextHandle = AROCContextHandle(
                    runtime: runtimeHandle,
                    featureSetName: "\(repositoryName) Observer"
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

                // Clean up result if needed
                if let resultPtr = result {
                    aro_value_free(resultPtr)
                }

                // Clean up context
                Unmanaged<AROCContextHandle>.fromOpaque(contextPtr).release()

                // Resume the async continuation
                continuation.resume()
            }
        }
    }
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

    // Parse and evaluate the expression
    guard let data = jsonStr.data(using: .utf8),
          let parsed = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
        return
    }

    let result = evaluateExpressionJSON(parsed, context: contextHandle.context)
    contextHandle.context.bind("_expression_", value: result)
}

/// Recursively evaluate a JSON-encoded expression
private func evaluateExpressionJSON(_ expr: [String: Any], context: RuntimeContext) -> any Sendable {
    // Literal value
    if let lit = expr["$lit"] {
        return convertToSendable(lit)
    }

    // Variable reference (with optional specifiers)
    if let varName = expr["$var"] as? String {
        var value = context.resolveAny(varName) ?? ""

        // Handle specifiers for expressions like <user: active>
        if let specs = expr["$specs"] as? [String] {
            for spec in specs {
                if let dict = value as? [String: any Sendable], let propVal = dict[spec] {
                    value = propVal
                } else {
                    return "" // Property not found
                }
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

    return ""
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

    // Logical
    case "and":
        return asBool(left) && asBool(right)

    case "or":
        return asBool(left) || asBool(right)

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
                let varName = String(current[..<endRange.lowerBound])
                current = String(current[endRange.upperBound...])

                // Resolve variable from context
                if let value = contextHandle.context.resolveAny(varName) {
                    result += "\(value)"
                }
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

/// Load plugins from a directory (compiles if needed - for interpreter use)
/// - Parameter dirPath: Path to the directory containing the plugins/ folder
/// - Returns: 0 on success, non-zero on failure
@_cdecl("aro_load_plugins")
public func aro_load_plugins(_ dirPath: UnsafePointer<CChar>?) -> Int32 {
    guard let dirPath = dirPath else { return -1 }

    let directory = URL(fileURLWithPath: String(cString: dirPath))

    do {
        try PluginLoader.shared.loadPlugins(from: directory)
        return 0
    } catch {
        print("[ARO] Plugin loading error: \(error)")
        return 1
    }
}

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
        try PluginLoader.shared.loadPrecompiledPlugins(relativeTo: resolvedURL)
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

    // Determine concurrency limit
    let maxConcurrency = concurrency > 0 ? Int(concurrency) : ProcessInfo.processInfo.activeProcessorCount

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

    // Use DispatchQueue for reliable parallel execution in compiled binaries
    let queue = DispatchQueue(label: "aro.parallel.foreach", attributes: .concurrent)
    let group = DispatchGroup()
    let semaphore = DispatchSemaphore(value: maxConcurrency)

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

        // Wait for available concurrency slot
        semaphore.wait()

        // Dispatch work
        group.enter()
        queue.async {
            defer {
                group.leave()
                semaphore.signal()
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
        }
    }

    // Wait for all work to complete
    group.wait()

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
