// ============================================================
// RuntimeExecutionBridge.swift
// ARORuntime - C-callable execution: context, expressions, iteration
// ============================================================
//
// Owns the C-ABI bridge for running compiled feature-set bodies: context
// management (create/named/child/destroy, feature-set metadata register/lookup,
// published-variable binding, terminal binding), variable binding + reference
// resolution, the JSON expression-evaluation engine (with the stack guard),
// string interpolation, when-guard and match-pattern evaluation, variable
// resolution and specifier access, custom event emission, precompiled plugin
// loading, array/collection iteration for for-each (streaming and parallel
// variants), and mutable-scope entry/exit for while loops. `bindTerminalToContext`
// and `evaluateExpressionJSON` are widened to internal here so
// RuntimeEventRecordingBridge.swift can share them.
// Extracted from RuntimeBridge.swift (issue #313) — pure move, no behaviour change.

import Foundation
import AROParser

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
    guard let childContext = parentHandle.context.createChild(featureSetName: featureSetName) as? RuntimeContext else {
        return nil
    }

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

/// Register feature set metadata (name -> business activity mapping)
/// Called from generated main() to populate the registry for HTTP routing
/// - Parameters:
///   - featureSetNamePtr: Feature set name C string
///   - businessActivityPtr: Business activity C string (NULL for empty)
@_cdecl("aro_register_feature_set_metadata")
public func aro_register_feature_set_metadata(
    _ featureSetNamePtr: UnsafePointer<CChar>?,
    _ businessActivityPtr: UnsafePointer<CChar>?
) {
    guard let namePtr = featureSetNamePtr else { return }

    let name = String(cString: namePtr)
    let businessActivity = businessActivityPtr.map { String(cString: $0) } ?? ""

    featureSetMetadataLock.lock()
    featureSetBusinessActivities[name] = businessActivity
    featureSetMetadataLock.unlock()
}

/// Lookup business activity for a feature set
/// - Parameter featureSetNamePtr: Feature set name C string
/// - Returns: Business activity C string (caller must free) or NULL if not found
@_cdecl("aro_lookup_business_activity")
public func aro_lookup_business_activity(_ featureSetNamePtr: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    guard let namePtr = featureSetNamePtr else { return nil }

    let name = String(cString: namePtr)

    featureSetMetadataLock.lock()
    let businessActivity = featureSetBusinessActivities[name]
    featureSetMetadataLock.unlock()

    guard let activity = businessActivity else { return nil }

    // Allocate C string and return
    return strdup(activity)
}

/// Synchronously binds terminal capabilities dict to a context handle.
/// Called before dispatching compiled feature set functions (handlers, observers).
// #313: widened from `private` to internal — called from RuntimeEventRecordingBridge.swift.
func bindTerminalToContext(_ contextHandle: AROCContextHandle) {
    #if !os(Windows)
    let semaphore = DispatchSemaphore(value: 0)
    let context = contextHandle.context
    let terminalService = contextHandle.terminalService
    Task { @Sendable in
        let terminalDict: [String: any Sendable]
        if let ts = terminalService {
            let caps = await ts.detectCapabilities()
            terminalDict = [
                "rows": caps.rows, "columns": caps.columns,
                "width": caps.columns, "height": caps.rows,
                "supports_color": caps.supportsColor,
                "supports_true_color": caps.supportsTrueColor,
                "is_tty": caps.isTTY, "encoding": caps.encoding
            ]
        } else {
            terminalDict = [
                "rows": 24, "columns": 80, "width": 80, "height": 24,
                "supports_color": false, "supports_true_color": false,
                "is_tty": false, "encoding": "UTF-8"
            ]
        }
        context.bind("terminal", value: terminalDict, allowRebind: true)
        semaphore.signal()
    }
    semaphore.wait()
    #endif
}

