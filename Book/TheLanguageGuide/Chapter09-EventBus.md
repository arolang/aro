# Chapter 9: The Event Bus

*"In an event-driven system, everything is a reaction."*

---

## 9.1 Events, Not Calls

ARO is fundamentally event-driven. Feature sets do not call each other directly—they react to events. This is a crucial architectural distinction that shapes how you design and reason about ARO applications.

In traditional programming, you invoke functions by name. The caller knows about the callee and depends on it directly. If the callee changes its signature or behavior, the caller must be updated. This coupling creates a web of dependencies that grows denser as applications expand.

ARO takes a different approach. When a feature set needs something to happen afterward, it emits an event describing what occurred. Other feature sets can register as handlers for that event type. The emitting feature set does not know which handlers exist or what they will do. It simply publishes information about what happened and moves on.

This decoupling has profound implications. You can add new behaviors by adding handlers without modifying existing code. You can remove behaviors by removing handlers without affecting the emitting code. Multiple independent subsystems can react to the same event without coordination. The architecture remains loose and extensible.

The event bus is the runtime component that makes this work. It receives events from Emit actions, matches them to handlers based on naming patterns, and dispatches them for execution. The bus is invisible to your code—you simply emit events and register handlers, and the runtime handles the routing.

---

## 9.2 How the Event Bus Works

<div style="float: left; margin: 0 1.5em 1em 0;">
<svg width="200" height="220" viewBox="0 0 200 220" xmlns="http://www.w3.org/2000/svg">  <!-- Emitter -->  <rect x="60" y="10" width="80" height="35" rx="4" fill="#dbeafe" stroke="#3b82f6" stroke-width="2"/>  <text x="100" y="25" text-anchor="middle" font-family="sans-serif" font-size="9" font-weight="bold" fill="#1e40af">Feature Set</text>  <text x="100" y="38" text-anchor="middle" font-family="monospace" font-size="8" fill="#3b82f6">&lt;Emit&gt;</text>  <!-- Arrow down to bus -->  <line x1="100" y1="45" x2="100" y2="70" stroke="#6b7280" stroke-width="2"/>  <polygon points="100,70 95,62 105,62" fill="#6b7280"/>  <!-- Event Bus -->  <rect x="30" y="75" width="140" height="30" rx="4" fill="#fef3c7" stroke="#f59e0b" stroke-width="2"/>  <text x="100" y="95" text-anchor="middle" font-family="sans-serif" font-size="10" font-weight="bold" fill="#92400e">EVENT BUS</text>  <!-- Fan-out arrows -->  <line x1="55" y1="105" x2="35" y2="140" stroke="#22c55e" stroke-width="2"/>  <polygon points="35,140 43,135 39,143" fill="#22c55e"/>  <line x1="100" y1="105" x2="100" y2="140" stroke="#22c55e" stroke-width="2"/>  <polygon points="100,140 95,132 105,132" fill="#22c55e"/>  <line x1="145" y1="105" x2="165" y2="140" stroke="#22c55e" stroke-width="2"/>  <polygon points="165,140 157,135 161,143" fill="#22c55e"/>  <!-- Handler 1 -->  <rect x="5" y="145" width="60" height="35" rx="4" fill="#dcfce7" stroke="#22c55e" stroke-width="2"/>  <text x="35" y="160" text-anchor="middle" font-family="sans-serif" font-size="8" font-weight="bold" fill="#166534">Handler A</text>  <text x="35" y="172" text-anchor="middle" font-family="sans-serif" font-size="7" fill="#22c55e">email</text>  <!-- Handler 2 -->  <rect x="70" y="145" width="60" height="35" rx="4" fill="#dcfce7" stroke="#22c55e" stroke-width="2"/>  <text x="100" y="160" text-anchor="middle" font-family="sans-serif" font-size="8" font-weight="bold" fill="#166534">Handler B</text>  <text x="100" y="172" text-anchor="middle" font-family="sans-serif" font-size="7" fill="#22c55e">analytics</text>  <!-- Handler 3 -->  <rect x="135" y="145" width="60" height="35" rx="4" fill="#dcfce7" stroke="#22c55e" stroke-width="2"/>  <text x="165" y="160" text-anchor="middle" font-family="sans-serif" font-size="8" font-weight="bold" fill="#166534">Handler C</text>  <text x="165" y="172" text-anchor="middle" font-family="sans-serif" font-size="7" fill="#22c55e">audit</text>  <!-- Isolated label -->  <text x="100" y="200" text-anchor="middle" font-family="sans-serif" font-size="8" fill="#6b7280">handlers run in isolation</text>  <text x="100" y="212" text-anchor="middle" font-family="sans-serif" font-size="8" fill="#6b7280">order not guaranteed</text></svg>
</div>

