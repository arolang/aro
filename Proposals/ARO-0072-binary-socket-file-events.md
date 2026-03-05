# ARO-0072 — Binary Mode: Socket Event Handlers and File Event Routing

| Field | Value |
|-------|-------|
| Proposal | ARO-0072 |
| Title | Binary Mode: Socket Event Handlers and File Event Routing |
| Status | Draft |
| Category | Runtime / AROCRuntime |
| Affects | `aro build` (compiled binaries) only |
| Related | ARO-0008 (I/O Services), ARO-0009 (Native Compilation) |

---

## 1. Summary

When an ARO application is compiled with `aro build`, two categories of event handlers fail silently:

1. **Socket Event Handlers** (`Socket Event Handler` business activity) — connect, data, and disconnect handlers never fire because (a) `LLVMCodeGenerator` explicitly skips registering them, and (b) the native BSD socket server callbacks (`aro_native_socket_server_start`) only `print(...)` instead of publishing `DomainEvent`s.

2. **File Event Routing** — in the interpreter, file events use typed events (`ClientConnectedEvent` etc.) routed through `ExecutionEngine.registerSocketEventHandlers`. In the compiled binary, `AROFileSystemService` publishes `DomainEvent`s that *are* correctly classified, but this behavior needs end-to-end verification and a test to lock it in.

This proposal documents the root causes, the required code changes, and the updated expected test output.

---

## 2. Observed Behaviour (Binary Mode — `MultiService` Example)

| Feature | Binary Mode | Interpreter Mode |
|---------|-------------|------------------|
| HTTP GET `/status` | ✅ Works | ✅ Works |
| HTTP POST `/broadcast` | ✅ Works | ✅ Works |
| Socket echo (data → echo) | ✅ Works | ✅ Works |
| Socket broadcast via HTTP | ✅ Works | ✅ Works |
| Socket connect welcome message | ❌ Never fires | ✅ Works |
| Socket disconnect log | ❌ Never fires | ✅ Works |
| File created handler | ❓ Needs verification | ✅ Works |
| File modified handler | ❓ Needs verification | ✅ Works |
| File deleted handler | ❓ Needs verification | ✅ Works |

---

## 3. Root Cause Analysis

### 3.1 Socket Event Handlers (Critical — confirmed broken)

**Problem A — `LLVMCodeGenerator` skips registration:**

`Sources/AROCompiler/LLVMC/LLVMCodeGenerator.swift`, `registerEventHandlers()` (line ~1477):

```swift
guard !activity.contains("Socket Event") &&
      !activity.contains("Application-End") else {
    continue   // ← Socket Event handlers are explicitly skipped
}
```

Handlers with business activity `"Socket Event Handler"` (e.g. `Handle Client Connected: Socket Event Handler`) are never registered via `aro_runtime_register_handler`. No handler entry exists in `_compiledHandlers` for `"socket.connected"`, `"socket.data"`, or `"socket.disconnected"`.

**Problem B — `NativeSocketServer` callbacks do not emit `DomainEvent`:**

`Sources/ARORuntime/Bridge/ServiceBridge.swift`, `aro_native_socket_server_start()` (line ~1548):

```swift
nativeSocketServer?.onConnect { connectionId, remoteAddress in
    // Only prints — no DomainEvent published
    print("[Handle Client Connected] SocketConnection(...)")
}
nativeSocketServer?.onData { connectionId, data in
    _ = nativeSocketServer?.broadcast(data: data)   // echo only
    ...
}
nativeSocketServer?.onDisconnect { connectionId in
    print("[Handle Client Disconnected] \(connectionId)")
}
```

Even if handlers were registered (Problem A fixed), no `DomainEvent` would reach `EventBus.shared`, so they would still never fire.

### 3.2 File Event Routing (Needs verification)

File event routing in binary mode uses a different path than the socket events:

- `AROFileSystemService` IS registered as `FileMonitorService` in `AROCContextHandle` ✅
- `Start the <file-monitor>` correctly calls `fileSystemService.watch(path:)` ✅
- `AROFileSystemService.handleFileEvent` publishes both typed events AND `DomainEvent`s ✅
- `LLVMCodeGenerator` registers file handlers for `"file.created"`, `"file.modified"`, `"file.deleted"` ✅
- `_compiledHandlers["file.created"]` etc. are populated and dispatched ✅

The chain is structurally correct. However the `FileMonitor` library's `MacosWatcher` has subtle logic for event classification:

```swift
// MacosWatcher.swift — callback decision tree
if (event.fileModified || event.fileChange) && changeSetCount == 0 {
    delegate?.fileDidChanged(.changed)        // ← checked FIRST
} else if event.fileRemoved && changeSetCount < 0 {
    delegate?.fileDidChanged(.deleted)
} else if event.fileCreated {
    delegate?.fileDidChanged(.added)          // ← only if first branch false
} else {
    delegate?.fileDidChanged(.changed)
}
```

