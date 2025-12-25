# Chapter 10: Custom Events

*"Design your domain events like you design your domain model."*

---

## 10.1 Domain Events

Custom events represent significant occurrences in your business domain. Unlike the built-in events that the runtime generates for file changes, socket messages, and HTTP requests, custom events are defined by you to capture business-meaningful happenings within your application.

A domain event records that something important occurred. A new user registered. An order was placed. A payment was received. Inventory fell below a threshold. Each event captures a moment in time when the state of the business changed in a way that other parts of the system might care about.

The power of domain events comes from their role in decoupling. The code that causes an event does not need to know what will happen afterward. It simply announces that something occurred. Other code can react to that announcement. This separation allows you to add new reactions without modifying the original code, to test event producers and consumers independently, and to understand each part of the system in isolation.

Designing good domain events requires thinking about your business domain. What are the significant state changes? What information would observers need to react appropriately? How should events relate to each other? These questions parallel the questions you ask when designing a domain model, which is why event design and domain modeling often go hand in hand.

---

## 10.2 Emitting Events

The Emit action publishes an event to the event bus. The event has a type and a payload. The type is specified in the result position with an "event" qualifier. The payload follows the "with" preposition.

The event type becomes the name used for matching handlers. Choose event names that describe what happened rather than what should happen. Use past tense to emphasize that the event records something that already occurred. "CustomerRegistered" and "OrderPlaced" and "PaymentReceived" are good names. "RegisterCustomer" and "PlaceOrder" are commands, not events—they describe actions to be taken, not facts that have been recorded.

Event names should be specific and business-meaningful. "UserUpdated" is vague—what was updated? The user's email? Their password? Their role? More specific names like "UserEmailChanged," "UserPasswordReset," and "UserRoleUpdated" tell handlers exactly what happened, allowing them to react appropriately.

The payload is the data that travels with the event. It should contain everything that handlers might need to do their work. For a UserCreated event, include the full user object or at least the properties that handlers will need. For an OrderPlaced event, include the order details, customer information, and anything else relevant to order processing.

The payload should be self-contained. Handlers should not need to make additional queries to understand the event. If a handler needs the customer's email address to send a notification, include the email in the event payload rather than forcing the handler to retrieve it separately.

---

## 10.3 Handling Events

A feature set becomes an event handler when its business activity matches the handler pattern. The pattern consists of the event name followed by "Handler." A feature set with business activity "UserCreated Handler" handles UserCreated events. A feature set with business activity "OrderPlaced Handler" handles OrderPlaced events.

Within a handler, the event is available through the "event" identifier. You use Extract actions to pull data out of the event into local bindings. The event object contains the payload that was provided when the event was emitted, plus metadata about the event itself.

The payload structure depends on what the emitter provided. If the emitter passed a single object as the payload, you can extract properties from that object. If the emitter passed an object literal with multiple fields, you can extract each field by name. The structure of the event is an implicit contract between emitters and handlers—handlers must know what to expect.

Event metadata includes an identifier for correlating logs and traces, a timestamp recording when the event was emitted, and a source identifying which feature set emitted the event. This metadata is useful for debugging, auditing, and understanding event flows through the system.

Handlers should be focused on single responsibilities. A handler that sends email and updates analytics and notifies administrators is doing too much. Split these into separate handlers that each do one thing well. The event bus will invoke all handlers for the event, and each handler can be developed and tested independently.

---

## 10.4 Event Patterns

Several patterns emerge in how events are used to structure applications.

