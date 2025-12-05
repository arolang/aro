// ============================================================
// RuntimeBridge.swift
// AROCRuntime - C-callable Runtime Interface
// ============================================================

import Foundation
import AROParser
import ARORuntime

// MARK: - Runtime Handle

/// Opaque runtime handle for C interop
final class AROCRuntimeHandle {
    let runtime: Runtime
    var contexts: [UnsafeMutableRawPointer: AROCContextHandle] = [:]

    init() {
        self.runtime = Runtime()
    }
}

/// Opaque context handle for C interop
final class AROCContextHandle {
    let context: RuntimeContext
    let runtime: AROCRuntimeHandle

    init(runtime: AROCRuntimeHandle, featureSetName: String) {
        self.runtime = runtime
        self.context = RuntimeContext(featureSetName: featureSetName)
    }
}

// MARK: - Global Storage

/// Global storage for runtime handles (prevents deallocation)
/// Using nonisolated(unsafe) as this is protected by handleLock
nonisolated(unsafe) private var runtimeHandles: [UnsafeMutableRawPointer: AROCRuntimeHandle] = [:]
private let handleLock = NSLock()

// MARK: - Runtime Lifecycle

/// Initialize the ARO runtime
/// - Returns: Opaque pointer to runtime handle
@_cdecl("aro_runtime_init")
public func aro_runtime_init() -> UnsafeMutableRawPointer? {
    let handle = AROCRuntimeHandle()
    let pointer = Unmanaged.passRetained(handle).toOpaque()

    handleLock.lock()
    runtimeHandles[pointer] = handle
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
    handleLock.unlock()

    Unmanaged<AROCRuntimeHandle>.fromOpaque(ptr).release()
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

/// Load plugins from a directory
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