macOS FSEvents sets **both** `Created` and `Modified` flags when a new file is created via `touch`. The classification relies on `changeSetCount` (difference between current directory listing and the cached last listing). If the directory scan is slow or if a race condition causes `changeSetCount == 0` when a file is created, the callback emits `.changed` instead of `.added`. This needs explicit end-to-end test coverage.

---

## 4. Required Changes

### 4.1 `LLVMCodeGenerator.swift` — Register socket event handlers

**File:** `Sources/AROCompiler/LLVMC/LLVMCodeGenerator.swift`

Remove the `Socket Event` skip guard and add socket handler registration by feature set name (same pattern as file handlers):

```swift
// BEFORE (line ~1477):
guard !activity.contains("Socket Event") &&
      !activity.contains("Application-End") else {
    continue
}

// AFTER:
guard !activity.contains("Application-End") else {
    continue
}

// Socket Event Handlers: register for socket.connected / socket.data / socket.disconnected
if activity.contains("Socket Event") {
    let featureName = analyzed.featureSet.name.lowercased()
    let socketEventType: String
    // Check "disconnect" before "connect" since "disconnect" contains "connect"
    if featureName.contains("disconnect") {
        socketEventType = "socket.disconnected"
    } else if featureName.contains("connect") {
        socketEventType = "socket.connected"
    } else if featureName.contains("data") || featureName.contains("message") || featureName.contains("received") {
        socketEventType = "socket.data"
    } else {
        continue
    }
    let funcName = featureSetFunctionName(analyzed.featureSet.name)
    if let handlerFunc = ctx.module.function(named: funcName) {
        let eventTypeStr = ctx.stringConstant(socketEventType)
        _ = ctx.module.insertCall(
            externals.runtimeRegisterHandler,
            on: [runtime, eventTypeStr, handlerFunc],
            at: ip
        )
    }
    continue
}
```

### 4.2 `ServiceBridge.swift` — Emit `DomainEvent` from `NativeSocketServer` callbacks

**File:** `Sources/ARORuntime/Bridge/ServiceBridge.swift`

Replace the print-only callbacks in `aro_native_socket_server_start()` with `EventBus.shared.publish(DomainEvent(...))` calls. The payload dicts must match what `ExtractAction` expects in `socket.aro` (ARO `Extract` uses `object.base` to look up the top-level key, then `object.specifiers[0]` to navigate into the dict):

```swift
nativeSocketServer?.onConnect { connectionId, remoteAddress in
    // "Handle Client Connected": Extract the <client-id> from the <connection: id>.
    EventBus.shared.publish(DomainEvent(
        eventType: "socket.connected",
        payload: [
            "connection": [
                "id": connectionId,
                "remoteAddress": remoteAddress
            ] as [String: any Sendable]
        ]
    ))
}

nativeSocketServer?.onData { connectionId, data in
    // "Handle Data Received": Extract the <message> from the <packet: message>.
    //                         Extract the <client-id> from the <packet: connection>.
    let message = String(data: data, encoding: .utf8) ?? ""
    EventBus.shared.publish(DomainEvent(
        eventType: "socket.data",
        payload: [
            "packet": [
                "message": message,
                "connection": connectionId
            ] as [String: any Sendable]
        ]
    ))
}

nativeSocketServer?.onDisconnect { connectionId in
    // "Handle Client Disconnected": Extract the <client-id> from the <event: connectionId>.
    EventBus.shared.publish(DomainEvent(
        eventType: "socket.disconnected",
        payload: [
            "event": [
                "connectionId": connectionId,
                "reason": "closed"
            ] as [String: any Sendable]
        ]
    ))
}
```

**Note:** The `onData` callback previously broadcast all received data to all clients (echo behaviour). After this change, the echo logic moves into the ARO handler. The raw echo in `onData` should be removed; ARO's `Handle Data Received` handler calls `Send the <echo> to the <client-id>` explicitly. However, `BroadcastAction` (used in `Handle Data Received` to send the echo) needs `SocketServerService` registered — see §4.3.

### 4.3 `RuntimeBridge.swift` — Expose `NativeSocketServer` as `SocketServerService` for `BroadcastAction`

**File:** `Sources/ARORuntime/Bridge/RuntimeBridge.swift`

`BroadcastAction` (in `AROCRuntime/ActionBridge.swift`, `aro_action_broadcast`) currently looks up `SocketServerService` from the execution context to call `broadcast(data:)`. In binary mode, the `NativeSocketServer` is stored in a module-level global (`nativeSocketServer`) but is NOT registered as `SocketServerService` in `AROCContextHandle`.

Two options:

**Option A (simple):** Access the module-level `nativeSocketServer` global directly from `aro_action_broadcast` without going through the service registry. Already works if `aro_action_broadcast` uses the global directly.

