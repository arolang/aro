// ============================================================
// ActionBridge.swift
// ARORuntime - C-callable Action Interface
// ============================================================
//
// This file provides thin @_cdecl wrappers that delegate to
// ActionRunner.shared for unified action execution.
// All action logic lives in Actions/BuiltIn/*.swift

import Foundation
import AROParser

// MARK: - Descriptor Types for C Interop

/// C-compatible result descriptor (defined in C header)
/// struct AROResultDescriptor {
///     const char* base;
///     const char** specifiers;
///     int specifier_count;
/// };

/// C-compatible object descriptor (defined in C header)
/// struct AROObjectDescriptor {
///     const char* base;
///     int preposition;
///     const char** specifiers;
///     int specifier_count;
/// };

// MARK: - Helper Functions

// Note: AROCValue and AROCContextHandle are defined in RuntimeBridge.swift

/// Convert C result descriptor to Swift ResultDescriptor
func toResultDescriptor(_ ptr: UnsafeRawPointer) -> ResultDescriptor {
    // Read raw C struct with proper alignment:
    // struct AROResultDescriptor {
    //     const char* base;        // offset 0, 8 bytes
    //     const char** specifiers; // offset 8, 8 bytes
    //     int specifier_count;     // offset 16, 4 bytes
    // };
    let basePtr = ptr.load(as: UnsafePointer<CChar>?.self)
    let base = basePtr.map { String(cString: $0) } ?? ""

    let specsPtr = ptr.load(fromByteOffset: 8, as: UnsafeMutablePointer<UnsafePointer<CChar>?>?.self)
    let specCount = ptr.load(fromByteOffset: 16, as: Int32.self)

    var specifiers: [String] = []
    if let specs = specsPtr {
        for i in 0..<Int(specCount) {
            if let spec = specs[i] {
                let specStr = String(cString: spec)
                specifiers.append(specStr)
            }
        }
    }

    let dummyLocation = SourceLocation(line: 0, column: 0, offset: 0)
    let dummySpan = SourceSpan(at: dummyLocation)
    return ResultDescriptor(base: base, specifiers: specifiers, span: dummySpan)
}

/// Convert C object descriptor to Swift ObjectDescriptor
func toObjectDescriptor(_ ptr: UnsafeRawPointer) -> ObjectDescriptor {
    // Read raw C struct with proper alignment:
    // struct AROObjectDescriptor {
    //     const char* base;        // offset 0, 8 bytes
    //     int preposition;         // offset 8, 4 bytes
    //     // 4 bytes padding for pointer alignment
    //     const char** specifiers; // offset 16, 8 bytes
    //     int specifier_count;     // offset 24, 4 bytes
    // };
    let basePtr = ptr.load(as: UnsafePointer<CChar>?.self)
    let base = basePtr.map { String(cString: $0) } ?? ""

    let prepInt = ptr.load(fromByteOffset: 8, as: Int32.self)
    let preposition = intToPreposition(Int(prepInt)) ?? .from

    // Account for padding: specifiers is at offset 16, not 12
    let specsPtr = ptr.load(fromByteOffset: 16, as: UnsafeMutablePointer<UnsafePointer<CChar>?>?.self)
    let specCount = ptr.load(fromByteOffset: 24, as: Int32.self)

    var specifiers: [String] = []
    if let specs = specsPtr {
        for i in 0..<Int(specCount) {
            if let spec = specs[i] {
                specifiers.append(String(cString: spec))
            }
        }
    }

    let dummyLocation = SourceLocation(line: 0, column: 0, offset: 0)
    let dummySpan = SourceSpan(at: dummyLocation)
    return ObjectDescriptor(preposition: preposition, base: base, specifiers: specifiers, span: dummySpan)
}

/// Convert integer to Preposition enum
func intToPreposition(_ value: Int) -> Preposition? {
    switch value {
    case 1: return .from
    case 2: return .for
    case 3: return .with
    case 4: return .to
    case 5: return .into
    case 6: return .via
    case 7: return .against
    case 8: return .on
    default: return nil
    }
}

/// Get context handle from opaque pointer
func getContext(_ contextPtr: UnsafeMutableRawPointer?) -> AROCContextHandle? {
    guard let ptr = contextPtr else { return nil }
    return Unmanaged<AROCContextHandle>.fromOpaque(ptr).takeUnretainedValue()
}

/// Box a value for return to C
func boxResult(_ value: any Sendable) -> UnsafeMutableRawPointer {
    let boxed = AROCValue(value: value)
    return UnsafeMutableRawPointer(Unmanaged.passRetained(boxed).toOpaque())
}