<div style="text-align: center; margin: 2em 0;">
<svg width="480" height="110" viewBox="0 0 480 110" xmlns="http://www.w3.org/2000/svg">  <!-- Command-Event Pattern -->  <text x="120" y="15" text-anchor="middle" font-family="sans-serif" font-size="10" font-weight="bold" fill="#1e40af">Command-Event</text>  <rect x="20" y="25" width="60" height="30" rx="3" fill="#dbeafe" stroke="#3b82f6" stroke-width="1.5"/>  <text x="50" y="43" text-anchor="middle" font-family="sans-serif" font-size="8" fill="#1e40af">Command</text>  <line x1="80" y1="40" x2="100" y2="40" stroke="#6b7280" stroke-width="1.5"/>  <polygon points="100,40 95,37 95,43" fill="#6b7280"/>  <rect x="100" y="25" width="60" height="30" rx="3" fill="#dcfce7" stroke="#22c55e" stroke-width="1.5"/>  <text x="130" y="43" text-anchor="middle" font-family="sans-serif" font-size="8" fill="#166534">Work</text>  <line x1="160" y1="40" x2="180" y2="40" stroke="#6b7280" stroke-width="1.5"/>  <polygon points="180,40 175,37 175,43" fill="#6b7280"/>  <rect x="180" y="25" width="60" height="30" rx="3" fill="#fef3c7" stroke="#f59e0b" stroke-width="1.5"/>  <text x="210" y="43" text-anchor="middle" font-family="sans-serif" font-size="8" fill="#92400e">Event</text>  <text x="120" y="75" text-anchor="middle" font-family="sans-serif" font-size="7" fill="#9ca3af">"do X" → does X → "X done"</text>  <!-- Divider -->  <line x1="260" y1="20" x2="260" y2="90" stroke="#e5e7eb" stroke-width="1"/>  <!-- Event Chain Pattern -->  <text x="370" y="15" text-anchor="middle" font-family="sans-serif" font-size="10" font-weight="bold" fill="#7c3aed">Event Chain</text>  <rect x="280" y="25" width="50" height="25" rx="3" fill="#f3e8ff" stroke="#a855f7" stroke-width="1.5"/>  <text x="305" y="41" text-anchor="middle" font-family="sans-serif" font-size="7" fill="#7c3aed">Event A</text>  <line x1="330" y1="37" x2="345" y2="37" stroke="#a855f7" stroke-width="1.5"/>  <polygon points="345,37 340,34 340,40" fill="#a855f7"/>  <rect x="345" y="25" width="50" height="25" rx="3" fill="#f3e8ff" stroke="#a855f7" stroke-width="1.5"/>  <text x="370" y="41" text-anchor="middle" font-family="sans-serif" font-size="7" fill="#7c3aed">Event B</text>  <line x1="395" y1="37" x2="410" y2="37" stroke="#a855f7" stroke-width="1.5"/>  <polygon points="410,37 405,34 405,40" fill="#a855f7"/>  <rect x="410" y="25" width="50" height="25" rx="3" fill="#f3e8ff" stroke="#a855f7" stroke-width="1.5"/>  <text x="435" y="41" text-anchor="middle" font-family="sans-serif" font-size="7" fill="#7c3aed">Event C</text>  <text x="370" y="75" text-anchor="middle" font-family="sans-serif" font-size="7" fill="#9ca3af">each handler emits next</text></svg>
</div>

The command-event pattern separates the action that causes a change from the event that records it. An HTTP handler receives a command (create a user), performs the work (validate data, store user), and emits an event (UserCreated). The command is imperative—it asks for something to happen. The event is declarative—it states what happened. This separation clarifies responsibilities and enables loose coupling.

Event chains occur when handlers emit additional events. An OrderPlaced event might trigger an inventory handler that emits InventoryReserved, which triggers a payment handler that emits PaymentProcessed, which triggers a fulfillment handler. Each step in the chain is a separate handler with its own isolation, error handling, and potential for independent evolution.

The saga pattern uses event chains to implement long-running processes that span multiple steps. A refund saga might involve reversing a payment, restoring inventory, updating the order status, and notifying the customer. Each step emits an event that triggers the next step. If a step fails, compensation events can trigger rollback of previous steps.

### Complete Saga Example: Order Processing

Here is a complete order processing saga showing event-driven choreography:

```aro
(* Step 1: HTTP handler creates order and starts the saga *)
(createOrder: Order API) {
    <Extract> the <order-data> from the <request: body>.
    <Create> the <order> with <order-data>.
    <Store> the <order> in the <order-repository>.

    (* Emit event to start the saga *)
    <Emit> an <OrderPlaced: event> with <order>.

    <Return> a <Created: status> with <order>.
}

(* Step 2: Reserve inventory when order is placed *)
(Reserve Inventory: OrderPlaced Handler) {
    <Extract> the <order> from the <event: order>.
    <Extract> the <items> from the <order: items>.

    (* Reserve each item in inventory *)
    <Retrieve> the <inventory> from the <inventory-service> for <items>.
    <Update> the <inventory> with { reserved: true }.
    <Store> the <inventory> in the <inventory-service>.

    (* Continue the saga *)
    <Emit> an <InventoryReserved: event> with <order>.
}

(* Step 3: Process payment after inventory is reserved *)
(Process Payment: InventoryReserved Handler) {
    <Extract> the <order> from the <event: order>.
    <Extract> the <amount> from the <order: total>.
    <Extract> the <payment-method> from the <order: paymentMethod>.

    (* Charge the customer *)
    <Send> the <charge-request> to the <payment-gateway> with {
        amount: <amount>,
        method: <payment-method>
    }.

    (* Continue the saga *)
    <Emit> a <PaymentProcessed: event> with <order>.
}

(* Step 4: Ship order after payment succeeds *)
(Ship Order: PaymentProcessed Handler) {
    <Extract> the <order> from the <event: order>.

    (* Update order status and create shipment *)
    <Update> the <order> with { status: "shipped" }.
    <Store> the <order> in the <order-repository>.
    <Send> the <shipment-request> to the <shipping-service> with <order>.

    (* Final event in the happy path *)
    <Emit> an <OrderShipped: event> with <order>.
}

(* Notification handler - runs in parallel with saga *)
(Notify Customer: OrderShipped Handler) {
    <Extract> the <order> from the <event: order>.
    <Extract> the <email> from the <order: customerEmail>.

    <Send> the <shipping-notification> to the <email-service> with {
        to: <email>,
        template: "order-shipped",
        order: <order>
    }.

    <Return> an <OK: status> for the <notification>.
}
```