The event bus maintains a registry of handlers organized by event type. When the application starts, the runtime scans all feature sets, identifies those whose business activity matches the handler pattern, and registers them with the bus. This registration happens automatically based on naming conventions.

When a feature set executes an Emit action, the runtime creates an event object containing the event name and payload data. This object is delivered to the event bus, which looks up all handlers registered for that event type. Each matching handler receives the event and executes independently.

The bus provides delivery guarantees within a single application instance. When you emit an event, all registered handlers will eventually execute. However, the order of execution is not guaranteed—handlers may run in any sequence. If you need guaranteed ordering, you must express it through event chaining where each handler emits an event that triggers the next step.

Handler execution is isolated. Each handler runs in its own context with its own symbol table. A failure in one handler does not affect other handlers for the same event. The emitting feature set is also isolated—it completes regardless of whether handlers succeed or fail. This fire-and-forget semantics makes event emission a non-blocking operation that does not wait for handlers to complete.

---

## 9.3 Event Matching

Handlers are matched to events based on their business activity. The standard pattern is that the business activity ends with "Handler" preceded by the event name. When a feature set declares its business activity as "UserCreated Handler," it becomes a handler for events named "UserCreated."

This naming-based matching is simple and transparent. By reading the feature set declaration, you know exactly which events it handles. By searching the codebase for "UserCreated Handler," you find all handlers for that event type. No configuration files or external registrations are needed—the code itself declares its event relationships.

The runtime supports several built-in event types generated by services rather than user code. File system services emit File Event when files change. Socket services emit Socket Event when messages arrive. Timer services emit Timer Event on schedule. HTTP services generate events that trigger feature sets matching OpenAPI operation identifiers. These built-in events follow the same matching rules as custom events.

You can have multiple handlers for the same event. When UserCreated is emitted, every feature set with "UserCreated Handler" in its business activity will execute. This allows you to add behaviors incrementally. One handler might send a welcome email. Another might update analytics. A third might create an audit record. Each handler does one thing well, and together they compose the complete response to the event.

---

## 9.4 Emitting Events

The Emit action publishes an event to the bus. The action takes an event type and a payload. The event type appears in the result position with an "event" qualifier. The payload follows the "with" preposition and can be any value—a simple variable, an object literal, or a complex expression.

The event type becomes the name used for handler matching. If you emit an event with type "OrderPlaced," handlers with business activity "OrderPlaced Handler" will receive it. Choose event names that describe what happened in business terms rather than technical terms. "CustomerRegistered" is better than "RecordInserted." "PaymentDeclined" is better than "ErrorOccurred."

The payload is the data that handlers will receive. Handlers access this data using the Extract action with the "event" identifier. Include everything that handlers might need to do their work, but avoid including sensitive information that not all handlers should access. The payload is delivered unchanged to every handler, so all handlers see the same data.

A single feature set can emit multiple events. This is common when different subsystems need to react to different aspects of an operation. Creating an order might emit OrderCreated for order processing, PaymentRequired for the payment system, and InventoryUpdate for warehouse management. Each subsystem handles the event relevant to its domain.

---

## 9.5 Accessing Event Data

Within a handler, the event is available through the special "event" identifier. You use the Extract action to pull specific data out of the event payload into local bindings.

The event object contains the payload that was provided when the event was emitted. If the emitter provided a user object as the payload, you can extract that user with appropriate qualifiers. If the emitter provided an object literal with multiple fields, you can extract each field individually.

Beyond the payload, events carry metadata about their origin. The event identifier provides a unique value for correlating logs and traces. The timestamp records when the event was emitted. The source identifies which feature set emitted the event. This metadata is useful for debugging and auditing.

The extraction patterns for events follow the same qualifier syntax used elsewhere in ARO. You chain qualifiers with colons to navigate into nested structures. If the payload contains an order with a customer with an email, you can extract that email directly using multiple qualifiers.

---

## 9.6 Multiple Handlers and Execution

When multiple handlers register for the same event type, all of them execute when that event is emitted. This parallel reaction is one of the most powerful aspects of event-driven architecture because it allows independent modules to respond to the same stimulus without coordinating with each other.

Each handler runs independently. They do not share state. A failure in one handler does not prevent other handlers from running. If one handler encounters an error, that error is logged, but the other handlers continue normally. This isolation makes handlers resilient—a bug in one handler does not bring down the entire system.

The order of handler execution is not specified. The runtime may execute handlers in any order, and that order may vary between executions. If your handlers must execute in a specific sequence, you need to express that through event chaining rather than relying on implicit ordering.

