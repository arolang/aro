// ============================================================
// RuntimeEventRecordingBridge.swift
// ARORuntime - C-callable event/observer/handler registration
// ============================================================
//
// Owns the C-ABI bridge for registering compiled feature-set callbacks with
// the runtime's event system: generic event handlers, user-defined
// `Application.<Name>` actions (+ their input/response marshalling helpers),
// repository observers (guarded and legacy), state-transition handlers, and
// notification handlers. Depends on `bindTerminalToContext` and
// `evaluateExpressionJSON` (widened to internal in their owning files).
// Extracted from RuntimeBridge.swift (issue #313) — pure move, no behaviour change.

import Foundation
import AROParser


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
            let compiledThread = Thread {
              pool.withAcquiredSlot {
                // Track execution time for metrics
                let startTime = Date()
                let handlerName = "\(eventTypeStr) Handler"

                // Create a context for the handler
                let contextHandle = AROCContextHandle(runtime: runtimeHandle, featureSetName: handlerName)

                // Bind event payload to context.
                // Bind both "event:<key>" (ARO convention) AND plain "<key>" so that
                // handler code written for interpreter mode (which binds the source
                // object directly, e.g. "packet", "connection") works unchanged.
                // Binding the plain key last lets it override "event" if the payload
                // itself contains an "event" key (e.g. socket.disconnected).
                contextHandle.context.bind("event", value: event.payload)
                for (key, value) in event.payload {
                    contextHandle.context.bind("event:\(key)", value: value)
                    contextHandle.context.bind(key, value: value)
                }

                // Bind terminal capabilities so ARO handler code can use <terminal: columns>
                bindTerminalToContext(contextHandle)

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
              }
            }
            compiledThread.stackSize = 8 * 1024 * 1024
            compiledThread.start()
        }
    }
}

/// Register a user-defined `Application.<Name>` action in a compiled binary.
///
/// User-defined actions (feature sets whose business activity is `Action`)
/// are compiled to native code just like every other feature set, but the
/// runtime's ActionRegistry has no idea they exist — only the LLVM-emitted
/// `main` knows the name → function mapping. The compiler calls this
/// function once per user-defined action at startup so a later
/// `Application.RenderElement the <X> with { … }` can be dispatched
/// through `aro_action_dynamic` like every other dynamic action.
///
/// - Parameters:
///   - runtimePtr: Runtime handle from aro_runtime_init.
///   - namePtr: Bare action name (e.g. "RenderElement"). Registered as
///     verb "Application.<name>".
///   - bodyFuncPtr: Function pointer to the compiled feature-set body —
///     `@convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?`,
///     same signature as event handlers and Application-Start.
///   - takesFieldPtr: Optional "takes <field>" sugar slot from the action
///     header. If non-null, callers may use `from <value>` and the runtime
///     wraps the value as `{ <field>: <value> }` for `<input>`.
@_cdecl("aro_register_user_action")
public func aro_register_user_action(
    _ runtimePtr: UnsafeMutableRawPointer?,
    _ namePtr: UnsafePointer<CChar>?,
    _ bodyFuncPtr: UnsafeMutableRawPointer?,
    _ takesFieldPtr: UnsafePointer<CChar>?
) {
    guard let runtimePtr = runtimePtr,
          let namePtr = namePtr,
          let bodyFuncPtr = bodyFuncPtr
    else { return }

    let runtimeHandle = Unmanaged<AROCRuntimeHandle>.fromOpaque(runtimePtr).takeUnretainedValue()
    let name = String(cString: namePtr)
    let takesField = takesFieldPtr.map { String(cString: $0) }
    let bodyAddress = Int(bitPattern: bodyFuncPtr)
    let verb = "Application.\(name)"

    ActionRegistry.shared.registerDynamic(
        verb: verb,
        handler: { result, object, context in
            // Build the <input> dict the same way UserDefinedActionHost
            // does in interpreter mode (with-clause, takes-sugar, or a
            // bare variable that already holds an object).
            let input = buildCompiledUserActionInput(
                takesField: takesField,
                object: object,
                context: context
            )

            // Spawn a fresh runtime context for the callee, parented to
            // the caller so services and globals stay reachable.
            let childContext = RuntimeContext(
                featureSetName: name,
                businessActivity: "Action",
                parent: context
            )
            childContext.bind("input", value: input)

            // Wrap the child context as an AROCContextHandle so the
            // compiled body can read/write it through the regular C API.
            let childHandle = AROCContextHandle(runtime: runtimeHandle, existingContext: childContext)
            let childPtr = Unmanaged.passRetained(childHandle).toOpaque()

            // Re-cast the stored function-pointer address and invoke it.
            guard let bodyPtrReconstructed = UnsafeMutableRawPointer(bitPattern: bodyAddress) else {
                Unmanaged<AROCContextHandle>.fromOpaque(childPtr).release()
                throw ActionError.unknownAction("Application.\(name) — invalid body pointer")
            }
            typealias BodyFunc = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
            let body = unsafeBitCast(bodyPtrReconstructed, to: BodyFunc.self)
            let returned = body(childPtr)
            if let r = returned { aro_value_free(r) }

            // Read the response the body produced and flatten it into the
            // dict shape callers see from plugin actions: `status`, optional
            // `reason`, plus whatever fields `Return … with <data>.` set.
            let flat = flattenCompiledUserActionResponse(childContext)

            Unmanaged<AROCContextHandle>.fromOpaque(childPtr).release()
            return flat
        },
        pluginName: "_user_defined_actions_"
    )
}