// MARK: - Unified Action Execution

/// Execute an action through ActionRunner
/// This is the single point of execution for all compiled actions
private func executeAction(
    verb: String,
    contextPtr: UnsafeMutableRawPointer?,
    resultPtr: UnsafeRawPointer?,
    objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    guard let ctxHandle = getContext(contextPtr),
          let result = resultPtr,
          let object = objectPtr else { return nil }

    let resultDesc = toResultDescriptor(result)
    let objectDesc = toObjectDescriptor(object)

    // Execute through ActionRunner with error handling
    let actionResult = ActionRunner.shared.executeSyncWithResult(
        verb: verb,
        result: resultDesc,
        object: objectDesc,
        context: ctxHandle.context
    )

    // Clear temporary expression/literal bindings after action execution
    // These are statement-scoped and should not persist to subsequent statements
    ctxHandle.context.unbind("_expression_")
    ctxHandle.context.unbind("_literal_")

    // If action failed, store error in context for HTTP response handling
    if !actionResult.succeeded, let errorMsg = actionResult.error {
        ctxHandle.context.setExecutionError(ActionError.runtimeError(errorMsg))
    }

    // Check semantic role - response/export actions don't bind their results
    let semanticRole = ActionSemanticRole.classify(verb: verb)
    let shouldBindResult = semanticRole != .response && semanticRole != .export

    // Only bind the result if the action hasn't already bound it
    // This prevents "Cannot rebind immutable variable" errors while still
    // supporting actions that don't bind their own results.
    if let value = actionResult.value {
        if shouldBindResult && !ctxHandle.context.exists(resultDesc.base) {
            ctxHandle.context.bind(resultDesc.base, value: value)
        }
        return boxResult(value)
    }

    // Return empty string on failure
    let fallback = ""
    if shouldBindResult && !ctxHandle.context.exists(resultDesc.base) {
        ctxHandle.context.bind(resultDesc.base, value: fallback)
    }
    return boxResult(fallback)
}

// MARK: - REQUEST Actions

@_cdecl("aro_action_extract")
public func aro_action_extract(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    return executeAction(verb: "extract", contextPtr: contextPtr, resultPtr: resultPtr, objectPtr: objectPtr)
}

@_cdecl("aro_action_fetch")
public func aro_action_fetch(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    return executeAction(verb: "fetch", contextPtr: contextPtr, resultPtr: resultPtr, objectPtr: objectPtr)
}

@_cdecl("aro_action_retrieve")
public func aro_action_retrieve(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    return executeAction(verb: "retrieve", contextPtr: contextPtr, resultPtr: resultPtr, objectPtr: objectPtr)
}

@_cdecl("aro_action_parse")
public func aro_action_parse(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    return executeAction(verb: "parse", contextPtr: contextPtr, resultPtr: resultPtr, objectPtr: objectPtr)
}

@_cdecl("aro_action_read")
public func aro_action_read(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    return executeAction(verb: "read", contextPtr: contextPtr, resultPtr: resultPtr, objectPtr: objectPtr)
}

@_cdecl("aro_action_request")
public func aro_action_request(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    return executeAction(verb: "request", contextPtr: contextPtr, resultPtr: resultPtr, objectPtr: objectPtr)
}

// MARK: - OWN Actions

@_cdecl("aro_action_compute")
public func aro_action_compute(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    return executeAction(verb: "compute", contextPtr: contextPtr, resultPtr: resultPtr, objectPtr: objectPtr)
}

@_cdecl("aro_action_validate")
public func aro_action_validate(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    return executeAction(verb: "validate", contextPtr: contextPtr, resultPtr: resultPtr, objectPtr: objectPtr)
}

@_cdecl("aro_action_compare")
public func aro_action_compare(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    return executeAction(verb: "compare", contextPtr: contextPtr, resultPtr: resultPtr, objectPtr: objectPtr)
}

@_cdecl("aro_action_transform")
public func aro_action_transform(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    return executeAction(verb: "transform", contextPtr: contextPtr, resultPtr: resultPtr, objectPtr: objectPtr)
}

@_cdecl("aro_action_create")
public func aro_action_create(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    return executeAction(verb: "create", contextPtr: contextPtr, resultPtr: resultPtr, objectPtr: objectPtr)
}

@_cdecl("aro_action_update")
public func aro_action_update(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    return executeAction(verb: "update", contextPtr: contextPtr, resultPtr: resultPtr, objectPtr: objectPtr)
}