Handlers may execute concurrently if the runtime determines that they are independent. This parallelism can improve performance, but it also means handlers must not assume exclusive access to shared resources. Design handlers to be safe for concurrent execution, avoiding race conditions in shared state.

---

## 9.7 Event Chains

Events can trigger handlers that emit additional events, creating chains of processing. This pattern allows you to break complex workflows into discrete steps that execute in sequence.

The chain is established through the event naming. When the first event triggers a handler that emits a second event, handlers for that second event run next. Each step in the chain is a separate feature set with its own isolation and error handling.

Event chains are useful for orchestrating multi-step processes. An order processing workflow might start with OrderCreated, which triggers inventory checking. If inventory is available, InventoryReserved triggers payment processing. If payment succeeds, PaymentProcessed triggers fulfillment. Each step emits the event that triggers the next step.

The advantage of chains over monolithic handlers is modularity. Each step can be developed, tested, and modified independently. You can add steps by adding handlers. You can modify a step's implementation without affecting other steps. The overall workflow emerges from the composition of independent parts.

Be cautious of circular chains where A triggers B triggers A. This creates an infinite loop that will exhaust resources. Design your event flows to be acyclic, with clear beginning and end points.

---

## 9.8 Error Handling in Events

Error handling for events differs from synchronous execution. When a handler fails, the error is logged with full context, but the failure does not propagate to the emitter or to other handlers. Each handler succeeds or fails independently.

This design reflects the fire-and-forget nature of event emission. The emitting feature set has already moved on by the time handlers execute. It cannot meaningfully handle handler failures because it has already returned its result. The isolation is intentional—it prevents cascading failures and keeps the emitter's behavior predictable.

For scenarios where handler success is critical, you need different patterns. You might use synchronous validation before emitting the event, checking conditions that would cause handler failure. You might use compensating events where failure handlers emit events that trigger recovery. You might move critical operations into the emitting feature set itself rather than relying on handlers.

The runtime logs all handler failures. You can configure alerts based on these logs to notify operators when handlers are failing. The logs include the event type, handler name, error message, and full context, providing the information needed to diagnose and fix issues.

---

## 9.9 Best Practices

Name events for business meaning rather than technical operations. The event name should describe what happened in domain terms that non-technical stakeholders would understand. "CustomerRegistered" tells you about a business occurrence. "DatabaseRowInserted" tells you about an implementation detail.

Keep handlers focused on single responsibilities. A handler that sends email and updates analytics and notifies administrators is doing too much. Split these into three handlers that each do one thing well. The event bus will invoke all of them, and each will be easier to understand, test, and maintain.

Design handlers for idempotency when possible. Events might be delivered more than once in some scenarios—retries after transient failures, replays for recovery, or duplicate emissions due to bugs. If handlers can safely process the same event multiple times without causing incorrect behavior, your system is more resilient.

Avoid circular event chains. If event A triggers handler B which emits event A, you have an infinite loop. Map out your event flows to ensure they are directed acyclic graphs. Each event should lead forward through the workflow, not backward to create cycles.

Document event contracts. The payload of an event is a contract between emitters and handlers. Document what fields are included, their types, and their meanings. When you change an event's structure, update all handlers to accommodate the change.

---

## 9.10 State Observers

State observers are a specialized form of event handler that react to state transitions. When the Accept action successfully transitions a state field, it emits a StateTransitionEvent that observers can handle.

