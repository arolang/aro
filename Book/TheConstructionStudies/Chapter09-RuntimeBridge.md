# Chapter 9: Runtime Bridge

## The Three-Layer Architecture

Compiled ARO binaries need to call Swift runtime code. LLVM generates native code that can call C functions. Swift can expose functions to C via `@_cdecl`. This creates a three-layer bridge.

- **Layer 1**: LLVM IR calls C-named functions (`@aro_action_extract`, `@aro_variable_bind_string`, etc.)
- **Layer 2**: `@_cdecl` wrappers receive C types, convert to Swift, and call Swift actions
- **Layer 3**: Swift actions execute with full runtime access

The bridge used to be its own module, `AROCRuntime`, with one large `RuntimeBridge.swift` at its head. Both are gone: the C surface was folded into `ARORuntime` — which is now a static library exporting C symbols — and the monolith was split by concern. Fourteen files, about 9,400 lines, and **248 `@_cdecl` functions** across the module. The name survives only as a `[RuntimeBridge]` log prefix.

The bridge code lives in `Sources/ARORuntime/Bridge/`:

| File | Purpose |
|------|---------|
| `RuntimeCoreBridge.swift` | Handles: `AROCRuntimeHandle`, `AROCContextHandle`, `AROCValue`; lifecycle |
| `RuntimeExecutionBridge.swift` | Feature-set entry, variable ops, expression-JSON evaluation |
| `ActionBridge.swift` | The action verbs exposed via `@_cdecl` — 68 of the module's 248 |
| `ServiceBridge.swift` | The native HTTP server, static-plugin registration, file/socket services |
| `RuntimeEventRecordingBridge.swift` | Handler registration and event recording |
| `AROFuture.swift` | The async/sync boundary: futures and `ActionTaskExecutor` |
| `LazyActionPolicy.swift` | Which verbs may defer (ARO-0088) |
| `SocketBridge.swift`, `FileSystemBridge.swift`, `FileWatcherBridge.swift`, `HTTPClientBridge.swift`, `HTTPServerBridge.swift` | Per-service C surfaces |

```
LLVM-Generated Code (native)
        ↓ C calling convention
  @_cdecl Functions (Swift)
        ↓ Swift method calls
   Swift Runtime (Swift)
```