**Option B (clean):** Create a thin `NativeSocketServerAdapter: SocketServerService` wrapper around `nativeSocketServer` and register it in `AROCContextHandle`:

```swift
// In AROCContextHandle.init
if let server = nativeSocketServerRef {
    let adapter = NativeSocketServerAdapter(server: server)
    self.context.register(adapter as SocketServerService)
}
```

Check `ActionBridge.swift`'s `aro_action_broadcast` first to determine which option applies.

### 4.4 `MultiService/test.hint` — Enable binary mode

**File:** `Examples/MultiService/test.hint`

```
mode: both
timeout: 10
keep-alive: true
occurrence-check: true
allow-error: true
```

### 4.5 `MultiService/expected.txt` — Update for binary test

The binary mode test must include socket welcome message and file event notifications. Since `occurrence-check: true` is used, each line needs to appear somewhere in the actual output:

```
# Generated: manually
# Type: console
---
System starting...
Socket server started
File monitor started
HTTP server started on port 8080
>>> Socket client connected
Welcome to Multi-Service Demo!
FILE CREATED:
>>> File modified
FILE MODIFIED:
FILE DELETED:
HTTP broadcast triggered
```

*(Exact paths are dynamic; `occurrence-check` matches each line as a substring.)*

---

## 5. Event Payload Contract

The payload dict format used in `DomainEvent` for socket events must match the `Extract` qualifiers used in `socket.aro`:

| Handler | ARO Extract Statement | DomainEvent Payload Key | Sub-Key |
|---------|----------------------|------------------------|---------|
| `Handle Client Connected` | `Extract the <client-id> from the <connection: id>.` | `"connection"` | `"id"` |
| `Handle Data Received` | `Extract the <message> from the <packet: message>.` | `"packet"` | `"message"` |
| `Handle Data Received` | `Extract the <client-id> from the <packet: connection>.` | `"packet"` | `"connection"` |
| `Handle Client Disconnected` | `Extract the <client-id> from the <event: connectionId>.` | `"event"` | `"connectionId"` |

The interpreter uses `SocketConnection`, `SocketPacket`, and `SocketDisconnectInfo` structs and resolves properties via the qualifier system. The binary mode uses plain `[String: any Sendable]` dicts and resolves via dict key lookup — the logical mapping is identical.

---

## 6. `Send` Action in Binary Mode

The `Handle Client Connected` handler calls `Send the <welcome> to the <client-id>.`. In binary mode, `aro_action_send` (in `ActionBridge.swift`) must look up the `NativeSocketServer` to send to a specific connection ID. Verify `aro_action_send` already uses the global `nativeSocketServer` reference, or add support for it.

---

## 7. File Event Routing — Verification Plan

Although the code path for file events in binary mode appears correct, it must be explicitly tested:

1. Build `MultiService` binary
2. Start file monitor watching `"."` from `MultiService/` directory
3. Create a new file: `touch newfile.txt` → expect `DomainEvent("file.created")` → handler logs ">>> File created"
4. Modify the file: `echo x >> newfile.txt` → expect `DomainEvent("file.modified")` → handler logs ">>> File modified"
5. Delete the file: `rm newfile.txt` → expect `DomainEvent("file.deleted")` → handler logs ">>> File deleted"

If step 3 produces ">>> File modified" instead of ">>> File created", the `MacosWatcher` `changeSetCount` race condition is present and requires a fix in the `FileMonitor` library or a workaround in `AROFileSystemService.handleFileEvent` (e.g., maintain a separate file set and classify based on existence delta rather than relying on `FileMonitor` classification).

---

## 8. Implementation Order

| Step | File | Change | Effort |
|------|------|--------|--------|
| 1 | `LLVMCodeGenerator.swift` | Register socket handlers | Small |
| 2 | `ServiceBridge.swift` | Emit `DomainEvent` from `onConnect/onData/onDisconnect` | Small |
| 3 | `ActionBridge.swift` | Verify `aro_action_send` works with native socket server | Investigation |
| 4 | `RuntimeBridge.swift` | Register `NativeSocketServer` as `SocketServerService` if needed | Small |
| 5 | `MultiService/test.hint` | Add `mode: both` | Trivial |
| 6 | `MultiService/expected.txt` | Update expected output | Small |
| 7 | Manual test | Verify file event routing works end-to-end in binary | Investigation |

---

## 9. Out of Scope

- **WebSocket handlers in binary mode** — tracked separately
- **Socket event handlers in `aro build --native`** on Linux — the `aro_native_socket_server_start` changes here apply cross-platform, but Linux testing is separate
- **`onData` echo behaviour** — the current binary mode echoes raw data in `onData`; after this fix the echo goes through the ARO handler, which may change observable behaviour slightly (echo content now prefixed with "Echo: ")