@_cdecl("aro_action_configure")
public func aro_action_configure(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    return executeAction(verb: "configure", contextPtr: contextPtr, resultPtr: resultPtr, objectPtr: objectPtr)
}

@_cdecl("aro_action_accept")
public func aro_action_accept(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    return executeAction(verb: "accept", contextPtr: contextPtr, resultPtr: resultPtr, objectPtr: objectPtr)
}

// MARK: - RESPONSE Actions

@_cdecl("aro_action_return")
public func aro_action_return(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    return executeAction(verb: "return", contextPtr: contextPtr, resultPtr: resultPtr, objectPtr: objectPtr)
}

@_cdecl("aro_action_throw")
public func aro_action_throw(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    return executeAction(verb: "throw", contextPtr: contextPtr, resultPtr: resultPtr, objectPtr: objectPtr)
}

@_cdecl("aro_action_emit")
public func aro_action_emit(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    return executeAction(verb: "emit", contextPtr: contextPtr, resultPtr: resultPtr, objectPtr: objectPtr)
}

@_cdecl("aro_action_send")
public func aro_action_send(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    return executeAction(verb: "send", contextPtr: contextPtr, resultPtr: resultPtr, objectPtr: objectPtr)
}

@_cdecl("aro_action_log")
public func aro_action_log(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    return executeAction(verb: "log", contextPtr: contextPtr, resultPtr: resultPtr, objectPtr: objectPtr)
}

@_cdecl("aro_action_store")
public func aro_action_store(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    return executeAction(verb: "store", contextPtr: contextPtr, resultPtr: resultPtr, objectPtr: objectPtr)
}

@_cdecl("aro_action_write")
public func aro_action_write(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    return executeAction(verb: "write", contextPtr: contextPtr, resultPtr: resultPtr, objectPtr: objectPtr)
}

@_cdecl("aro_action_publish")
public func aro_action_publish(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    return executeAction(verb: "publish", contextPtr: contextPtr, resultPtr: resultPtr, objectPtr: objectPtr)
}

// MARK: - SERVER Actions

@_cdecl("aro_action_start")
public func aro_action_start(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    return executeAction(verb: "start", contextPtr: contextPtr, resultPtr: resultPtr, objectPtr: objectPtr)
}

@_cdecl("aro_action_listen")
public func aro_action_listen(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    return executeAction(verb: "listen", contextPtr: contextPtr, resultPtr: resultPtr, objectPtr: objectPtr)
}

@_cdecl("aro_action_route")
public func aro_action_route(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    return executeAction(verb: "route", contextPtr: contextPtr, resultPtr: resultPtr, objectPtr: objectPtr)
}

@_cdecl("aro_action_watch")
public func aro_action_watch(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    return executeAction(verb: "watch", contextPtr: contextPtr, resultPtr: resultPtr, objectPtr: objectPtr)
}

@_cdecl("aro_action_stop")
public func aro_action_stop(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    return executeAction(verb: "stop", contextPtr: contextPtr, resultPtr: resultPtr, objectPtr: objectPtr)
}