/// Build the `<input>` dict for a compiled-binary user-action call.
/// Mirrors UserDefinedActionHost.buildInput but uses only what's bound
/// on the caller's context (no analyzer access).
private func buildCompiledUserActionInput(
    takesField: String?,
    object: ObjectDescriptor,
    context: ExecutionContext
) -> [String: any Sendable] {
    func resolveLocal(_ name: String) -> (any Sendable)? {
        guard let rc = context as? RuntimeContext, rc.existsLocally(name) else { return nil }
        return rc.resolveAny(name)
    }
    if let withDict = resolveLocal("_with_") as? [String: any Sendable] {
        return withDict
    }
    // `with { ... }` in a compiled binary: the LLVM call site routes the
    // evaluated object literal through `_expression_` (there is no `_with_`
    // transient in compiled mode) but preserves the preposition on the
    // object descriptor. A with-clause dict is the input object itself —
    // without this, a `takes <field>` action would wrap the whole dict as
    // `{ field: dict }`, mangling `Application.X the <r> with { field: v }`.
    if object.preposition == .with,
       let dict = (resolveLocal("_expression_") ?? resolveLocal("_literal_")) as? [String: any Sendable] {
        return dict
    }
    if let takesField = takesField {
        if let expr = resolveLocal("_expression_") { return [takesField: expr] }
        if let lit  = resolveLocal("_literal_")    { return [takesField: lit] }
        if let v    = context.resolveAny(object.base) { return [takesField: v] }
    }
    if let resolved = context.resolveAny(object.base) as? [String: any Sendable] {
        return resolved
    }
    return [:]
}

