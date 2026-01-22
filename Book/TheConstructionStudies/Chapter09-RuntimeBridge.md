# Chapter 9: Runtime Bridge

## The Three-Layer Architecture

Compiled ARO binaries need to call Swift runtime code. LLVM generates native code that can call C functions. Swift can expose functions to C via `@_cdecl`. This creates a three-layer bridge.

The bridge code lives in `Sources/ARORuntime/Bridge/`:

| File | Purpose |
|------|---------|
| `RuntimeBridge.swift` | Lifecycle: init, shutdown, context management |
| `ActionBridge.swift` | All 48 actions exposed via @_cdecl |
| `ServiceBridge.swift` | HTTP server, file system, socket services |

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
  <text x="40" y="215" class="label">  → ActionRunner.shared.executeSync()</text>

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

## Handle Management

The bridge uses opaque pointers to pass Swift objects to/from C code:

```swift
/// Opaque runtime handle for C interop
final class AROCRuntimeHandle: @unchecked Sendable {
    let runtime: Runtime
    var contexts: [UnsafeMutableRawPointer: AROCContextHandle] = [:]
}

/// Opaque context handle for C interop
class AROCContextHandle {
    let context: RuntimeContext
    let runtime: AROCRuntimeHandle
}
```

Creating a handle:
```swift
@_cdecl("aro_runtime_init")
public func aro_runtime_init() -> UnsafeMutableRawPointer? {
    let handle = AROCRuntimeHandle()

    // Convert Swift object to opaque pointer
    let pointer = Unmanaged.passRetained(handle).toOpaque()

    // Store in global registry (prevents deallocation)
    handleLock.lock()
    runtimeHandles[pointer] = handle
    handleLock.unlock()

    return UnsafeMutableRawPointer(pointer)
}
```

Retrieving a handle:
```swift
@_cdecl("aro_runtime_shutdown")
public func aro_runtime_shutdown(_ runtimePtr: UnsafeMutableRawPointer?) {
    guard let ptr = runtimePtr else { return }

    // Convert opaque pointer back to Swift object
    let handle = Unmanaged<AROCRuntimeHandle>.fromOpaque(ptr).takeUnretainedValue()

    // Clean up
    handleLock.lock()
    runtimeHandles.removeValue(forKey: ptr)
    handleLock.unlock()

    // Release the retained object
    Unmanaged<AROCRuntimeHandle>.fromOpaque(ptr).release()
}
```

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

C structs are read with manual offset calculations:

```swift
/// Convert C object descriptor to Swift ObjectDescriptor
func toObjectDescriptor(_ ptr: UnsafeRawPointer) -> ObjectDescriptor {
    // C struct layout:
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

    // Account for padding: specifiers at offset 16, not 12
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

    return ObjectDescriptor(preposition: preposition, base: base, specifiers: specifiers, ...)
}
```

**Critical insight**: The padding between `preposition` (4 bytes at offset 8) and `specifiers` (pointer at offset 16) must match C struct alignment rules. Getting this wrong causes subtle memory corruption.

---

## The @_cdecl Attribute

Swift's `@_cdecl` attribute exports a function with C linkage:

```swift
@_cdecl("aro_action_extract")
public func aro_action_extract(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    return executeAction(verb: "extract", contextPtr: contextPtr,
                         resultPtr: resultPtr, objectPtr: objectPtr)
}
```

All 50 actions have thin wrappers that delegate to `ActionRunner`:

```swift
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

    // Execute through ActionRunner (same code path as interpreter)
    let actionResult = ActionRunner.shared.executeSync(
        verb: verb,
        result: resultDesc,
        object: objectDesc,
        context: ctxHandle.context
    )

    // Box result for return to C
    if let value = actionResult {
        return boxResult(value)
    }
    return boxResult("")
}
```

---

## Synchronous Execution Challenge

Actions in the interpreter are `async`. But `@_cdecl` functions cannot be `async` (C has no concept of Swift concurrency). The solution: block the calling thread:

```swift
/// Synchronous action execution for compiled binaries
public func executeSync(
    verb: String,
    result: ResultDescriptor,
    object: ObjectDescriptor,
    context: ExecutionContext
) -> (any Sendable)? {
    let semaphore = DispatchSemaphore(value: 0)
    var resultValue: (any Sendable)?

    // Run async code on a detached task
    Task.detached {
        do {
            resultValue = try await self.execute(
                verb: verb,
                result: result,
                object: object,
                context: context
            )
        } catch {
            print("[ActionRunner] Error: \(error)")
        }
        semaphore.signal()
    }

    semaphore.wait()  // Block until async completes
    return resultValue
}
```

**Warning**: This can cause deadlocks if the executor pool is exhausted. Event handlers run on GCD threads (not the Swift cooperative executor) to prevent this.

---

## Handler Registration

Compiled binaries register event handlers by passing function pointers:

```swift
@_cdecl("aro_runtime_register_handler")
public func aro_runtime_register_handler(
    _ runtimePtr: UnsafeMutableRawPointer?,
    _ eventType: UnsafePointer<CChar>?,
    _ handlerFuncPtr: UnsafeMutableRawPointer?
) {
    guard let ptr = runtimePtr,
          let eventTypeStr = eventType.map({ String(cString: $0) }),
          let handlerPtr = handlerFuncPtr else { return }

    let runtimeHandle = Unmanaged<AROCRuntimeHandle>.fromOpaque(ptr).takeUnretainedValue()

    // Capture handler address as Int (Sendable)
    let handlerAddress = Int(bitPattern: handlerPtr)

    runtimeHandle.runtime.eventBus.subscribe(to: DomainEvent.self) { event in
        guard event.domainEventType == eventTypeStr else { return }

        // CRITICAL: Run on GCD, not Swift executor
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                // Create context for handler
                let contextHandle = AROCContextHandle(runtime: runtimeHandle, ...)

                // Bind event data
                contextHandle.context.bind("event", value: event.payload)

                // Reconstruct function pointer
                guard let funcPtr = UnsafeMutableRawPointer(bitPattern: handlerAddress) else {
                    continuation.resume()
                    return
                }

                // Call compiled handler
                typealias HandlerFunc = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
                let handlerFunc = unsafeBitCast(funcPtr, to: HandlerFunc.self)
                _ = handlerFunc(contextPtr)

                continuation.resume()
            }
        }
    }
}
```

---

## Value Boxing

Values returned to C are boxed in reference-counted containers:

```swift
/// Boxed value for C interop
class AROCValue {
    let value: any Sendable

    init(value: any Sendable) {
        self.value = value
    }
}

/// Box a value for return to C
func boxResult(_ value: any Sendable) -> UnsafeMutableRawPointer {
    let boxed = AROCValue(value: value)
    return UnsafeMutableRawPointer(Unmanaged.passRetained(boxed).toOpaque())
}

/// Free a boxed value
@_cdecl("aro_value_free")
public func aro_value_free(_ valuePtr: UnsafeMutableRawPointer?) {
    guard let ptr = valuePtr else { return }
    Unmanaged<AROCValue>.fromOpaque(ptr).release()
}
```

---

## Variable Operations

The bridge provides type-specific binding functions:

```swift
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
```

Complex types (dictionaries, arrays) are passed as JSON strings:

```swift
@_cdecl("aro_variable_bind_dict")
public func aro_variable_bind_dict(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ name: UnsafePointer<CChar>?,
    _ json: UnsafePointer<CChar>?
) {
    // ... parameter validation ...

    // Parse JSON to dictionary
    guard let data = jsonStr.data(using: .utf8),
          let parsed = try? JSONSerialization.jsonObject(with: data),
          let dict = parsed as? [String: Any] else {
        // Fallback: bind as string
        contextHandle.context.bind(nameStr, value: jsonStr)
        return
    }

    // Convert to Sendable and bind
    let sendableDict = convertToSendable(dict) as? [String: any Sendable] ?? [:]
    contextHandle.context.bind(nameStr, value: sendableDict)
}
```

---

## Platform-Specific Type Handling

JSON deserialization behaves differently on Darwin vs Linux:

```swift
private func convertToSendable(_ value: Any) -> any Sendable {
    case let nsNumber as NSNumber:
        #if canImport(Darwin)
        // On Darwin, check CFBooleanGetTypeID for JSON booleans
        if CFGetTypeID(nsNumber) == CFBooleanGetTypeID() {
            return nsNumber.boolValue
        }
        #else
        // On Linux, use objCType to detect booleans
        let objCType = String(cString: nsNumber.objCType)
        if objCType == "c" || objCType == "B" {
            let intVal = nsNumber.intValue
            if intVal == 0 || intVal == 1 {
                return nsNumber.boolValue
            }
        }
        #endif
        // ...
}
```

---

## Service Registration Limitations

A critical limitation: SwiftNIO doesn't work in compiled binaries:

```swift
init(runtime: AROCRuntimeHandle, featureSetName: String) {
    // ...

    // NOTE: Do NOT register AROHTTPServer (NIO-based) in compiled binaries.
    // SwiftNIO crashes because Swift's type metadata for NIO's internal
    // socket channel types is not available when the Swift runtime is
    // initialized from LLVM-compiled code.
    //
    // Instead, compiled binaries use native BSD socket HTTP server via
    // aro_native_http_server_start_with_openapi()
    self.httpServer = nil
}
```

This is why compiled ARO binaries use a native socket-based HTTP server instead of SwiftNIO.

---

## Chapter Summary

The runtime bridge enables compiled code to call Swift:

1. **@_cdecl** exports Swift functions with C calling conventions
2. **Opaque pointers** wrap Swift objects for C code to hold
3. **Manual offset calculations** convert C structs to Swift types
4. **Semaphore blocking** makes async actions synchronous
5. **Function pointer casting** enables compiled handler callbacks
6. **Value boxing** provides reference-counted return values
7. **Platform-specific code** handles Darwin/Linux differences

The bridge is the most fragile part of native compilation. Memory layout assumptions, pointer casting, and synchronization all create potential failure modes. The interpreter path avoids these issues entirely—use it when stability matters more than startup time.

Implementation references:
- `Sources/ARORuntime/Bridge/RuntimeBridge.swift` — Core lifecycle and context management
- `Sources/ARORuntime/Bridge/ActionBridge.swift` — All 48 action @_cdecl exports
- `Sources/ARORuntime/Bridge/ServiceBridge.swift` — HTTP/File/Socket service bridges

---

*Next: Chapter 10 — Critical Assessment*