/// Bind published variables to a context for a given business activity
/// This eagerly binds all published variables that match the business activity,
/// enabling HTTP handlers in compiled binaries to access variables published by Application-Start
/// - Parameters:
///   - contextPtr: Context handle
///   - businessActivityPtr: Business activity C string (NULL for empty)
@_cdecl("aro_context_bind_published_variables")
public func aro_context_bind_published_variables(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ businessActivityPtr: UnsafePointer<CChar>?
) {
    guard let ptr = contextPtr else { return }

    let contextHandle = Unmanaged<AROCContextHandle>.fromOpaque(ptr).takeUnretainedValue()
    let businessActivity = businessActivityPtr.map { String(cString: $0) } ?? ""
    let runtime = contextHandle.runtime.runtime

    // This must be async, so we need to run it synchronously using a semaphore
    let semaphore = DispatchSemaphore(value: 0)

    // Explicitly capture values to avoid data race warnings
    let context = contextHandle.context
    let terminalService = contextHandle.terminalService

    Task { @Sendable in
        let globalSymbols = await runtime.globalSymbols
        let allSymbols = await globalSymbols.allSymbols()

        for (name, entry) in allSymbols {
            // Skip if already bound
            if context.resolveAny(name) != nil {
                continue
            }

            // Only bind if business activity matches (or both are empty)
            if !entry.businessActivity.isEmpty && !businessActivity.isEmpty &&
               entry.businessActivity == businessActivity {
                context.bind(name, value: entry.value)
            } else if entry.businessActivity.isEmpty || businessActivity.isEmpty {
                // If either is empty, bind it (framework/external variables)
                context.bind(name, value: entry.value)
            }
        }

        // Bind terminal capabilities dict so ARO code can use <terminal: columns> etc.
        let terminalDict: [String: any Sendable]
        if let ts = terminalService {
            let caps = await ts.detectCapabilities()
            terminalDict = [
                "rows": caps.rows, "columns": caps.columns,
                "width": caps.columns, "height": caps.rows,
                "supports_color": caps.supportsColor,
                "supports_true_color": caps.supportsTrueColor,
                "is_tty": caps.isTTY, "encoding": caps.encoding
            ]
        } else {
            terminalDict = [
                "rows": 24, "columns": 80, "width": 80, "height": 24,
                "supports_color": false, "supports_true_color": false,
                "is_tty": false, "encoding": "UTF-8"
            ]
        }
        context.bind("terminal", value: terminalDict, allowRebind: true)

        semaphore.signal()
    }
    semaphore.wait()
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

    // Parse JSON to dictionary.
    // try? is acceptable: generated code also routes plain (non-JSON) string
    // payloads through this entry point, so a parse failure is an expected
    // signal to fall back to binding the raw string — no data is lost.
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

    // Parse JSON to array.
    // try? is acceptable: a payload that is not valid JSON is bound as the raw
    // string instead, so the value still reaches the context — no data is lost.
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

/// Convert Any to Sendable recursively (delegates to shared SendableConverter)
private func convertToSendable(_ value: Any) -> any Sendable {
    SendableConverter.fromJSON(value)
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

// MARK: - Stack Guard for Expression Evaluation

/// Returns an estimate of remaining stack space on the current thread in bytes.
///
/// Uses pthread APIs to find the stack bounds, then compares against the current
/// stack pointer (approximated via a local variable address). Returns `Int.max`
/// on unsupported platforms so the guard always passes (fail-open).
private func remainingStackBytes() -> Int {
    var marker: UInt8 = 0
    let sp = Int(bitPattern: withUnsafePointer(to: &marker) { $0 })
#if canImport(Darwin)
    let thread = pthread_self()
    let stackTop = Int(bitPattern: pthread_get_stackaddr_np(thread))   // highest address
    let stackSize = Int(pthread_get_stacksize_np(thread))
    let lowest = stackTop - stackSize
    return max(0, sp - lowest)
#elseif os(Linux)
    // pthread_getattr_np is a GNU extension not exposed by Swift's Glibc overlay.
    // Return 0 so withStackGuard always offloads to a fresh 8 MB thread on Linux,
    // guaranteeing safety at the cost of always spawning a thread.
    _ = sp
    return 0
#else
    return Int.max
#endif
}

/// Minimum stack headroom required before attempting inline expression evaluation.
/// JSONSerialization's recursive JSON parser can consume several hundred KB on
/// deeply-nested input. Below this threshold we offload to a fresh 8 MB thread
/// so the caller never receives a SIGBUS regardless of expression complexity.
private let stackGuardThreshold = 512 * 1024   // 512 KB

/// Run `body` on the current thread if there is enough stack headroom; otherwise
/// spawn a fresh 8 MB Thread, execute `body` there, and block until it finishes.
/// The result is returned synchronously either way, so callers are unaware of the
/// indirection.
private func withStackGuard<T>(_ body: @escaping @Sendable () -> T) -> T {
    guard remainingStackBytes() >= stackGuardThreshold else {
        // Stack is running low — offload to a fresh thread with a full 8 MB stack.
        // The semaphore guarantees the borrow ends before we return, making this safe
        // despite the unchecked Sendable transfer of the box.
        let sema = DispatchSemaphore(value: 0)
        let box = MutexBox<T>()
        let t = Thread {
            box.value = body()
            sema.signal()
        }
        t.stackSize = 8 * 1024 * 1024
        t.start()
        sema.wait()
        return box.value!
    }
    return body()
}

/// Thread-safe single-value box used to ferry a result out of `withStackGuard`.
private final class MutexBox<T>: @unchecked Sendable {
    var value: T?
    init() {}
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

    // If the calling thread is running low on stack, evaluate on a fresh 8 MB thread.
    // This prevents SIGBUS from JSONSerialization's recursive JSON parser consuming
    // the remaining stack space in compiled handler threads.
    withStackGuard {
        // Parse the JSON. The expression JSON is compiler-generated, so a parse
        // failure is a codegen bug: returning silently would leave _expression_
        // unbound with no trace — log before bailing out.
        guard let data = jsonStr.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data, options: []) else {
            FileHandle.standardError.write(Data("[RuntimeBridge] Warning: unparseable expression JSON, _expression_ left unbound: \(jsonStr)\n".utf8))
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

        // For simple variable references ($var), also set _expression_name_ so EmitAction
        // can use the variable name as the payload key (instead of falling back to "data").
        // For all other expression types, clear _expression_name_ so EmitAction doesn't
        // use a stale name from a previous statement.
        if let varName = dict["$var"] as? String, dict.count <= 2 /* $var + optional $specs */ {
            contextHandle.context.bind("_expression_name_", value: varName, allowRebind: true)
        } else {
            contextHandle.context.bind("_expression_name_", value: "", allowRebind: true)
        }
    }
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

    withStackGuard {
        // Parse the JSON. The expression JSON is compiler-generated, so a parse
        // failure is a codegen bug: returning silently would leave the variable
        // unbound with no trace — log before bailing out.
        guard let data = jsonStr.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data, options: []) else {
            FileHandle.standardError.write(Data("[RuntimeBridge] Warning: unparseable expression JSON, <\(nameStr)> left unbound: \(jsonStr)\n".utf8))
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
// #313: widened from `private` to internal — called from RuntimeEventRecordingBridge.swift.
func evaluateExpressionJSON(_ expr: [String: Any], context: RuntimeContext) -> any Sendable {
    // Literal value
    if let lit = expr["$lit"] {
        return convertToSendable(lit)
    }

    // Variable reference (with optional specifiers)
    if let varName = expr["$var"] as? String {
        let specs = expr["$specs"] as? [String] ?? []

        // Environment variable access: <env: VAR_NAME>
        if varName == "env", let envKey = specs.first {
            return ProcessInfo.processInfo.environment[envKey] ?? "" as any Sendable
        }

        // Special handling for repository count access: <repository-name: count>
        if specs == ["count"] && InMemoryRepositoryStorage.isRepositoryName(varName) {
            // Get count synchronously using the actor's sync count method
            let businessActivity = context.businessActivity
            return InMemoryRepositoryStorage.shared.countSync(
                repository: varName,
                businessActivity: businessActivity
            )
        }

        var value: any Sendable = context.resolveAny(varName) ?? ""

        // Handle specifiers - try plugin qualifier first, then dictionary property access
        // Try namespaced qualifier form first (e.g., <list: collections.reverse>)
        if specs.count > 1 {
            let joined = specs.joined(separator: ".")
            // try? is acceptable: this is a probe — most specifiers are not
            // namespaced qualifiers, and failure falls through to the
            // per-specifier resolution below.
            if let transformed = try? QualifierRegistry.shared.resolve(joined, value: value) {
                return transformed
            }
        }

        for spec in specs {
            // First, try plugin qualifier (e.g., <list: pick-random>).
            // try? is acceptable: a specifier that is not a registered qualifier
            // is expected — resolution falls through to property access below.
            if let transformed = try? QualifierRegistry.shared.resolve(spec, value: value) {
                value = transformed
            } else if let dict = value as? [String: any Sendable], let propVal = dict[spec] {
                // Fall back to dictionary property access (e.g., <user: name>)
                value = propVal
            }
            // If neither works, just continue - the value stays as-is
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
                value = convertToSendable(nested)
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
        // String repetition: "x" * n or n * "x"
        if let str = left as? String, let count = right as? Int {
            return String(repeating: str, count: max(0, count))
        }
        if let str = right as? String, let count = left as? Int {
            return String(repeating: str, count: max(0, count))
        }
        if let l = asDouble(left), let r = asDouble(right) {
            if let li = left as? Int, let ri = right as? Int {
                return li * ri
            }
            return l * r
        }
        return 0

    case "/":
        if let l = asDouble(left), let r = asDouble(right) {
            guard r != 0 else { fatalError("Division by zero") }
            // Integer / Integer → integer floor division (e.g. 80/3 = 26)
            if let li = left as? Int, let ri = right as? Int {
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
            let regex = try RegexCache.shared.regex(pattern)
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
        // try? is acceptable: this helper deliberately returns Optional —
        // "not a parseable date" is an expected answer the caller handles.
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
            FileHandle.standardError.write(Data("[RuntimeBridge] DEBUG: aro_variable_resolve(end-date) returned nil - variable not bound\n".utf8))
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
                value = convertToSendable(nested)
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

    // Parse the guard expression. The JSON is compiler-generated, so a parse
    // failure is a codegen bug: silently returning false would skip the guarded
    // block with no trace — log before failing the guard.
    guard let data = jsonStr.data(using: .utf8),
          let parsed = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
        FileHandle.standardError.write(Data("[RuntimeBridge] Warning: unparseable when-guard JSON, guard evaluates false: \(jsonStr)\n".utf8))
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

    // Parse subject name and pattern JSON. Both are compiler-generated, so a
    // parse failure is a codegen bug: silently returning "no match" would skip
    // the case with no trace — log before failing the match.
    guard let subjectData = subjectStr.data(using: .utf8),
          let patternData = patternStr.data(using: .utf8),
          let subjectInfo = try? JSONSerialization.jsonObject(with: subjectData, options: []) as? [String: Any],
          let patternInfo = try? JSONSerialization.jsonObject(with: patternData, options: []) as? [String: Any] else {
        FileHandle.standardError.write(Data("[RuntimeBridge] Warning: unparseable match-pattern JSON, case treated as no-match: subject=\(subjectStr) pattern=\(patternStr)\n".utf8))
        return 0
    }

    // Get subject value from context
    guard let subjectName = subjectInfo["name"] as? String,
          let rawSubjectValue = contextHandle.context.resolveAny(subjectName) else {
        return 0
    }

    // Apply specifiers for qualified match subjects (e.g. match <state: mode>)
    var subjectValue: any Sendable = rawSubjectValue
    if let specifiers = subjectInfo["specifiers"] as? [String] {
        for specifier in specifiers {
            guard let dict = subjectValue as? [String: any Sendable],
                  let next = dict[specifier] else { return 0 }
            subjectValue = next
        }
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
            let regex = try RegexCache.shared.regex(pattern, options: options)
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
    // Handle [String] from SplitAction explicitly
    if let stringArray = boxed.value as? [String] {
        return Int64(stringArray.count)
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

    if let array = boxed.value as? [any Sendable],
       index >= 0 && index < array.count {
        let element = array[Int(index)]
        let boxedElement = AROCValue(value: element)
        return UnsafeMutableRawPointer(Unmanaged.passRetained(boxedElement).toOpaque())
    }
    // Handle [String] from SplitAction explicitly
    if let stringArray = boxed.value as? [String],
       index >= 0 && index < stringArray.count {
        let element = stringArray[Int(index)]
        let boxedElement = AROCValue(value: element)
        return UnsafeMutableRawPointer(Unmanaged.passRetained(boxedElement).toOpaque())
    }
    return nil
}

/// Get the next element from a collection, advancing the iterator state in-place.
/// Works for both eagerly-materialised arrays and `LazyDirectoryList` (O(1) streaming).
/// - Parameters:
///   - valuePtr:  Value handle wrapping an array or LazyDirectoryList
///   - statePtr:  Pointer to an Int64 caller-allocated state (initialised to 0).
///               For arrays: used as a 0-based index, incremented per call.
///               For LazyDirectoryList: used as a monotonic counter; the enumerator
///               holds the actual position internally.
/// - Returns: passRetained value handle for the next element, or NULL when exhausted.
@_cdecl("aro_array_get_next")
public func aro_array_get_next(
    _ valuePtr: UnsafeMutableRawPointer?,
    _ statePtr: UnsafeMutablePointer<Int64>?
) -> UnsafeMutableRawPointer? {
    guard let ptr = valuePtr, let statePtr = statePtr else { return nil }
    let boxed = Unmanaged<AROCValue>.fromOpaque(ptr).takeUnretainedValue()

    if let lazyList = boxed.value as? LazyDirectoryList {
        guard let entry = lazyList.next() else { return nil }
        statePtr.pointee &+= 1
        let boxedElement = AROCValue(value: entry as any Sendable)
        return UnsafeMutableRawPointer(Unmanaged.passRetained(boxedElement).toOpaque())
    }

    // Backward compat: PipelinedDirectoryIterator from binaries compiled without _ctx.
    // Falls back to Task.detached + semaphore (same as Phase 1 pattern).
    if let pipelined = boxed.value as? PipelinedDirectoryIterator {
        if let entry = pipelined.tryNextSync() {
            statePtr.pointee &+= 1
            return UnsafeMutableRawPointer(Unmanaged.passRetained(AROCValue(value: entry as any Sendable)).toOpaque())
        }
        if pipelined.isExhausted { return nil }
        let box = ActionRunnerResultBox()
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            if let entry = await pipelined.nextAsync() {
                box.set(ActionRunnerResult.success(entry as any Sendable))
            } else {
                box.set(ActionRunnerResult.failure("__exhausted__"))
            }
            sem.signal()
        }
        // Phase 5: slot ownership lives on a TaskLocal.
        CompiledExecutionPool.shared.withYieldedSlot {
            sem.wait()
        }
        let res = box.result
        guard res.succeeded, let entry = res.value as? [String: any Sendable] else { return nil }
        statePtr.pointee &+= 1
        return UnsafeMutableRawPointer(Unmanaged.passRetained(AROCValue(value: entry as any Sendable)).toOpaque())
    }

    if let array = boxed.value as? [any Sendable] {
        let index = Int(statePtr.pointee)
        guard index < array.count else { return nil }
        statePtr.pointee &+= 1
        let boxedElement = AROCValue(value: array[index])
        return UnsafeMutableRawPointer(Unmanaged.passRetained(boxedElement).toOpaque())
    }

    if let stringArray = boxed.value as? [String] {
        let index = Int(statePtr.pointee)
        guard index < stringArray.count else { return nil }
        statePtr.pointee &+= 1
        let element: any Sendable = stringArray[index]
        let boxedElement = AROCValue(value: element)
        return UnsafeMutableRawPointer(Unmanaged.passRetained(boxedElement).toOpaque())
    }

    return nil
}

/// Context-aware for-each iterator — cooperative pipelined variant of aro_array_get_next.
///
/// For `PipelinedDirectoryIterator` values:
///  - Fast path: returns the next buffered entry synchronously (no Task, no semaphore).
///  - Slow path: submits an `ArrayNextWorkItem` to the driver channel so the driver Task
///    can `await iterator.nextAsync()` cooperatively, allowing the producer Task to
///    continue prefetching while the driver waits.
/// For all other value types: delegates to `aro_array_get_next` (synchronous fast path).
@_cdecl("aro_array_get_next_ctx")
public func aro_array_get_next_ctx(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ valuePtr: UnsafeMutableRawPointer?,
    _ statePtr: UnsafeMutablePointer<Int64>?
) -> UnsafeMutableRawPointer? {
    guard let contextPtr, let valuePtr, let statePtr else {
        return aro_array_get_next(valuePtr, statePtr)
    }

    let boxed = Unmanaged<AROCValue>.fromOpaque(valuePtr).takeUnretainedValue()

    // Lazy upgrade: first for-each call on a LazyDirectoryList wraps it in a
    // PipelinedDirectoryIterator so the producer and driver Task can overlap.
    if let lazyList = boxed.value as? LazyDirectoryList {
        let pipelined = PipelinedDirectoryIterator(from: lazyList)
        boxed.upgradeValue(pipelined)
        // Fall through to pipelined path below (re-read value)
    }

    guard let pipelined = boxed.value as? PipelinedDirectoryIterator else {
        return aro_array_get_next(valuePtr, statePtr)
    }

    // Fast path: item is already buffered — return it directly, zero overhead.
    if let entry = pipelined.tryNextSync() {
        statePtr.pointee &+= 1
        return UnsafeMutableRawPointer(Unmanaged.passRetained(AROCValue(value: entry as any Sendable)).toOpaque())
    }
    if pipelined.isExhausted { return nil }

    // Slow path: producer hasn't buffered an item yet — go through driver channel.
    // The driver Task calls `await pipelined.nextAsync()` cooperatively; meanwhile
    // the producer Task can run on another cooperative-pool thread.
    let contextHandle = Unmanaged<AROCContextHandle>.fromOpaque(contextPtr).takeUnretainedValue()
    let channel = contextHandle.driverChannel
    let box = ActionRunnerResultBox()
    let sem = DispatchSemaphore(value: 0)
    channel.submitArrayNext(iterator: pipelined, holder: box, semaphore: sem)

    // Phase 5: slot ownership lives on a TaskLocal.
    CompiledExecutionPool.shared.withYieldedSlot {
        sem.wait()
    }

    let res = box.result
    guard res.succeeded, let entry = res.value as? [String: any Sendable] else { return nil }
    statePtr.pointee &+= 1
    return UnsafeMutableRawPointer(Unmanaged.passRetained(AROCValue(value: entry as any Sendable)).toOpaque())
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
        FileHandle.standardError.write(Data("[RuntimeBridge] DEBUG: aro_variable_bind_value(_to_) called, valuePtr=\(hasValue ? "valid" : "NULL")\n".utf8))
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

/// Apply a specifier to a value (qualifier or property access)
/// - Parameters:
///   - valuePtr: Value handle
///   - specifier: Specifier name (C string) - either a qualifier or property name
/// - Returns: Value handle for the result (must be freed with aro_value_free), or NULL if not found
@_cdecl("aro_dict_get")
public func aro_dict_get(
    _ valuePtr: UnsafeMutableRawPointer?,
    _ specifier: UnsafePointer<CChar>?
) -> UnsafeMutableRawPointer? {
    guard let ptr = valuePtr,
          let specStr = specifier.map({ String(cString: $0) }) else { return nil }

    let boxed = Unmanaged<AROCValue>.fromOpaque(ptr).takeUnretainedValue()

    // First, try plugin qualifier (e.g., <list: pick-random>).
    // try? is acceptable: this is a probe — a specifier that is not a
    // registered qualifier is expected, and resolution falls through to
    // dictionary property access below.
    if let transformed = try? QualifierRegistry.shared.resolve(specStr, value: boxed.value) {
        let boxedValue = AROCValue(value: transformed)
        return UnsafeMutableRawPointer(Unmanaged.passRetained(boxedValue).toOpaque())
    }

    // Fall back to dictionary property access (e.g., <user: name>)
    if let dict = boxed.value as? [String: any Sendable],
       let value = dict[specStr] {
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
    // Phase 5: slot ownership lives on a TaskLocal — the entire loop runs
    // inside withYieldedSlot so the rejoin happens automatically on exit.
    return pool.withYieldedSlot {
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
        let compiledThread5 = Thread {
            defer {
                pool.gate.signal()
                localLimit.signal()
                group.leave()
            }
            pool.withSlotOwnership {
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
        compiledThread5.stackSize = 8 * 1024 * 1024
        compiledThread5.start()
    }

    // Wait for all iterations to complete
    group.wait()

    // Check for errors
    if let error = errorBox.getError() {
        print("[ARO] Parallel loop error: \(error)")
        return -1
    }

    return 0
    } // end withYieldedSlot
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

    // Parse and evaluate the expression. The filter JSON is compiler-generated,
    // so a parse failure is a codegen bug: silently returning false would drop
    // every element from the filtered collection with no trace — log first.
    guard let data = jsonStr.data(using: .utf8),
          let parsed = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
        FileHandle.standardError.write(Data("[RuntimeBridge] Warning: unparseable filter JSON, filter evaluates false: \(jsonStr)\n".utf8))
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

// MARK: - Stream For-Each (ARO-0051 Streaming)

/// Returns 1 if the named variable holds a lazy AROStream, 0 otherwise.
/// Used by compiled binaries to choose the stream iteration path.
@_cdecl("aro_runtime_is_stream")
public func aro_runtime_is_stream(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ varName: UnsafePointer<CChar>?
) -> Int32 {
    guard let ptr = contextPtr,
          let nameStr = varName.map({ String(cString: $0) }) else { return 0 }
    let contextHandle = Unmanaged<AROCContextHandle>.fromOpaque(ptr).takeUnretainedValue()
    if contextHandle.context.resolveAny(nameStr) is AnyStreamingValue { return 1 }
    return 0
}

/// Iterates a lazy stream variable in the context, calling the loop body function for each element.
///
/// Signature of loopBodyFn: `ptr loopBodyFn(ptr ctx, ptr element, i64 index) -> ptr`
/// The callback is called synchronously for each element from within a Task.
/// Iteration stops when the stream is exhausted or the context reports an error.
///
/// - Parameters:
///   - contextPtr: Execution context handle
///   - varName: Name of the stream variable in the context
///   - loopBodyFn: Pointer to the loop body function (same signature as parallel for-each bodies)
@_cdecl("aro_runtime_foreach_stream")
public func aro_runtime_foreach_stream(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ varName: UnsafePointer<CChar>?,
    _ loopBodyFn: UnsafeMutableRawPointer?
) {
    guard let ptr = contextPtr,
          let nameStr = varName.map({ String(cString: $0) }),
          let bodyFn = loopBodyFn else { return }

    let contextHandle = Unmanaged<AROCContextHandle>.fromOpaque(ptr).takeUnretainedValue()

    // Resolve the stream value (works for any element type)
    guard let anyValue = contextHandle.context.resolveAny(nameStr) as? AnyStreamingValue else {
        return
    }
    let stream: AROStream<any Sendable> = anyValue.asStream()

    typealias LoopBodyFunc = @convention(c) (
        UnsafeMutableRawPointer?,   // context ptr
        UnsafeMutableRawPointer?,   // element ptr
        Int64                        // index
    ) -> UnsafeMutableRawPointer?

    let body = unsafeBitCast(bodyFn, to: LoopBodyFunc.self)

    // Capture everything needed inside the Task in a Sendable box.
    final class StreamIterState: @unchecked Sendable {
        let stream: AROStream<any Sendable>
        let contextPtr: UnsafeMutableRawPointer
        let contextHandle: AROCContextHandle
        let body: LoopBodyFunc
        init(_ s: AROStream<any Sendable>, _ cp: UnsafeMutableRawPointer,
             _ ch: AROCContextHandle, _ b: LoopBodyFunc) {
            stream = s; contextPtr = cp; contextHandle = ch; body = b
        }
    }
    let state = StreamIterState(stream, ptr, contextHandle, body)

    // Drain the stream synchronously: run iteration in a detached Task,
    // block the calling thread with a semaphore until all items are processed.
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached { [state] in
        do {
            var index: Int64 = 0
            for try await item in state.stream.stream {
                let boxed = AROCValue(value: item)
                let elementPtr = UnsafeMutableRawPointer(Unmanaged.passRetained(boxed).toOpaque())
                _ = state.body(state.contextPtr, elementPtr, index)
                Unmanaged<AROCValue>.fromOpaque(elementPtr).release()
                // Stop if an action in the body set an error on the context
                if state.contextHandle.context.getExecutionError() != nil { break }
                index += 1
            }
        } catch {}
        semaphore.signal()
    }
    semaphore.wait()
}

// MARK: - Mutable Scope (ARO-0131 While Loop)

/// Enter a mutable scope in the given context (called at start of while loop)
@_cdecl("aro_runtime_enter_mutable_scope")
public func aro_runtime_enter_mutable_scope(_ contextPtr: UnsafeMutableRawPointer?) {
    guard let ptr = contextPtr else { return }
    let contextHandle = Unmanaged<AROCContextHandle>.fromOpaque(ptr).takeUnretainedValue()
    contextHandle.context.enterMutableScope()
}

/// Exit a mutable scope in the given context (called at end of while loop)
@_cdecl("aro_runtime_exit_mutable_scope")
public func aro_runtime_exit_mutable_scope(_ contextPtr: UnsafeMutableRawPointer?) {
    guard let ptr = contextPtr else { return }
    let contextHandle = Unmanaged<AROCContextHandle>.fromOpaque(ptr).takeUnretainedValue()
    contextHandle.context.exitMutableScope()
}
