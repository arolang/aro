# Chapter 11: Dual-Mode Execution Parity

## What This Chapter Is

ARO programs can run in two modes: interpreted (`aro run`) and compiled (`aro build`). In theory, they should produce identical results. In practice, they share most infrastructure but diverge in subtle ways that are hard to detect until tests fail silently.

This chapter documents the sources of divergence, the systematic fixes applied, and the architectural patterns that prevent future drift.

---

## The Divergence Problem

The interpreter and binary paths share `ActionRegistry.shared`, `RuntimeContext`, and `EventBus.shared`. But two key subsystems have entirely separate implementations:

**Event dispatch**: The interpreter uses Swift typed events (`FileCreatedEvent`, `StateTransitionEvent`, etc.) routed through `EventBus.subscribe(to:)`. The compiled binary uses `DomainEvent` (an event type string plus a `[String: any Sendable]` payload dictionary) routed through `aro_runtime_register_handler`.

**Expression evaluation**: The interpreter evaluates expressions in `ExpressionEvaluator.swift` (Swift). The compiled binary evaluates them in `evaluateBinaryOp()` in `RuntimeBridge.swift` (also Swift, but a separate implementation with different behavior for edge cases).

This separation is necessary — the compiled binary cannot execute arbitrary Swift closures — but it creates a gap that widens every time a new feature is added to only one path.

---

## Source of Divergence 1: Verb Sets

### The Problem

`FeatureSetExecutor.executeAROStatement()` classifies verbs into sets to decide whether a statement needs execution or can be skipped. These sets were defined inline as local `let` declarations:

```swift
// Before — local to FeatureSetExecutor (lines 304–317)
let testVerbs: Set<String> = ["then", "assert"]
let requestVerbs: Set<String> = ["call", "invoke"]
let updateVerbs: Set<String> = ["update", "modify", "change", "set"]
// ... 7 more sets
```

Because these were local, any code that needed to classify verbs elsewhere had to duplicate the sets or remain inconsistent.

### The Fix

`Sources/ARORuntime/Core/VerbSets.swift` extracts the sets into a shared public enum:

```swift
public enum VerbSets {
    public static let testVerbs:     Set<String> = ["then", "assert"]
    public static let requestVerbs:  Set<String> = ["call", "invoke"]
    public static let updateVerbs:   Set<String> = ["update", "modify", "change", "set"]
    public static let createVerbs:   Set<String> = ["create", "make", "build", "construct"]
    public static let mergeVerbs:    Set<String> = ["merge", "combine", "join", "concat"]
    public static let computeVerbs:  Set<String> = ["compute", "calculate", "derive"]
    public static let extractVerbs:  Set<String> = ["extract", "parse", "get"]
    public static let queryVerbs:    Set<String> = ["filter", "map", "reduce", "aggregate", "split"]
    public static let responseVerbs: Set<String> = ["write", "read", "store", "save", "persist",
                                                     "log", "print", "send", "emit", "notify",
                                                     "alert", "signal", "broadcast"]
    public static let serverVerbs:   Set<String> = ["start", "stop", "restart", "keepalive",
                                                     "schedule", "stream", "subscribe",
                                                     "sleep", "delay", "pause"]
}
```

`FeatureSetExecutor` now references these via `VerbSets.testVerbs` etc. Any future code that classifies verbs has a single authoritative source.

---

## Source of Divergence 2: Integer Division

### The Problem

Integer division produced different results in the two modes.

**Interpreter** (`ExpressionEvaluator.swift`, `.divide` case):

```swift
// Before fix — always returned Double via numericOperation
case .divide:
    return try numericOperation(left, right) { $0 / $1 }
```

This meant `7 / 2` evaluated to `3.5` in interpreter mode.

**Binary** (`RuntimeBridge.swift`, `evaluateBinaryOp()`):

```swift
case "/":
    if let li = left as? Int, let ri = right as? Int {
        guard ri != 0 else { return 0 }
        return li / ri  // Integer floor division → 3
    }
    // ... fallback to double
```

### The Fix

The interpreter now matches the binary behavior: Int/Int returns Int.

```swift
case .divide:
    // Int/Int → integer floor division (matches binary mode evaluateBinaryOp behavior)
    if let li = left as? Int, let ri = right as? Int {
        guard ri != 0 else { return 0 }
        return li / ri
    }
    return try numericOperation(left, right) { $0 / $1 }
```