/// Read the response the compiled feature-set body wrote into its child
/// context and flatten it into the dict shape callers see from plugin
/// and interpreter user-actions.
private func flattenCompiledUserActionResponse(_ context: RuntimeContext) -> [String: any Sendable] {
    guard let response = context.getResponse() else { return [:] }
    var dict: [String: any Sendable] = ["status": response.status]
    if !response.reason.isEmpty { dict["reason"] = response.reason }
    for (key, anySendable) in response.data {
        if let value: any Sendable = anySendable.get() { dict[key] = value }
    }
    return dict
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
            // Parse the when condition JSON. The JSON is compiler-generated, so a
            // parse failure is a codegen bug: skipping silently would make the
            // observer never fire with no trace — log before skipping.
            guard let conditionData = condition.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: conditionData, options: []) as? [String: Any] else {
                FileHandle.standardError.write(Data("[RuntimeBridge] Warning: unparseable when-condition for \(repositoryName) Observer, event skipped: \(condition)\n".utf8))
                return
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
            let compiledThread2 = Thread {
              pool.withAcquiredSlot {
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

                // Bind terminal capabilities so ARO observer code can use <terminal: columns>
                bindTerminalToContext(contextHandle)

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
              }
            }
            compiledThread2.stackSize = 8 * 1024 * 1024
            compiledThread2.start()
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

// MARK: - State Transition Handler Registration

/// Register a StateTransition handler for compiled binaries.
///
/// Subscribes to DomainEvent("StateTransition") co-published by AcceptAction,
/// filters by `payload["toState"] == guardValue`, then invokes the compiled handler.
///
/// - Parameters:
///   - runtimePtr: Runtime handle
///   - guardKeyPtr: The field to filter on (typically "toState")
///   - guardValuePtr: The required value for that field (e.g. "submitted")
///   - handlerFuncPtr: Compiled LLVM handler function pointer
@_cdecl("aro_runtime_register_state_transition_handler")
public func aro_runtime_register_state_transition_handler(
    _ runtimePtr: UnsafeMutableRawPointer?,
    _ guardKeyPtr: UnsafePointer<CChar>?,
    _ guardValuePtr: UnsafePointer<CChar>?,
    _ handlerFuncPtr: UnsafeMutableRawPointer?
) {
    guard let runtimePtr = runtimePtr,
          let guardKeyPtr = guardKeyPtr,
          let guardValuePtr = guardValuePtr,
          let handlerFuncPtr = handlerFuncPtr else {
        print("[RuntimeBridge] ERROR: Invalid parameters to aro_runtime_register_state_transition_handler")
        return
    }

    let runtimeHandle = Unmanaged<AROCRuntimeHandle>.fromOpaque(runtimePtr).takeUnretainedValue()
    let guardKey = String(cString: guardKeyPtr)
    let guardValue = String(cString: guardValuePtr)
    let handlerAddress = Int(bitPattern: handlerFuncPtr)

    // Subscribe to DomainEvent("StateTransition") co-published by AcceptAction
    runtimeHandle.runtime.registerCompiledHandler(
        eventType: "StateTransition",
        handlerName: "StateTransition Handler<\(guardKey):\(guardValue)>"
    ) { @Sendable event in
        // Apply guard: only fire if payload[guardKey] == guardValue
        guard let fieldValue = event.payload[guardKey] as? String,
              fieldValue == guardValue else { return }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let pool = CompiledExecutionPool.shared
            let compiledThread3 = Thread {
              pool.withAcquiredSlot {
                let handlerName = "StateTransition Handler<\(guardKey):\(guardValue)>"
                let contextHandle = AROCContextHandle(runtime: runtimeHandle, featureSetName: handlerName)

                // Bind event payload — handlers extract with: Extract the <x> from the <event: x>
                contextHandle.context.bind("event", value: event.payload)
                for (k, v) in event.payload {
                    contextHandle.context.bind("event:\(k)", value: v)
                }

                bindTerminalToContext(contextHandle)

                let contextPtr = Unmanaged.passRetained(contextHandle).toOpaque()

                guard let handlerPtrReconstructed = UnsafeMutableRawPointer(bitPattern: handlerAddress) else {
                    print("[RuntimeBridge] ERROR: Invalid handler pointer for StateTransition handler")
                    Unmanaged<AROCContextHandle>.fromOpaque(contextPtr).release()
                    continuation.resume()
                    return
                }

                typealias HandlerFunc = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
                let handlerFunc = unsafeBitCast(handlerPtrReconstructed, to: HandlerFunc.self)
                let result = handlerFunc(contextPtr)

                let duration = Date().timeIntervalSince(Date()) * 1000
                runtimeHandle.runtime.eventBus.publish(FeatureSetCompletedEvent(
                    featureSetName: handlerName,
                    businessActivity: "StateTransition Handler",
                    executionId: contextHandle.context.executionId,
                    success: true,
                    durationMs: duration
                ))

                if let resultPtr = result { aro_value_free(resultPtr) }
                Unmanaged<AROCContextHandle>.fromOpaque(contextPtr).release()
                continuation.resume()
              }
            }
            compiledThread3.stackSize = 8 * 1024 * 1024
            compiledThread3.start()
        }
    }
}

// MARK: - Notification Handler Registration