<div style="float: right; margin: 0 0 1em 1.5em;">
<svg width="200" height="200" viewBox="0 0 200 200" xmlns="http://www.w3.org/2000/svg">
  <!-- Accept Action -->
  <rect x="60" y="10" width="80" height="35" rx="4" fill="#dbeafe" stroke="#3b82f6" stroke-width="2"/>
  <text x="100" y="25" text-anchor="middle" font-family="sans-serif" font-size="8" font-weight="bold" fill="#1e40af">&lt;Accept&gt;</text>
  <text x="100" y="38" text-anchor="middle" font-family="monospace" font-size="7" fill="#3b82f6">draft → placed</text>
  <!-- Arrow to event -->
  <line x1="100" y1="45" x2="100" y2="65" stroke="#f59e0b" stroke-width="2"/>
  <polygon points="100,70 95,62 105,62" fill="#f59e0b"/>
  <!-- StateTransitionEvent -->
  <rect x="35" y="70" width="130" height="25" rx="4" fill="#fef3c7" stroke="#f59e0b" stroke-width="2"/>
  <text x="100" y="87" text-anchor="middle" font-family="sans-serif" font-size="8" font-weight="bold" fill="#92400e">StateTransitionEvent</text>
  <!-- Fan-out arrows -->
  <line x1="55" y1="95" x2="35" y2="120" stroke="#22c55e" stroke-width="2"/>
  <polygon points="35,125 43,118 39,126" fill="#22c55e"/>
  <line x1="100" y1="95" x2="100" y2="120" stroke="#22c55e" stroke-width="2"/>
  <polygon points="100,125 95,117 105,117" fill="#22c55e"/>
  <line x1="145" y1="95" x2="165" y2="120" stroke="#22c55e" stroke-width="2"/>
  <polygon points="165,125 157,118 161,126" fill="#22c55e"/>
  <!-- Observers -->
  <rect x="5" y="130" width="60" height="35" rx="4" fill="#dcfce7" stroke="#22c55e" stroke-width="2"/>
  <text x="35" y="145" text-anchor="middle" font-family="sans-serif" font-size="7" font-weight="bold" fill="#166534">Audit</text>
  <text x="35" y="157" text-anchor="middle" font-family="sans-serif" font-size="6" fill="#22c55e">all transitions</text>
  <rect x="70" y="130" width="60" height="35" rx="4" fill="#dcfce7" stroke="#22c55e" stroke-width="2"/>
  <text x="100" y="145" text-anchor="middle" font-family="sans-serif" font-size="7" font-weight="bold" fill="#166534">Notify</text>
  <text x="100" y="157" text-anchor="middle" font-family="sans-serif" font-size="6" fill="#22c55e">&lt;draft_to_placed&gt;</text>
  <rect x="135" y="130" width="60" height="35" rx="4" fill="#dcfce7" stroke="#22c55e" stroke-width="2"/>
  <text x="165" y="145" text-anchor="middle" font-family="sans-serif" font-size="7" font-weight="bold" fill="#166534">Track</text>
  <text x="165" y="157" text-anchor="middle" font-family="sans-serif" font-size="6" fill="#22c55e">&lt;shipped_to_delivered&gt;</text>
  <!-- Label -->
  <text x="100" y="185" text-anchor="middle" font-family="sans-serif" font-size="7" fill="#6b7280">matching observers run after transition</text>
</svg>
</div>

State observers bridge the gap between state machines and event-driven architecture. The Accept action manages the "what"—validating and applying state transitions. Observers manage the "then what"—reacting to those transitions with side effects like audit logging, notifications, or analytics.

The observer pattern is declared through business activity naming. A feature set with business activity "status StateObserver" observes all transitions on fields named "status." Adding a transition filter like "status StateObserver<draft_to_placed>" restricts the observer to only that specific transition. A feature set with just "StateObserver" observes all state transitions regardless of field name.

```aro
(* Observe ALL status transitions *)
(Audit Order Status: status StateObserver) {
    <Extract> the <orderId> from the <transition: entityId>.
    <Extract> the <fromState> from the <transition: fromState>.
    <Extract> the <toState> from the <transition: toState>.

    <Log> the <audit: message> for the <console>
        with "[AUDIT] Order ${orderId}: ${fromState} -> ${toState}".

    <Return> an <OK: status> for the <audit>.
}

(* Observe ONLY when order is placed *)
(Notify Order Placed: status StateObserver<draft_to_placed>) {
    <Extract> the <orderId> from the <transition: entityId>.
    <Log> the <notification> for the <console>
        with "Order ${orderId} has been placed!".
    <Return> an <OK: status> for the <notification>.
}

(* Observe ONLY when order ships *)
(Send Shipping Notification: status StateObserver<paid_to_shipped>) {
    <Extract> the <order> from the <transition: entity>.
    <Extract> the <tracking> from the <order: trackingNumber>.

    <Log> the <notification> for the <console>
        with "Order shipped! Tracking: ${tracking}".

    <Return> an <OK: status> for the <notification>.
}
```

Within an observer, the transition data is available through the "transition" identifier. You extract specific fields using the familiar qualifier syntax. The fromState and toState fields tell you what changed. The fieldName and objectName provide context about where the change occurred. The entityId offers a convenient way to identify the affected entity. The entity field gives you the complete object after the transition if you need additional context.

Observers execute after the Accept action succeeds. If Accept throws because the current state does not match the expected state, no event is emitted and no observers run. This ensures observers only react to valid transitions. Observers themselves run in isolation—if one observer fails, other observers for the same transition still execute. The failure is logged but does not affect the original Accept action or other observers.

The separation between Accept and observers creates a clean architecture. Accept is synchronous and transactional—it validates and applies the state change atomically. Observers are asynchronous and independent—they react to the change with side effects that do not affect the core state transition. This separation makes the system more testable, more maintainable, and more extensible.

---

*Next: Chapter 10 — Application Lifecycle*