This is a behavioral change: ARO integer division now truncates toward zero, consistent with most languages.

---

## Source of Divergence 3: Event Handler Registration

### The Architecture

The interpreter registers event handlers during program startup by subscribing Swift closures to typed events:

```swift
// Interpreter — ExecutionEngine.registerNotificationEventHandlers
eventBus.subscribe(to: NotificationSentEvent.self) { event in
    // evaluate when condition, then execute feature set
}
```

The compiled binary cannot use Swift closures at the C ABI boundary. Instead, `LLVMCodeGenerator` emits calls to C-callable registration functions at program startup, passing a function pointer to the compiled feature set:

```
// Generated LLVM IR (pseudocode)
call void @aro_runtime_register_notification_handler(
    runtime_ptr,
    handler_func_ptr,
    when_condition_json_ptr
)
```

### The DomainEvent Co-Publishing Pattern

For the binary path to receive events, every action that fires a typed event must also publish a `DomainEvent` to `EventBus.shared`. The `registerCompiledHandler` function in `RuntimeBridge.swift` subscribes to these `DomainEvents` and calls the compiled handler function.

**Pattern** (applies to all event-generating actions):

```swift
// 1. Publish typed event for interpreter handlers
if let eventBus = context.eventBus {
    await eventBus.publishAndTrack(MyTypedEvent(/* ... */))
} else {
    context.emit(MyTypedEvent(/* ... */))
}

// 2. Co-publish DomainEvent for binary mode handlers
// DomainEvent eventType: "MyEventType"
// DomainEvent payload:   { "key1": Value, "key2": Value, ... }
EventBus.shared.publish(DomainEvent(eventType: "MyEventType", payload: [
    "key1": value1,
    "key2": value2
]))
```

### Payload Schemas

Each event type has a defined payload schema. These are documented in comments at each callsite:

| Event Type | Payload Keys |
|------------|--------------|
| `StateTransition` | `fromState: String`, `toState: String`, `fieldName: String`, `objectName: String`, `entityId: String?` |
| `NotificationSent` | `message: String`, `target: String`, `user: targetObj`, `[targetName]: targetObj`, plus all target object fields spread at top level |
| `file.created` / `file.modified` / `file.deleted` | `path: String` |
| `websocket.connected` | `connectionId: String`, `path: String`, `remoteAddress: String` |
| `websocket.disconnected` | `connectionId: String`, `reason: String` |
| `websocket.message` | `connectionId: String`, `message: String` |
| `socket.connected` | `connection: { id: String, remoteAddress: String }` |
| `socket.data` | `packet: { message: String, buffer: String, data: String, connection: String }` |
| `socket.disconnected` | `event: { connectionId: String, reason: String }` |
| `KeyPress` | `key: String` |

---

## The Handler Registration Pattern

Every new event type requires a corresponding `aro_runtime_register_*` function. All follow this template in `RuntimeBridge.swift`:

```swift
@_cdecl("aro_runtime_register_my_event_handler")
public func aro_runtime_register_my_event_handler(
    _ runtimePtr: UnsafeMutableRawPointer?,   // runtime handle
    _ guardParamPtr: UnsafePointer<CChar>?,   // optional guard (nullable)
    _ handlerFuncPtr: UnsafeMutableRawPointer? // compiled function pointer
) {
    guard let runtimePtr, let handlerFuncPtr else { return }
    let runtimeHandle = Unmanaged<AROCRuntimeHandle>.fromOpaque(runtimePtr).takeUnretainedValue()
    let handlerAddress = Int(bitPattern: handlerFuncPtr)

    runtimeHandle.runtime.registerCompiledHandler(
        eventType: "MyEventType",
        handlerName: "My Handler"
    ) { @Sendable event in
        // 1. Evaluate guard condition (if any)
        // 2. Run handler on pthread (NOT GCD — avoids 64-thread limit)
        await withCheckedContinuation { continuation in
            Thread {
                let contextHandle = AROCContextHandle(runtime: runtimeHandle,
                                                       featureSetName: "My Handler")
                // Bind event payload to context
                contextHandle.context.bind("event", value: event.payload)
                for (k, v) in event.payload {
                    contextHandle.context.bind("event:\(k)", value: v)
                }
                // Execute compiled handler
                let handlerFunc = unsafeBitCast(/* reconstructed ptr */,
                                                to: HandlerFunc.self)
                let result = handlerFunc(contextPtr)
                // Cleanup
                continuation.resume()
            }.start()
        }
    }
}
```

