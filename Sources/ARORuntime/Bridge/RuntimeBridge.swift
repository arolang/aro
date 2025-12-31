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

// MARK: - Runtime Handle

/// Opaque runtime handle for C interop
final class AROCRuntimeHandle: @unchecked Sendable {
    let runtime: Runtime
    var contexts: [UnsafeMutableRawPointer: AROCContextHandle] = [:]

    #if !os(Windows)
    /// Shared event loop group for async I/O in compiled binaries
    let eventLoopGroup: MultiThreadedEventLoopGroup
    #endif

    init() {
        self.runtime = Runtime()
        #if !os(Windows)
        // Create event loop group for NIO-based async I/O
        self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        #endif
    }

    deinit {
        #if !os(Windows)
        try? eventLoopGroup.syncShutdownGracefully()
        #endif
    }
}

/// Opaque context handle for C interop
final class AROCContextHandle {
    let context: RuntimeContext
    let runtime: AROCRuntimeHandle

    init(runtime: AROCRuntimeHandle, featureSetName: String) {
        self.runtime = runtime
        // CRITICAL: Pass the eventBus from runtime to enable event emission in compiled binaries
        self.context = RuntimeContext(
            featureSetName: featureSetName,
            eventBus: runtime.runtime.eventBus,
            isCompiled: true
        )
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

    Task { @Sendable in
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
private func resolveValue(_ value: Any, context: RuntimeContext) -> Any {
    if let str = value as? String, str.hasPrefix("$ref:") {
        let varName = String(str.dropFirst(5))  // Remove "$ref:" prefix
        if let resolved = context.resolveAny(varName) {
            return resolved
        } else {
            return value  // Return original if not found
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
    case let bool as Bool:
        return bool
    // Check for actual CFBoolean type to distinguish from NSNumber integers
    // CFBoolean is a distinct type for true/false in JSON, NSNumber(1) is an integer
    case let nsNumber as NSNumber:
        let objCType = String(cString: nsNumber.objCType)
        #if canImport(Darwin)
        // On Darwin, check if it's actually a boolean type (CFBoolean)
        if CFGetTypeID(nsNumber) == CFBooleanGetTypeID() {
            return nsNumber.boolValue
        }
        #else
        // On Linux, NSNumber from JSON booleans have objCType "c" (char)
        // and values 0 or 1, but we can't reliably distinguish from small integers.
        // Use objCType check: "c" with 0/1 suggests boolean, but this is heuristic.
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
        if let l = asDouble(left), let r = asDouble(right) {
            return l < r
        }
        return false

    case ">":
        if let l = asDouble(left), let r = asDouble(right) {
            return l > r
        }
        return false

    case "<=":
        if let l = asDouble(left), let r = asDouble(right) {
            return l <= r
        }
        return false

    case ">=":
        if let l = asDouble(left), let r = asDouble(right) {
            return l >= r
        }
        return false

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

    guard let value = contextHandle.context.resolveAny(nameStr) else { return nil }

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
    guard let ctxPtr = contextPtr,
          let nameStr = name.map({ String(cString: $0) }),
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
