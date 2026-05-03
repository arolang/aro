# Chapter 7: Event Architecture

## The EventBus Pattern

ARO uses a centralized publish-subscribe pattern for inter-component communication. The EventBus decouples event producers from consumers, enabling reactive programming without tight coupling.

The bus is a Swift actor whose subscription storage is a synchronously-accessed class guarded by an `NSLock`. The actor isolates async coordination state — AsyncStream continuations and the in-flight handler counter — while the lock-backed store lets `subscribe()` register a handler before its caller continues, closing a race where an event published immediately after subscription could miss its just-registered handler. Nonisolated entry points wrap the lock-backed paths so synchronous callers don't pay for an actor hop on every call.

<svg viewBox="0 0 700 350" xmlns="http://www.w3.org/2000/svg">
  <style>
    .box { fill: #f5f5f5; stroke: #333; stroke-width: 1.5; }
    .bus { fill: #e8f4e8; }
    .producer { fill: #f4e8e8; }
    .consumer { fill: #e8e8f4; }
    .arrow { fill: none; stroke: #333; stroke-width: 1.5; marker-end: url(#arrow17); }
    .label { font-family: monospace; font-size: 10px; fill: #333; }
    .title { font-family: monospace; font-size: 12px; fill: #333; font-weight: bold; }
  </style>

  <defs>
    <marker id="arrow17" markerWidth="8" markerHeight="6" refX="7" refY="3" orient="auto">
      <polygon points="0 0, 8 3, 0 6" fill="#333"/>
    </marker>
  </defs>

  <!-- EventBus (center) -->
  <rect x="250" y="120" width="200" height="110" rx="5" class="box bus"/>
  <text x="350" y="145" class="title" text-anchor="middle">EventBus</text>
  <text x="260" y="170" class="label">subscriptions: [Subscription]</text>
  <text x="260" y="185" class="label">continuations: AsyncStreams</text>
  <text x="260" y="200" class="label">inFlightHandlers: Int</text>
  <text x="260" y="215" class="label">isolation: actor</text>

  <!-- Producers (left) -->
  <rect x="30" y="40" width="140" height="50" rx="5" class="box producer"/>
  <text x="100" y="70" class="label" text-anchor="middle">EmitAction</text>

  <rect x="30" y="110" width="140" height="50" rx="5" class="box producer"/>
  <text x="100" y="140" class="label" text-anchor="middle">StoreAction</text>

  <rect x="30" y="180" width="140" height="50" rx="5" class="box producer"/>
  <text x="100" y="210" class="label" text-anchor="middle">HTTPServer</text>

  <rect x="30" y="250" width="140" height="50" rx="5" class="box producer"/>
  <text x="100" y="280" class="label" text-anchor="middle">FileMonitor</text>

  <!-- Consumers (right) -->
  <rect x="530" y="40" width="140" height="50" rx="5" class="box consumer"/>
  <text x="600" y="70" class="label" text-anchor="middle">Domain Handler</text>

  <rect x="530" y="110" width="140" height="50" rx="5" class="box consumer"/>
  <text x="600" y="140" class="label" text-anchor="middle">Repository Observer</text>

  <rect x="530" y="180" width="140" height="50" rx="5" class="box consumer"/>
  <text x="600" y="210" class="label" text-anchor="middle">File Handler</text>

  <rect x="530" y="250" width="140" height="50" rx="5" class="box consumer"/>
  <text x="600" y="280" class="label" text-anchor="middle">State Observer</text>

  <!-- Arrows from producers -->
  <path d="M 170 65 L 250 145" class="arrow"/>
  <path d="M 170 135 L 250 160" class="arrow"/>
  <path d="M 170 205 L 250 180" class="arrow"/>
  <path d="M 170 275 L 250 200" class="arrow"/>

  <!-- Arrows to consumers -->
  <path d="M 450 145 L 530 65" class="arrow"/>
  <path d="M 450 160 L 530 135" class="arrow"/>
  <path d="M 450 180 L 530 205" class="arrow"/>
  <path d="M 450 200 L 530 275" class="arrow"/>

  <text x="200" y="90" class="label">publish</text>
  <text x="480" y="90" class="label">dispatch</text>
</svg>

**Figure 7.1**: EventBus architecture. Producers publish events; the bus dispatches to matching subscribers.

---

## RuntimeEvent Protocol

All events share two things: a static `eventType` string (the routing key) and a timestamp. Subscribers match on `eventType` — or use `"*"` to receive everything.

ARO defines several event categories:

| Category | Event Types | Source |
|----------|-------------|--------|
| Application | `application.started`, `application.stopping` | Lifecycle |
| HTTP | `http.request`, `http.response` | HTTPServer |
| File | `file.created`, `file.modified`, `file.deleted` | FileMonitor |
| Socket | `socket.connected`, `socket.data`, `socket.disconnected` | SocketServer |
| Repository | `repository.changed` | Store/Update/Delete actions |
| State | `state.transition` | Accept action |
| Domain | `domain` (with subtypes) | Emit action |
| Error | `error` | Any component |

---

## Handler Registration Timing

A critical design decision: **handlers are registered before the entry point executes**.

```text
execute(program):
  1. Register all event handlers (domain, repository, file, socket, state)
  2. Execute Application-Start
  3. Await pending handlers
```

Step 1 before Step 2 is critical. If Application-Start emits an event, the handler must already be subscribed. Get the order wrong and you have a race condition baked in from the start.

<svg viewBox="0 0 600 280" xmlns="http://www.w3.org/2000/svg">
  <style>
    .box { fill: #f5f5f5; stroke: #333; stroke-width: 1.5; }
    .phase1 { fill: #e8f4e8; }
    .phase2 { fill: #f4e8e8; }
    .phase3 { fill: #e8e8f4; }
    .arrow { fill: none; stroke: #333; stroke-width: 1.5; marker-end: url(#arrow18); }
    .label { font-family: monospace; font-size: 10px; fill: #333; }
    .title { font-family: monospace; font-size: 11px; fill: #333; font-weight: bold; }
  </style>

  <defs>
    <marker id="arrow18" markerWidth="8" markerHeight="6" refX="7" refY="3" orient="auto">
      <polygon points="0 0, 8 3, 0 6" fill="#333"/>
    </marker>
  </defs>

  <!-- Phase 1: Load -->
  <rect x="30" y="30" width="160" height="80" rx="5" class="box phase1"/>
  <text x="110" y="55" class="title" text-anchor="middle">Phase 1: Load</text>
  <text x="40" y="75" class="label">• Parse all .aro files</text>
  <text x="40" y="90" class="label">• Build AnalyzedProgram</text>
  <text x="40" y="105" class="label">• Find entry point</text>

  <!-- Phase 2: Wire -->
  <rect x="220" y="30" width="160" height="80" rx="5" class="box phase2"/>
  <text x="300" y="55" class="title" text-anchor="middle">Phase 2: Wire</text>
  <text x="230" y="75" class="label">• Register handlers</text>
  <text x="230" y="90" class="label">• Subscribe to events</text>
  <text x="230" y="105" class="label">• Setup services</text>

  <!-- Phase 3: Execute -->
  <rect x="410" y="30" width="160" height="80" rx="5" class="box phase3"/>
  <text x="490" y="55" class="title" text-anchor="middle">Phase 3: Execute</text>
  <text x="420" y="75" class="label">• Run Application-Start</text>
  <text x="420" y="90" class="label">• Process events</text>
  <text x="420" y="105" class="label">• Await completion</text>

  <!-- Arrows -->
  <path d="M 190 70 L 220 70" class="arrow"/>
  <path d="M 380 70 L 410 70" class="arrow"/>

  <!-- Handler types -->
  <rect x="30" y="150" width="540" height="110" rx="5" class="box"/>
  <text x="300" y="175" class="title" text-anchor="middle">Handler Types Registered in Phase 2</text>

  <text x="50" y="200" class="label">Domain:     "UserCreated Handler" → DomainEvent(type: "UserCreated")</text>
  <text x="50" y="215" class="label">Repository: "user-repository Observer" → RepositoryChangedEvent</text>
  <text x="50" y="230" class="label">File:       "Handle Modified: File Event Handler" → FileModifiedEvent</text>
  <text x="50" y="245" class="label">Socket:     "Data Received: Socket Event Handler" → DataReceivedEvent</text>
</svg>

**Figure 7.2**: Execution phases. Handlers must be wired before the entry point runs.

---

## Seven Handler Types

ARO supports seven categories of event handlers, distinguished by business activity patterns.

### 1. Domain Event Handlers

Pattern: `{EventName} Handler`

```aro
(Send Welcome Email: UserCreated Handler) {
    Extract the <user> from the <event: user>.
    Send the <welcome-email> to the <user: email>.
    Return an <OK: status> for the <notification>.
}
```

For each feature set whose business activity contains `Handler` (but not `Socket Event Handler` or `File Event Handler`), extract the event type name and subscribe. Simple string parsing — no special annotations needed.

### 2. Repository Observers

Pattern: `{repository-name} Observer`

```aro
(Log User Changes: user-repository Observer) {
    Extract the <changeType> from the <event: changeType>.
    Log "User ${<changeType>}" to the <console>.
    Return an <OK: status> for the <logging>.
}
```

Repository observers fire on every Store, Update, or Delete. Inside the action, after the CRUD operation, the bus gets a `RepositoryChangedEvent` with the entity ID, change type, and before/after values.

### 3. File Event Handlers

Pattern: `{description}: File Event Handler`

```aro
(Handle Modified: File Event Handler) {
    Extract the <path> from the <event: path>.
    Log "File changed: ${<path>}" to the <console>.
    Return an <OK: status> for the <notification>.
}
```

The feature set name determines which file event type is handled:
- Contains "created" → `FileCreatedEvent`
- Contains "modified" → `FileModifiedEvent`
- Contains "deleted" → `FileDeletedEvent`

### 4. Socket Event Handlers

Pattern: `{description}: Socket Event Handler`

```aro
(Data Received: Socket Event Handler) {
    Extract the <data> from the <packet: data>.
    Send the <data> to the <packet: connectionId>.
    Return an <OK: status> for the <echo>.
}
```

### 5. State Observers

Pattern: `{fieldName} StateObserver` or `{fieldName} StateObserver<from_to_to>`

```aro
(* Observe all transitions on 'status' field *)
(Audit Changes: status StateObserver) {
    Extract the <fromState> from the <transition: fromState>.
    Extract the <toState> from the <transition: toState>.
    Log "Status: ${<fromState>} → ${<toState>}" to the <console>.
    Return an <OK: status> for the <audit>.
}

(* Observe specific transition: draft → placed *)
(Notify Placed: status StateObserver<draft_to_placed>) {
    Extract the <order> from the <transition: entity>.
    Send the <order-confirmation> to the <order: customerEmail>.
    Return an <OK: status> for the <notification>.
}
```

### 6. KeyPress Handlers

Pattern: `{description}: KeyPress Handler` with `where <key> = "keyname"` guards

```aro
(Move Down: KeyPress Handler) where <key> = "down" {
    (* Handle down arrow key press *)
    Return an <OK: status> for the <keypress>.
}
```

KeyPress handlers use `where` clause filtering at the feature set level to match specific keys. Multiple handlers can listen for different keys. Requires `Listen the <keyboard> to the <stdin>.` in Application-Start.

### 7. WebSocket Event Handlers

Pattern: `{description}: WebSocket Event Handler`

```aro
(Handle WebSocket Connect: WebSocket Event Handler) {
    Log "Client connected" to the <console>.
    Return an <OK: status> for the <connection>.
}
```

WebSocket handlers respond to WebSocket lifecycle events (connect, message, disconnect). Requires `Start the <http-server> with { websocket: "/ws" }.` in Application-Start.

---

## State Guards

Handlers can filter events based on entity field values using angle bracket syntax:

```aro
(* Only handle when status = "paid" *)
(Process Paid Orders: OrderCreated Handler<status:paid>) {
    ...
}

(* Multiple values with OR logic *)
(Handle Active Users: UserUpdated Handler<status:active,premium>) {
    ...
}

(* Multiple fields with AND logic *)
(VIP Processing: OrderCreated Handler<status:paid;tier:gold>) {
    ...
}
```

The `StateGuard` and `StateGuardSet` types parse and evaluate these conditions:

| Field | Meaning |
|-------|---------|
| `fieldPath` | Which payload field to check (e.g., `status`, `entity.tier`) |
| `validValues` | Set of acceptable values (OR logic within one guard) |

Multiple guards in a `StateGuardSet` use AND logic between them.

<svg viewBox="0 0 600 250" xmlns="http://www.w3.org/2000/svg">
  <style>
    .box { fill: #f5f5f5; stroke: #333; stroke-width: 1.5; }
    .match { fill: #d4edda; }
    .nomatch { fill: #f8d7da; }
    .arrow { fill: none; stroke: #333; stroke-width: 1.5; marker-end: url(#arrow19); }
    .label { font-family: monospace; font-size: 10px; fill: #333; }
    .title { font-family: monospace; font-size: 11px; fill: #333; font-weight: bold; }
  </style>

  <defs>
    <marker id="arrow19" markerWidth="8" markerHeight="6" refX="7" refY="3" orient="auto">
      <polygon points="0 0, 8 3, 0 6" fill="#333"/>
    </marker>
  </defs>

  <!-- Event -->
  <rect x="30" y="30" width="180" height="80" rx="5" class="box"/>
  <text x="120" y="55" class="title" text-anchor="middle">DomainEvent</text>
  <text x="40" y="75" class="label">type: "OrderCreated"</text>
  <text x="40" y="90" class="label">payload: {status: "paid",</text>
  <text x="40" y="105" class="label">         tier: "gold"}</text>

  <!-- Guard parsing -->
  <rect x="250" y="30" width="160" height="80" rx="5" class="box"/>
  <text x="330" y="55" class="title" text-anchor="middle">StateGuardSet.parse()</text>
  <text x="260" y="75" class="label">"&lt;status:paid;tier:gold&gt;"</text>
  <text x="260" y="95" class="label">→ guard1: status IN {paid}</text>
  <text x="260" y="105" class="label">→ guard2: tier IN {gold}</text>

  <!-- Match results -->
  <rect x="450" y="30" width="120" height="35" rx="5" class="box match"/>
  <text x="510" y="55" class="label" text-anchor="middle">✓ Handler executes</text>

  <rect x="450" y="75" width="120" height="35" rx="5" class="box nomatch"/>
  <text x="510" y="100" class="label" text-anchor="middle">✗ Filtered out</text>

  <!-- Arrows -->
  <path d="M 210 70 L 250 70" class="arrow"/>
  <path d="M 410 50 L 450 50" class="arrow"/>
  <text x="425" y="43" class="label">match</text>
  <path d="M 410 90 L 450 90" class="arrow"/>
  <text x="420" y="83" class="label">no match</text>

  <!-- Guard logic explanation -->
  <rect x="30" y="150" width="540" height="80" rx="5" class="box"/>
  <text x="300" y="175" class="title" text-anchor="middle">Guard Logic Rules</text>
  <text x="50" y="195" class="label">Within a guard:  OR logic  (status:paid,shipped → paid OR shipped)</text>
  <text x="50" y="210" class="label">Between guards: AND logic  (&lt;status:paid;tier:gold&gt; → paid AND gold)</text>
  <text x="50" y="225" class="label">Nested paths:   Dot notation (entity.status:active)</text>
</svg>

**Figure 7.3**: State guard filtering. Guards provide declarative event filtering without code.

---

## In-Flight Tracking

Events can trigger handlers that emit more events. The EventBus tracks in-flight handlers to ensure all cascaded processing completes before the application shuts down.

```text
publishAndTrack(event):
  find matching subscriptions
  for each subscription:
    increment inFlightHandlers
    run handler in task group
    on completion:
      decrement inFlightHandlers
      if 0: signal waiters
```

After `Application-Start` completes, the engine waits for all handlers to finish before returning. If they don't finish within the timeout, a warning is logged.

---

## Race Condition Prevention

The check and the continuation append happen inside the same actor-isolated method. This prevents the classic race where a handler finishes between the zero-check and the append, leaving the continuation waiting forever.

In plain terms: you can't safely check "are we done?" and then decide to wait separately. Both steps must be atomic. Actor isolation makes that happen.

---

## Concurrency Design

EventBus is a Swift actor with a lock-backed `SubscriptionStore`. `subscribe()` registers handlers synchronously through the store, so an event published in the very next instruction is guaranteed to see the new handler — there is no scheduled `Task` to outrun. Async coordination still goes through the actor: `publishAndWait()`, `publishAndTrack()`, and `awaitPendingEvents()` are actor-isolated and use `withTaskGroup` to run handlers concurrently while the bus tracks the in-flight count.

Handlers run via `Task` on the cooperative executor. Compiled binaries use the same path; a `CompiledExecutionPool` gates concurrent feature-set entry points to keep server bursts bounded.

Action work itself runs on `ActionTaskExecutor` — a custom `TaskExecutor` over GCD's elastic global queue, separate from the cooperative pool. Handlers that emit and force values therefore can never starve the cooperative pool: GCD will spawn additional threads to make progress. This is what made cascading event chains deadlock-free under issue #55.

---

## AsyncStream Integration

You can subscribe via callback (register a closure) or via AsyncStream (`for await event in bus.stream(for:)`). The stream version is cleaner for long-running handlers. Under the hood, both go through the same subscription mechanism — the stream just wraps the callback in a continuation.

---

## Handler Execution Pattern

Each handler gets its own fresh context inheriting services from the parent but isolated for variable bindings. The event payload is bound as `event`. If the handler throws, an error event is published — but the application keeps running. Handlers are fault-isolated.

```aro
(Send Welcome Email: UserCreated Handler) {
    Extract the <user> from the <event: user>.   (* event bound from payload *)
    Send the <welcome-email> to the <user: email>.
    Return an <OK: status> for the <notification>.
    (* if this throws, an error event is emitted — app continues *)
}
```

---

## Chapter Summary

The event architecture enables loosely coupled, reactive programming:

1. **EventBus** provides centralized publish-subscribe with type-based routing
2. **Handler Registration** happens before entry point execution
3. **Seven Handler Types** cover domain events, repositories, files, sockets, state transitions, key presses, and WebSocket events
4. **State Guards** enable declarative filtering without code
5. **In-Flight Tracking** ensures cascaded events complete before shutdown
6. **Race Prevention** uses actor isolation for correctness
7. **AsyncStream** integration supports modern Swift concurrency patterns

The event system is the glue between services. When an HTTP request arrives, the server publishes an event. When a file changes, the monitor publishes an event. Feature sets subscribe to these events and react — without knowing or caring about the source.

Implementation references:
- `Sources/ARORuntime/Events/EventBus.swift` (287 lines)
- `Sources/ARORuntime/Events/EventTypes.swift` (321 lines)
- `Sources/ARORuntime/Events/StateGuard.swift` (129 lines)
- `Sources/ARORuntime/Core/ExecutionEngine.swift` (851 lines)

---

*Next: Chapter 8 — Native Compilation*