/// Register a NotificationSent handler for compiled binaries.
///
/// Subscribes to DomainEvent("NotificationSent") co-published by NotifyAction,
/// evaluates the `whenCondition` expression (if provided) against the payload fields,
/// then invokes the compiled handler.
///
/// - Parameters:
///   - runtimePtr: Runtime handle
///   - handlerFuncPtr: Compiled LLVM handler function pointer
///   - whenConditionPtr: Serialized JSON of the `when` expression (nullable — nil means always fire)
@_cdecl("aro_runtime_register_notification_handler")
public func aro_runtime_register_notification_handler(
    _ runtimePtr: UnsafeMutableRawPointer?,
    _ handlerFuncPtr: UnsafeMutableRawPointer?,
    _ whenConditionPtr: UnsafePointer<CChar>?
) {
    guard let runtimePtr = runtimePtr,
          let handlerFuncPtr = handlerFuncPtr else {
        print("[RuntimeBridge] ERROR: Invalid parameters to aro_runtime_register_notification_handler")
        return
    }

    let runtimeHandle = Unmanaged<AROCRuntimeHandle>.fromOpaque(runtimePtr).takeUnretainedValue()
    let whenCondition: String? = whenConditionPtr.map { String(cString: $0) }
    let handlerAddress = Int(bitPattern: handlerFuncPtr)

    runtimeHandle.runtime.registerCompiledHandler(
        eventType: "NotificationSent",
        handlerName: "NotificationSent Handler"
    ) { @Sendable event in
        // Evaluate when condition if present. The condition JSON is
        // compiler-generated, so a parse failure is a codegen bug: skipping
        // silently would drop the event with no trace — log before skipping.
        if let condition = whenCondition, !condition.isEmpty {
            guard let conditionData = condition.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: conditionData, options: []) as? [String: Any] else {
                FileHandle.standardError.write(Data("[RuntimeBridge] Warning: unparseable when-condition for NotificationSent Handler, event skipped: \(condition)\n".utf8))
                return
            }

            // Bind payload fields directly so `when <age> >= 16` resolves `age` from the target object
            let tempContext = RuntimeContext(
                featureSetName: "NotificationSent Handler",
                businessActivity: "NotificationSent Handler",
                eventBus: runtimeHandle.runtime.eventBus
            )
            for (k, v) in event.payload {
                tempContext.bind(k, value: v)
            }

            let conditionResult = evaluateExpressionJSON(parsed, context: tempContext)
            let passes: Bool
            if let b = conditionResult as? Bool { passes = b }
            else if let i = conditionResult as? Int { passes = i != 0 }
            else { passes = false }
            guard passes else { return }
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let pool = CompiledExecutionPool.shared
            let compiledThread4 = Thread {
              pool.withAcquiredSlot {
                let handlerName = "NotificationSent Handler"
                let contextHandle = AROCContextHandle(runtime: runtimeHandle, featureSetName: handlerName)

                // Bind event payload — handler extracts with: Extract the <user> from the <event: user>
                contextHandle.context.bind("event", value: event.payload)
                for (k, v) in event.payload {
                    contextHandle.context.bind("event:\(k)", value: v)
                    // Also bind directly so feature-set-level when guards can evaluate payload fields
                    // e.g. `(Handler: NotificationSent Handler) when <age> >= 16` needs `age` in context
                    contextHandle.context.bind(k, value: v)
                }

                bindTerminalToContext(contextHandle)

                let contextPtr = Unmanaged.passRetained(contextHandle).toOpaque()

                guard let handlerPtrReconstructed = UnsafeMutableRawPointer(bitPattern: handlerAddress) else {
                    print("[RuntimeBridge] ERROR: Invalid handler pointer for NotificationSent handler")
                    Unmanaged<AROCContextHandle>.fromOpaque(contextPtr).release()
                    continuation.resume()
                    return
                }

                typealias HandlerFunc = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
                let handlerFunc = unsafeBitCast(handlerPtrReconstructed, to: HandlerFunc.self)
                let result = handlerFunc(contextPtr)

                let duration = Date().timeIntervalSince(Date()) * 1000
                runtimeHandle.runtime.eventBus.publish(FeatureSetCompletedEvent(
                    featureSetName: handlerName,
                    businessActivity: "NotificationSent Handler",
                    executionId: contextHandle.context.executionId,
                    success: true,
                    durationMs: duration
                ))

                if let resultPtr = result { aro_value_free(resultPtr) }
                Unmanaged<AROCContextHandle>.fromOpaque(contextPtr).release()
                continuation.resume()
              }
            }
            compiledThread4.stackSize = 8 * 1024 * 1024
            compiledThread4.start()
        }
    }
}
