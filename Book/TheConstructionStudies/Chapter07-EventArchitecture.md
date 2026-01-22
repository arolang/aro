# Chapter 7: Event Architecture

## The EventBus Pattern

ARO uses a centralized publish-subscribe pattern for inter-component communication. The EventBus decouples event producers from consumers, enabling reactive programming without tight coupling.

```swift
// EventBus.swift
public final class EventBus: @unchecked Sendable {
    public typealias EventHandler = @Sendable (any RuntimeEvent) async -> Void

    private struct Subscription: Sendable {
        let id: UUID
        let eventType: String
        let handler: EventHandler
    }

    private var subscriptions: [Subscription] = []
    private var continuations: [UUID: AsyncStream<any RuntimeEvent>.Continuation] = [:]
}
```

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
  <text x="260" y="215" class="label">lock: NSLock</text>

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

All events conform to a simple protocol:

```swift
public protocol RuntimeEvent: Sendable {
    static var eventType: String { get }
    var timestamp: Date { get }
}
```

The `eventType` is the routing key. Subscribers register for specific types or use `"*"` to receive all events.

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

```swift
public func execute(_ program: AnalyzedProgram, entryPoint: String) async throws -> Response {
    // 1. Find entry point feature set
    guard let entryFeatureSet = program.featureSets.first(where: {
        $0.featureSet.name == entryPoint
    }) else {
        throw ActionError.entryPointNotFound(entryPoint)
    }

    // 2. Register ALL handlers BEFORE execution
    registerSocketEventHandlers(for: program, baseContext: context)
    registerDomainEventHandlers(for: program, baseContext: context)
    registerFileEventHandlers(for: program, baseContext: context)
    registerRepositoryObservers(for: program, baseContext: context)
    registerStateObservers(for: program, baseContext: context)

    // 3. Now execute entry point
    let response = try await executor.execute(entryFeatureSet, context: context)

    return response
}
```

This ordering ensures that events emitted during `Application-Start` have handlers ready to receive them.

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

## Five Handler Types

ARO supports five categories of event handlers, distinguished by business activity patterns:

### 1. Domain Event Handlers

Pattern: `{EventName} Handler`

```aro
(Send Welcome Email: UserCreated Handler) {
    <Extract> the <user> from the <event: user>.
    <Send> the <welcome-email> to the <user: email>.
    <Return> an <OK: status> for the <notification>.
}
```

Registration logic:

```swift
private func registerDomainEventHandlers(for program: AnalyzedProgram, ...) {
    let domainHandlers = program.featureSets.filter { analyzedFS in
        let activity = analyzedFS.featureSet.businessActivity
        let hasHandler = activity.contains(" Handler")
        let isSpecialHandler = activity.contains("Socket Event Handler") ||
                               activity.contains("File Event Handler")
        return hasHandler && !isSpecialHandler
    }

    for analyzedFS in domainHandlers {
        // Extract "UserCreated" from "UserCreated Handler"
        let eventType = extractEventType(from: activity)

        eventBus.subscribe(to: DomainEvent.self) { event in
            guard event.domainEventType == eventType else { return }
            await self.executeDomainEventHandler(analyzedFS, event: event)
        }
    }
}
```

### 2. Repository Observers

Pattern: `{repository-name} Observer`

```aro
(Log User Changes: user-repository Observer) {
    <Extract> the <changeType> from the <event: changeType>.
    <Log> "User ${<changeType>}" to the <console>.
    <Return> an <OK: status> for the <logging>.
}
```

Repository observers are triggered by Store, Update, and Delete actions:

```swift
// Inside StoreAction.execute()
eventBus.publishAndTrack(RepositoryChangedEvent(
    repositoryName: repositoryName,
    changeType: .created,
    entityId: entityId,
    newValue: entity
))
```

### 3. File Event Handlers

Pattern: `{description}: File Event Handler`