@_cdecl("aro_action_broadcast")
public func aro_action_broadcast(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    guard let ctxHandle = getContext(contextPtr),
          let result = resultPtr else { return nil }

    let resultDesc = toResultDescriptor(result)

    // Get data to broadcast
    guard let data = ctxHandle.context.resolveAny(resultDesc.base) else {
        return nil
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

    // Use native socket broadcast
    let count = dataToSend.withUnsafeBytes { buffer -> Int32 in
        guard let ptr = buffer.baseAddress else { return -1 }
        return aro_native_socket_broadcast(ptr.assumingMemoryBound(to: UInt8.self), dataToSend.count)
    }

    let broadcastResult = BroadcastResult(success: count >= 0, clientCount: Int(count))
    // Don't bind result - broadcast is a response action, shouldn't overwrite the source variable
    return boxResult(broadcastResult)
}

@_cdecl("aro_action_keepalive")
public func aro_action_keepalive(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    guard let ctxHandle = getContext(contextPtr),
          let result = resultPtr else { return nil }

    let resultDesc = toResultDescriptor(result)

    // Set up signal handling
    KeepaliveSignalHandler.shared.setup()

    // Enter wait state
    ctxHandle.context.enterWaitState()

    // Emit event
    ctxHandle.context.emit(WaitStateEnteredEvent())

    // Use synchronous wait - this properly blocks the current thread
    // until SIGINT/SIGTERM is received
    ShutdownCoordinator.shared.waitForShutdownSync()

    // Return result
    let waitResult = WaitResult(completed: true, reason: "shutdown")
    ctxHandle.context.bind(resultDesc.base, value: waitResult)
    return boxResult(waitResult)
}

// MARK: - External Service Actions

@_cdecl("aro_action_call")
public func aro_action_call(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    return executeAction(verb: "call", contextPtr: contextPtr, resultPtr: resultPtr, objectPtr: objectPtr)
}

// MARK: - Data Pipeline Actions (ARO-0018)

@_cdecl("aro_action_filter")
public func aro_action_filter(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    return executeAction(verb: "filter", contextPtr: contextPtr, resultPtr: resultPtr, objectPtr: objectPtr)
}

@_cdecl("aro_action_reduce")
public func aro_action_reduce(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    return executeAction(verb: "reduce", contextPtr: contextPtr, resultPtr: resultPtr, objectPtr: objectPtr)
}

@_cdecl("aro_action_map")
public func aro_action_map(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    return executeAction(verb: "map", contextPtr: contextPtr, resultPtr: resultPtr, objectPtr: objectPtr)
}

// MARK: - System Exec Action (ARO-0033)

@_cdecl("aro_action_exec")
public func aro_action_exec(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    return executeAction(verb: "exec", contextPtr: contextPtr, resultPtr: resultPtr, objectPtr: objectPtr)
}

@_cdecl("aro_action_shell")
public func aro_action_shell(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    return executeAction(verb: "shell", contextPtr: contextPtr, resultPtr: resultPtr, objectPtr: objectPtr)
}

// MARK: - Repository Actions

@_cdecl("aro_action_delete")
public func aro_action_delete(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    return executeAction(verb: "delete", contextPtr: contextPtr, resultPtr: resultPtr, objectPtr: objectPtr)
}

@_cdecl("aro_action_merge")
public func aro_action_merge(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    return executeAction(verb: "merge", contextPtr: contextPtr, resultPtr: resultPtr, objectPtr: objectPtr)
}

@_cdecl("aro_action_close")
public func aro_action_close(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    return executeAction(verb: "close", contextPtr: contextPtr, resultPtr: resultPtr, objectPtr: objectPtr)
}

// MARK: - File Operations (ARO-0036)

@_cdecl("aro_action_list")
public func aro_action_list(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    return executeAction(verb: "list", contextPtr: contextPtr, resultPtr: resultPtr, objectPtr: objectPtr)
}

@_cdecl("aro_action_stat")
public func aro_action_stat(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    return executeAction(verb: "stat", contextPtr: contextPtr, resultPtr: resultPtr, objectPtr: objectPtr)
}

@_cdecl("aro_action_exists")
public func aro_action_exists(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    return executeAction(verb: "exists", contextPtr: contextPtr, resultPtr: resultPtr, objectPtr: objectPtr)
}

@_cdecl("aro_action_createdirectory")
public func aro_action_createdirectory(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    return executeAction(verb: "createdirectory", contextPtr: contextPtr, resultPtr: resultPtr, objectPtr: objectPtr)
}

@_cdecl("aro_action_make")
public func aro_action_make(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    return executeAction(verb: "make", contextPtr: contextPtr, resultPtr: resultPtr, objectPtr: objectPtr)
}

@_cdecl("aro_action_copy")
public func aro_action_copy(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    return executeAction(verb: "copy", contextPtr: contextPtr, resultPtr: resultPtr, objectPtr: objectPtr)
}

@_cdecl("aro_action_move")
public func aro_action_move(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    return executeAction(verb: "move", contextPtr: contextPtr, resultPtr: resultPtr, objectPtr: objectPtr)
}

@_cdecl("aro_action_append")
public func aro_action_append(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    return executeAction(verb: "append", contextPtr: contextPtr, resultPtr: resultPtr, objectPtr: objectPtr)
}

// MARK: - String Actions (ARO-0037)

@_cdecl("aro_action_split")
public func aro_action_split(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    return executeAction(verb: "split", contextPtr: contextPtr, resultPtr: resultPtr, objectPtr: objectPtr)
}

// MARK: - Notification Actions

@_cdecl("aro_action_notify")
public func aro_action_notify(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    return executeAction(verb: "notify", contextPtr: contextPtr, resultPtr: resultPtr, objectPtr: objectPtr)
}

@_cdecl("aro_action_alert")
public func aro_action_alert(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    return executeAction(verb: "alert", contextPtr: contextPtr, resultPtr: resultPtr, objectPtr: objectPtr)
}

@_cdecl("aro_action_signal")
public func aro_action_signal(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    return executeAction(verb: "signal", contextPtr: contextPtr, resultPtr: resultPtr, objectPtr: objectPtr)
}