<svg viewBox="0 0 600 350" xmlns="http://www.w3.org/2000/svg">
  <style>
    .box { fill: #f5f5f5; stroke: #333; stroke-width: 1.5; }
    .llvm { fill: #e8f4e8; }
    .bridge { fill: #f4e8e8; }
    .swift { fill: #e8e8f4; }
    .arrow { fill: none; stroke: #333; stroke-width: 1.5; marker-end: url(#arrow24); }
    .label { font-family: monospace; font-size: 10px; fill: #333; }
    .title { font-family: monospace; font-size: 11px; fill: #333; font-weight: bold; }
  </style>

  <defs>
    <marker id="arrow24" markerWidth="8" markerHeight="6" refX="7" refY="3" orient="auto">
      <polygon points="0 0, 8 3, 0 6" fill="#333"/>
    </marker>
  </defs>

  <!-- LLVM Generated Code -->
  <rect x="30" y="30" width="250" height="80" rx="5" class="box llvm"/>
  <text x="155" y="55" class="title" text-anchor="middle">LLVM-Generated Code</text>
  <text x="40" y="75" class="label">call ptr @aro_action_log(...)</text>
  <text x="40" y="90" class="label">call ptr @aro_variable_bind_string(...)</text>
  <text x="40" y="105" class="label">call ptr @aro_context_create(...)</text>

  <!-- Bridge Layer -->
  <rect x="30" y="140" width="250" height="80" rx="5" class="box bridge"/>
  <text x="155" y="165" class="title" text-anchor="middle">@_cdecl Bridge Functions</text>
  <text x="40" y="185" class="label">@_cdecl("aro_action_log")</text>
  <text x="40" y="200" class="label">public func aro_action_log(...)</text>
  <text x="40" y="215" class="label">  → executeSyncWithResult()</text>

  <!-- Swift Runtime -->
  <rect x="30" y="250" width="250" height="80" rx="5" class="box swift"/>
  <text x="155" y="275" class="title" text-anchor="middle">Swift Runtime</text>
  <text x="40" y="295" class="label">ActionRegistry, ActionImplementation</text>
  <text x="40" y="310" class="label">RuntimeContext, EventBus</text>
  <text x="40" y="325" class="label">Services (HTTP, File, Socket)</text>

  <!-- Type conversion side panel -->
  <rect x="320" y="30" width="250" height="300" rx="5" class="box"/>
  <text x="445" y="55" class="title" text-anchor="middle">Type Conversions</text>

  <text x="330" y="80" class="label">LLVM → C</text>
  <text x="340" y="95" class="label">ptr → UnsafeMutableRawPointer</text>
  <text x="340" y="110" class="label">i64 → Int64</text>
  <text x="340" y="125" class="label">ptr → UnsafePointer&lt;CChar&gt;</text>

  <text x="330" y="155" class="label">C → Swift</text>
  <text x="340" y="170" class="label">String(cString: ptr)</text>
  <text x="340" y="185" class="label">Unmanaged.fromOpaque(ptr)</text>
  <text x="340" y="200" class="label">ptr.load(as: T.self)</text>

  <text x="330" y="230" class="label">Swift → C</text>
  <text x="340" y="245" class="label">Unmanaged.passRetained(obj)</text>
  <text x="340" y="260" class="label">.toOpaque()</text>
  <text x="340" y="275" class="label">boxResult(value)</text>

  <!-- Arrows -->
  <path d="M 155 110 L 155 140" class="arrow"/>
  <path d="M 155 220 L 155 250" class="arrow"/>
</svg>

**Figure 9.1**: Three-layer bridge architecture. LLVM code calls C functions, which call Swift methods.

---

## The @_cdecl Attribute

Every action in the runtime is exposed as a `@_cdecl` function — a C-callable Swift function. The name mangling follows a simple pattern: `aro_action_{verbname}`. This is what the generated LLVM IR calls.

The action verbs have thin wrappers that delegate to a shared `ActionRunner`. The wrapper's job is to receive C pointers, convert them to Swift types, invoke the action, and box the result for return.

---

## Handle Management

The bridge uses opaque `UnsafeRawPointer` handles to pass Swift objects to C. There are three kinds:

| Handle | Type | Wraps |
|--------|------|-------|
| Runtime handle | `AROCRuntimeHandle` | The `Runtime`, the context table, the store-flush service, a lazy `MultiThreadedEventLoopGroup` |
| Context handle | `AROCContextHandle` | One `RuntimeContext`, a back-reference to the runtime, a per-invocation `ActionDriverChannel`, and strong refs to the services it must keep alive |
| Value box | `AROCValue` | A lock-guarded `any Sendable` |

Descriptors are *not* on that list, which is easy to get wrong. `ResultDescriptor` and `ObjectDescriptor` never cross as handles — they cross as stack-allocated C structs the code generator fills in per statement (`DescriptorBuilder`). Only things with lifetimes get handles.

Per-service handles follow the same pattern where a service must outlive a call: `HTTPServerHandle`, `HTTPRequestHandle`, `HTTPResponseHandle`, `SocketHandle`, and three platform-gated definitions of `FileWatcherHandle`.

Swift objects cannot be passed to C directly — C doesn't know their size or layout. So we allocate them with `Unmanaged.passRetained()`, which hands us an opaque pointer the C side can store and pass back. A global registry keeps those objects alive (prevents ARC from freeing them). When the C side is done, it calls a cleanup function, which releases the retain.

<svg viewBox="0 0 600 200" xmlns="http://www.w3.org/2000/svg">
  <style>
    .box { fill: #f5f5f5; stroke: #333; stroke-width: 1.5; }
    .handle { fill: #e8f4e8; }
    .arrow { fill: none; stroke: #333; stroke-width: 1.5; marker-end: url(#arrow25); }
    .label { font-family: monospace; font-size: 10px; fill: #333; }
    .title { font-family: monospace; font-size: 11px; fill: #333; font-weight: bold; }
  </style>

  <defs>
    <marker id="arrow25" markerWidth="8" markerHeight="6" refX="7" refY="3" orient="auto">
      <polygon points="0 0, 8 3, 0 6" fill="#333"/>
    </marker>
  </defs>

  <!-- LLVM side -->
  <rect x="30" y="30" width="150" height="60" rx="5" class="box"/>
  <text x="105" y="55" class="title" text-anchor="middle">LLVM Code</text>
  <text x="40" y="75" class="label">%runtime: ptr</text>

  <!-- Global registry -->
  <rect x="220" y="30" width="160" height="140" rx="5" class="box"/>
  <text x="300" y="55" class="title" text-anchor="middle">Global Registry</text>
  <text x="230" y="80" class="label">runtimeHandles:</text>
  <rect x="235" y="90" width="130" height="30" rx="3" class="handle"/>
  <text x="300" y="110" class="label" text-anchor="middle">0x7fff... → Handle</text>
  <rect x="235" y="125" width="130" height="30" rx="3" class="handle"/>
  <text x="300" y="145" class="label" text-anchor="middle">0x8000... → Handle</text>

  <!-- Swift object -->
  <rect x="420" y="30" width="150" height="140" rx="5" class="box handle"/>
  <text x="495" y="55" class="title" text-anchor="middle">AROCRuntimeHandle</text>
  <text x="430" y="80" class="label">runtime: Runtime</text>
  <text x="430" y="100" class="label">contexts: [ptr: ctx]</text>
  <text x="430" y="120" class="label">eventLoopGroup: ...</text>

  <!-- Arrows -->
  <path d="M 180 60 L 220 60" class="arrow"/>
  <text x="183" y="53" class="label">lookup</text>
  <path d="M 380 105 L 420 105" class="arrow"/>
  <text x="383" y="98" class="label">points to</text>
</svg>

**Figure 9.2**: Handle lifecycle. Opaque pointers index into a global registry that holds Swift objects.

---

## Descriptor Conversion

Incoming C descriptor structs are converted to Swift `ResultDescriptor` and `ObjectDescriptor` values. This is mechanical — copy the string pointers, reconstruct arrays from pointer+count pairs.

The tricky part is alignment. The `AROObjectDescriptor` C struct has this layout:

| Field | Offset | Size |
|-------|--------|------|
| `base` (ptr) | 0 | 8 bytes |
| `preposition` (int) | 8 | 4 bytes |
| *(padding)* | 12 | 4 bytes |
| `specifiers` (ptr) | 16 | 8 bytes |
| `specifier_count` (int) | 24 | 4 bytes |

**Critical insight**: The padding between `preposition` and `specifiers` must match C struct alignment rules exactly. Getting this wrong causes silent memory corruption — the sort of bug that only shows up on specific inputs.

---

## Variable Binding

Three binding helpers cover the common cases. Each takes a context handle, a name pointer, and a value, and calls into the context's `bind()` method:

| Function | Binds |
|----------|-------|
| `aro_variable_bind_string` | A UTF-8 C string |
| `aro_variable_bind_int` | An `i64` integer |
| `aro_variable_bind_dict` | A JSON string, parsed to a dictionary |

Complex types (dictionaries, arrays) cross the boundary as JSON strings. The bridge parses them on the Swift side and binds the resulting dictionary or array.

---

## Synchronous Execution

`@_cdecl` functions cannot be `async` — C has no concept of Swift concurrency. This is the fundamental tension of the C bridge: a synchronous wrapper around an async action.

The first answer was the obvious one — start the work on the cooperative executor, block the calling thread on a `DispatchSemaphore`. It worked and it deadlocked. Swift's cooperative pool has a fixed thread count; a cascading event chain could fill it with blocked pthreads, each waiting for a continuation that needed one of those very threads to run.

Two changes fixed it, and they are separable.

**Change the pool.** `AROFuture`'s underlying `Task` is created with `executorPreference: ActionTaskExecutor.shared`, a custom `TaskExecutor` over GCD's `global(qos: .userInitiated)` queue. GCD's pool is elastic: under load it spawns more threads. So a blocked forcer can no longer starve the work that would unblock it — which is the property the cooperative pool cannot offer and the reason for the whole exercise.

**Change the wait primitive.** Results are handed over through a `DispatchGroup`, not a semaphore, and the difference is not stylistic. `group.enter()` happens in the future's `init`; `group.leave()` happens exactly once when the result lands; `group.wait()` wakes *every* current and future waiter. A `DispatchSemaphore.signal()` releases one. For a value any number of consumers may force — including from C pthreads — the group is the correct primitive and the semaphore is a bug waiting for a second reader.

Semaphores have not vanished. They are still the mechanism at the older one-shot call sites across `RuntimeExecutionBridge`, `ServiceBridge`, `HTTPClientBridge` and `FileWatcherBridge`, where a single caller waits for a single answer and the fan-out problem does not arise. Describing the bridge as "semaphore-based" is a half-truth worth avoiding: futures resolve through a group on an elastic executor, and semaphores bridge the simple calls that never needed more.

---

## Handler Registration

Compiled binaries register event handlers by passing function pointers to the runtime. The runtime subscribes to the event bus, and when a matching event arrives, it reconstructs the function pointer and calls the compiled handler. The calling convention for all handlers is the same: receive a context pointer, return a result pointer.

There are exactly three `aro_runtime_register_*` entry points, all in `RuntimeEventRecordingBridge.swift`:

| Function | Registers |
|----------|-----------|
| `aro_runtime_register_handler` | a domain event type by name |
| `aro_runtime_register_state_transition_handler` | a state transition, with an optional guard key/value |
| `aro_runtime_register_notification_handler` | a notification handler, with an optional `when`-condition string |

Alongside them sit the `aro_register_*` family for everything that is not an event subscription: `aro_register_user_action` (ARO-0081), `aro_register_repository_observer` and its guarded variant, `aro_register_feature_set_metadata`, `aro_http_register_route`, and three plugin-registration entries.

This is the most fragile part of the bridge. Function pointer casting through `unsafeBitCast` is not checked at runtime. A mismatch in calling convention or parameter count will silently corrupt memory or crash.

---

## Value Boxing

Values returned from actions to the C side are wrapped in reference-counted containers. The bridge allocates a box, stores the value, and returns the box's opaque pointer. When the generated code no longer needs the value, it calls `aro_value_free`, which releases the retain and lets ARC collect the box.

This is a manual reference counting layer on top of Swift's automatic reference counting. The generated code must always pair every value-returning call with a corresponding free — a discipline enforced by the code generator, not the type system.

---

## Platform-Specific Type Handling

JSON deserialization behaves differently on Darwin and Linux, and the difference matters for booleans:

| Platform | Boolean representation | Issue |
|----------|----------------------|-------|
| Darwin (macOS) | `UInt8` via `CFBooleanGetTypeID()` | Correct — reliable detection |
| Linux | `Int32` via `objCType` check | Different — must extract as `Int32` |

On Darwin, JSON booleans can be identified by checking their Core Foundation type ID. On Linux, that API is not available, so the bridge checks the Objective-C type encoding string instead. Getting this wrong means booleans silently become integers, which breaks `when` guards and `match` expressions.

---

## Two HTTP Servers, and Why

SwiftNIO does not work in compiled binaries. Swift's type metadata for NIO's internal socket channel types is not available when the Swift runtime is initialized from LLVM-compiled code, and the crash lands in `_swift_allocObject_` with a null metadata pointer.

The bridge does not try to survive this; it refuses to walk into it. `AROCRuntimeHandle` deliberately leaves `httpServer` and `socketServer` `nil`, with the reasoning written above the assignment. Compiled binaries get `NativeHTTPServer` instead — a BSD-socket server living in `ServiceBridge.swift`, started by `aro_native_http_server_start_with_openapi()`, which `StartAction` calls when it finds no `HTTPServerService` registered.

So there are two HTTP server implementations, one per mode, and it is worth being precise about what that costs, because "HTTP doesn't work in compiled binaries" is a claim this book used to make and it is not true. The native server routes from the embedded OpenAPI contract, speaks WebSocket, streams request bodies through a bounded channel with backpressure, enforces per-route `x-aro-max-body` limits, and answers `413` with the same wording as the NIO server (ARO-0090 §10). The `FileUpload` example builds a binary and runs every one of those checks against it.

The honest gaps are narrower and specific: `Transfer-Encoding: chunked` request bodies are not implemented in the native server, which frames by `Content-Length` only; and on Windows the FlyingFox path cannot stream a body at all. Both are recorded in ARO-0090 §11.

The related constraint is the same family of problem. `ManagedAtomic` from `swift-atomics` causes SIGSEGV in compiled binaries. Any library that leans on Swift's metadata infrastructure at initialization time may hit this, and the pattern for dealing with it is the one above: detect at bring-up, substitute a plainer implementation, and write down which capability you gave up.

---

## Chapter Summary

The runtime bridge is the most mechanically complex part of ARO's native compilation story. Here is what it does:

1. **`@_cdecl`** exports Swift functions with C calling conventions — one per action verb
2. **Opaque pointer handles** wrap Swift objects so C code can hold and pass them
3. **Manual offset calculations** convert C structs to Swift `ResultDescriptor`/`ObjectDescriptor` values
4. **Futures on an elastic executor** make async actions synchronous at the boundary — a `DispatchGroup` for fan-out, GCD rather than the cooperative pool so a blocked forcer cannot starve its own unblocking
5. **Function pointer casting** enables compiled handler callbacks
6. **Value boxing** provides reference-counted return values to the C side
7. **Platform-specific code** handles Darwin/Linux boolean representation differences
8. **Native socket HTTP** replaces SwiftNIO, which cannot initialize correctly in this context — with contract routing, WebSocket, and streamed bodies, but no chunked transfer encoding

The bridge is the most fragile part of native compilation. Memory layout assumptions, pointer casting, and synchronization all create potential failure modes that the interpreter path avoids entirely. If stability matters more than startup time, use the interpreter. If you need a self-contained binary, the bridge is the price of admission.

Implementation references:
- `Sources/ARORuntime/Bridge/RuntimeCoreBridge.swift` — handles, lifecycle, context management
- `Sources/ARORuntime/Bridge/RuntimeExecutionBridge.swift` — feature-set entry, variables, expression JSON
- `Sources/ARORuntime/Bridge/ActionBridge.swift` — the action `@_cdecl` exports
- `Sources/ARORuntime/Bridge/AROFuture.swift` — futures and `ActionTaskExecutor`
- `Sources/ARORuntime/Bridge/ServiceBridge.swift` — the native HTTP server and service bridges

---

*Next: Chapter 10 — Critical Assessment*