```aro
(Handle Modified: File Event Handler) {
    <Extract> the <path> from the <event: path>.
    <Log> "File changed: ${<path>}" to the <console>.
    <Return> an <OK: status> for the <notification>.
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
    <Extract> the <data> from the <packet: data>.
    <Send> the <data> to the <packet: connectionId>.
    <Return> an <OK: status> for the <echo>.
}
```

### 5. State Observers

Pattern: `{fieldName} StateObserver` or `{fieldName} StateObserver<from_to_to>`

```aro
(* Observe all transitions on 'status' field *)
(Audit Changes: status StateObserver) {
    <Extract> the <fromState> from the <transition: fromState>.
    <Extract> the <toState> from the <transition: toState>.
    <Log> "Status: ${<fromState>} → ${<toState>}" to the <console>.
    <Return> an <OK: status> for the <audit>.
}

(* Observe specific transition: draft → placed *)
(Notify Placed: status StateObserver<draft_to_placed>) {
    <Extract> the <order> from the <transition: entity>.
    <Send> the <order-confirmation> to the <order: customerEmail>.
    <Return> an <OK: status> for the <notification>.
}
```

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

```swift
public struct StateGuard: Sendable {
    public let fieldPath: String      // e.g., "status" or "entity.status"
    public let validValues: Set<String>  // OR logic within guard

    public func matches(payload: [String: any Sendable]) -> Bool {
        guard let fieldValue = resolveFieldPath(fieldPath, in: payload) else {
            return false
        }
        return validValues.contains(fieldValue.lowercased())
    }
}

public struct StateGuardSet: Sendable {
    public let guards: [StateGuard]  // AND logic between guards

    public func allMatch(payload: [String: any Sendable]) -> Bool {
        guards.allSatisfy { $0.matches(payload: payload) }
    }
}
```

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

Events can trigger handlers that emit more events. The EventBus tracks in-flight handlers to ensure all cascaded processing completes:

```swift
public func publishAndTrack(_ event: any RuntimeEvent) async {
    let matchingSubscriptions = getMatchingSubscriptions(for: eventType)

    await withTaskGroup(of: Void.self) { group in
        for subscription in matchingSubscriptions {
            // Increment before spawning
            withLock { inFlightHandlers += 1 }

            group.addTask {
                await subscription.handler(event)

                // Decrement after completion, notify waiters if zero
                let continuationsToResume = self.withLock { () -> [...] in
                    self.inFlightHandlers -= 1
                    if self.inFlightHandlers == 0 {
                        let continuations = self.flushContinuations
                        self.flushContinuations.removeAll()
                        return continuations
                    }
                    return []
                }

                for continuation in continuationsToResume {
                    continuation.resume()
                }
            }
        }
    }
}
```

After `Application-Start` completes, the engine waits for all handlers:

```swift
// After entry point execution
let completed = await eventBus.awaitPendingEvents(timeout: 10.0)
if !completed {
    print("[WARNING] Event handlers did not complete within timeout")
}
```

---

## Concurrency Design

### Why EventBus Is Not an Actor

Unlike `ExecutionEngine` and `ActionRegistry` (which are actors), EventBus is a `final class` with manual `NSLock`:

```swift
public final class EventBus: @unchecked Sendable {
    private let lock = NSLock()
    // ...
}
```

Reasons for this design:

1. **Fire-and-forget publishing**: Event publication should not block the caller. Actors require `await` for every method call, adding unwanted latency.

2. **Lock overhead**: For high-frequency event dispatch, NSLock has lower overhead than actor hop overhead.

3. **Callback compatibility**: The `@unchecked Sendable` conformance allows storing closures that capture external state.

### Handler Threading

Event handlers run on **GCD dispatch queues**, not Swift's cooperative executor:

```swift
DispatchQueue.global().async {
    // Handler executes here, isolated from main thread
    await subscription.handler(event)
}
```

This design prevents a critical issue on Linux: if handlers ran on the Swift cooperative executor and blocked (e.g., waiting for I/O), the executor pool could be exhausted, causing deadlocks.