**Why pthreads, not GCD?** GCD's cooperative thread pool has a 64-thread limit. During intensive event processing (many events firing handlers concurrently), GCD deadlocks when all 64 threads are blocked waiting for continuation resumes. Foundation `Thread` bypasses this limit. The `CompiledExecutionPool.shared` semaphore prevents unbounded thread creation.

The three-step pattern for every new event handler:

1. **`LLVMExternalDeclEmitter.swift`**: Declare the C function with LLVM types
2. **`LLVMCodeGenerator.registerEventHandlers`**: Detect the business activity pattern and emit the registration call
3. **`RuntimeBridge.swift`**: Implement the `@_cdecl` function

---

## The `when` Guard: Interpreter vs Binary

Handler feature sets can have a `when` guard:

```aro
(Greet User: NotificationSent Handler) when <age> >= 16 {
    (* ... *)
}
```

**Interpreter**: `ExecutionEngine` evaluates this expression inline using `ExpressionEvaluator` with the target object's fields bound to context.

**Binary**: `LLVMCodeGenerator` serializes the `whenCondition` AST node to JSON using `serializeExpression()`:

```json
{"$binary":{"op":">=","left":{"$var":"age"},"right":{"$literal":16}}}
```

This JSON is passed as a string constant to the registration function. At runtime, `evaluateExpressionJSON()` in `RuntimeBridge.swift` deserializes and evaluates it against a `RuntimeContext` populated with the event payload.

This means the binary `when` guard evaluates against a flat payload dictionary, so the payload must spread the target object's fields at top level.

---

## Test Coverage: The mode: both Directive

Every `test.hint` file has a `mode` field:

| Value | Meaning |
|-------|---------|
| `both` | Run in interpreter and compiled binary modes, compare output |
| `interpreter` | Run interpreter only (binary mode unsupported) |

Out of 85 examples, **81 currently run in `mode: both`** (including the default, which is `both`). The 4 interpreter-only examples have open issues:

| Example | Issue | Root Cause |
|---------|-------|------------|
| `SocketClient` | #134 | `AROSocketClient` uses `ManagedAtomic<Bool>` → SIGSEGV in binary |
| `MultiService` | #134 | Depends on SocketClient fix |
| `Scoping` | #135 | `AppReady Handler` event payload structure differs in binary mode |
| `EventReplay` | #136 | `EventRecorder.swift` not implemented in C bridge |

The `occurrence-check: true` hint enables order-independent output comparison, which is essential for event handlers that fire asynchronously in binary mode.

---

## Verification Checklist for New Event Types

When adding a new action that fires events:

1. **Add DomainEvent co-publish** after the typed event publish
2. **Document the payload schema** with a `// DomainEvent eventType:  payload:` comment
3. **Add `@_cdecl` registration function** in `RuntimeBridge.swift`
4. **Declare the extern** in `LLVMExternalDeclEmitter.swift`
5. **Detect the business activity** in `LLVMCodeGenerator.registerEventHandlers` (before generic `hasSuffix(" Handler")`)
6. **Spread guard fields** into the DomainEvent payload if the handler has a `when` condition
7. **Add or update an example** with `mode: both` and `occurrence-check: true`
8. **Run** `swift build -c release && ./test-examples.pl`

---

## Lessons

**Silent divergence is the worst kind of bug.** A binary that produces wrong results without crashing is harder to diagnose than one that crashes immediately. The `mode: both` test directive is the primary defense: any behavioral difference between interpreter and binary becomes a test failure.

**Co-publishing is cheaper than unification.** A clean architectural solution would use a single event system for both modes. In practice, the typed event system is deeply integrated with the interpreter (closures, `async/await`, `publishAndTrack`), while the binary needs C-callable, pthread-compatible registration. DomainEvent co-publishing bridges the two worlds with minimal coupling and no breaking changes.

**Payload schemas are contracts.** The `// DomainEvent payload:` comments are not just documentation — they define the interface between the action that fires the event and the `RuntimeBridge` function that receives it. When the payload changes, both sides must be updated atomically.