This saga demonstrates:
- **Event chain**: OrderPlaced → InventoryReserved → PaymentProcessed → OrderShipped
- **Decoupling**: Each handler focuses on one step, unaware of the others
- **Fan-out**: Multiple handlers can listen to the same event (e.g., OrderShipped triggers both shipping and notifications)

Fan-out occurs when multiple handlers react to the same event. An OrderPlaced event might trigger handlers for inventory, payment, notifications, analytics, and fraud checking. All these handlers run when the event is emitted. Each handler focuses on its specific concern, and together they implement the complete response to a new order.

---

## 10.5 Event Design Guidelines

Good event design requires thinking about both producers and consumers.

Include sufficient context in event payloads. Handlers should have what they need without additional queries. If a UserUpdated event only contains the user identifier, every handler must retrieve the user to learn what changed. If the event includes the changes, previous values, who made the change, and when, handlers can react immediately.

Use past tense consistently. Events record what happened, not what should happen. "UserCreated" states a fact. "CreateUser" requests an action. The distinction matters because it clarifies the nature of the communication—events are announcements, not requests.

Be specific rather than generic. "UserUpdated" could mean many things. "UserEmailChanged" is unambiguous. Specific events allow handlers to know exactly what occurred and whether they should react. A handler that only cares about email changes can ignore password resets if they are separate events.

Treat event payloads as immutable. The payload is a snapshot of state at the moment the event was emitted. Handlers should not expect to modify the payload or to have modifications affect other handlers. Each handler receives an independent view of the event.

Design for evolution. Events are contracts between producers and consumers. Changing an event's structure can break consumers. When you add fields, make them optional so existing consumers continue to work. When you remove fields, ensure no consumers still depend on them. Version events if incompatible changes are necessary.

---

## 10.6 Error Handling in Events

Event handlers run in isolation. If one handler fails, other handlers for the same event still run. The emitting feature set is not affected by handler failures—it continues with its own execution regardless of what handlers do.

This isolation reflects the fire-and-forget nature of event emission. The emitter announces what happened and moves on. It does not wait for handlers to complete, does not receive their results, and does not fail if they fail. This makes event emission a non-blocking operation and prevents cascading failures.

For scenarios where handler success is important, additional patterns help. Compensation events can trigger recovery when things fail. A PaymentFailed event can trigger handlers that cancel the order and notify the customer. The failure handler runs as a reaction to the failure event, providing a mechanism for recovery without coupling the original operation to error handling.

The runtime logs all handler failures with full context. Operators can monitor these logs to detect failing handlers. Alerts can trigger when failure rates exceed thresholds. The information in the logs—event type, handler name, error message, timestamp, correlation identifier—supports diagnosis and debugging.

Designing handlers for idempotency provides resilience. If a handler can safely process the same event multiple times without incorrect behavior, temporary failures can be recovered by reprocessing the event. This is particularly valuable in distributed systems where exactly-once delivery is difficult to guarantee.

---

## 10.7 Best Practices

Name events from the perspective of the domain, not the infrastructure. "CustomerJoinedLoyaltyProgram" is a domain event. "DatabaseRowInserted" is an infrastructure event. Domain events communicate business meaning; infrastructure events communicate implementation details. Prefer domain events because they remain stable as implementations change.

Document the contract between event producers and consumers. The payload structure is an implicit contract—producers must provide what consumers expect. Documenting this contract makes the expectation explicit. Include what fields are present, their types, and their semantics. When the contract changes, communicate the change to all affected parties.

Use events for cross-cutting concerns. Audit logging, analytics, notifications, and other concerns that touch many parts of the application are natural fits for events. The code that creates a user does not need to know about audit logging—it just emits UserCreated, and an audit handler captures it.

Test handlers in isolation. Because handlers are independent feature sets with well-defined inputs (the event), they are straightforward to test. Construct a mock event with the expected payload, invoke the handler, and verify the behavior. This unit testing approach scales to complex systems.

Avoid circular event chains. If event A triggers a handler that emits event B, and event B triggers a handler that emits event A, you have an infinite loop. Map your event flows to ensure they form directed acyclic graphs with clear start and end points.

---

*Next: Chapter 11 — OpenAPI Integration*