---

## Race Condition Prevention

The EventBus uses careful lock ordering to prevent race conditions:

```swift
public func awaitPendingEvents(timeout: TimeInterval) async -> Bool {
    return await withTaskGroup(of: Bool.self) { group in
        // Task 1: Wait for handlers
        group.addTask {
            await withCheckedContinuation { continuation in
                self.withLock {
                    // CRITICAL: Both check AND append inside same lock
                    if self.inFlightHandlers == 0 {
                        continuation.resume()  // Already done
                    } else {
                        self.flushContinuations.append(continuation)  // Wait
                    }
                }
            }
            return true
        }

        // Task 2: Timeout
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            return false
        }

        // First to complete wins
        if let result = await group.next() {
            group.cancelAll()
            return result
        }
        return false
    }
}
```

The key insight: checking `inFlightHandlers == 0` and appending to `flushContinuations` must happen atomically. Otherwise, a handler could complete between the check and append, leaving the continuation waiting forever.

---

## AsyncStream Integration

The EventBus supports both callback-based and stream-based subscriptions:

```swift
// Callback-based
eventBus.subscribe(to: "http.request") { event in
    await handleRequest(event)
}

// Stream-based
let stream = eventBus.stream(for: HTTPRequestReceivedEvent.self)
for await event in stream {
    await handleRequest(event)
}
```

Stream subscriptions use AsyncStream continuations:

```swift
public func stream<E: RuntimeEvent>(for type: E.Type) -> AsyncStream<E> {
    AsyncStream { continuation in
        let id = subscribe(to: type) { event in
            continuation.yield(event)
        }

        continuation.onTermination = { [weak self] _ in
            self?.unsubscribe(id)
        }
    }
}
```

---

## Handler Execution Pattern

When an event matches a handler, a child context is created:

```swift
private func executeDomainEventHandler(
    _ analyzedFS: AnalyzedFeatureSet,
    event: DomainEvent
) async {
    // Create isolated context for this handler
    let handlerContext = RuntimeContext(
        featureSetName: analyzedFS.featureSet.name,
        businessActivity: analyzedFS.featureSet.businessActivity,
        eventBus: eventBus,
        parent: baseContext  // Inherit services
    )

    // Bind event payload for extraction
    handlerContext.bind("event", value: event.payload)

    // Execute the handler's statements
    let executor = FeatureSetExecutor(...)
    do {
        _ = try await executor.execute(analyzedFS, context: handlerContext)
    } catch {
        // Publish error event (handlers are fault-isolated)
        eventBus.publish(ErrorOccurredEvent(
            error: String(describing: error),
            context: analyzedFS.featureSet.name,
            recoverable: true
        ))
    }
}
```

Note: Handler errors are **isolated**. A failing handler doesn't crash the application; it publishes an error event and continues.

---

## Chapter Summary

The event architecture enables loosely coupled, reactive programming:

1. **EventBus** provides centralized publish-subscribe with type-based routing
2. **Handler Registration** happens before entry point execution
3. **Five Handler Types** cover domain events, repositories, files, sockets, and state transitions
4. **State Guards** enable declarative filtering without code
5. **In-Flight Tracking** ensures cascaded events complete before shutdown
6. **Race Prevention** uses careful lock ordering for correctness
7. **AsyncStream** integration supports modern Swift concurrency patterns

The event system is the glue between services. When an HTTP request arrives, the server publishes an event. When a file changes, the monitor publishes an event. Feature sets subscribe to these events and react—without knowing or caring about the source.

Implementation references:
- `Sources/ARORuntime/Events/EventBus.swift` (287 lines)
- `Sources/ARORuntime/Events/EventTypes.swift` (321 lines)
- `Sources/ARORuntime/Events/StateGuard.swift` (129 lines)
- `Sources/ARORuntime/Core/ExecutionEngine.swift` (851 lines)

---

*Next: Chapter 8 — Native Compilation*
