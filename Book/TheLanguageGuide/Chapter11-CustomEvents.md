# Chapter 11: Custom Events

*"Design your domain events like you design your domain model."*

---

> **See Chapter 9** for event bus mechanics, including emitting events, handling events, and error handling patterns.

---

## 11.1 Domain Events

Custom events represent significant occurrences in your business domain. Unlike the built-in events that the runtime generates for file changes, socket messages, and HTTP requests, custom events are defined by you to capture business-meaningful happenings within your application.

A domain event records that something important occurred. A new user registered. An order was placed. A payment was received. Inventory fell below a threshold. Each event captures a moment in time when the state of the business changed in a way that other parts of the system might care about.

The power of domain events comes from their role in decoupling. The code that causes an event does not need to know what will happen afterward. It simply announces that something occurred. Other code can react to that announcement. This separation allows you to add new reactions without modifying the original code, to test event producers and consumers independently, and to understand each part of the system in isolation.

Designing good domain events requires thinking about your business domain. What are the significant state changes? What information would observers need to react appropriately? How should events relate to each other? These questions parallel the questions you ask when designing a domain model, which is why event design and domain modeling often go hand in hand.

---

## 11.2 Event Patterns

Several patterns emerge in how events are used to structure applications.

<div style="text-align: center; margin: 2em 0;">
<svg width="480" height="110" viewBox="0 0 480 110" xmlns="http://www.w3.org/2000/svg">  <!-- Command-Event Pattern -->  <text x="120" y="15" text-anchor="middle" font-family="sans-serif" font-size="10" font-weight="bold" fill="#1e40af">Command-Event</text>  <rect x="20" y="25" width="60" height="30" rx="3" fill="#dbeafe" stroke="#3b82f6" stroke-width="1.5"/>  <text x="50" y="43" text-anchor="middle" font-family="sans-serif" font-size="8" fill="#1e40af">Command</text>  <line x1="80" y1="40" x2="100" y2="40" stroke="#6b7280" stroke-width="1.5"/>  <polygon points="100,40 95,37 95,43" fill="#6b7280"/>  <rect x="100" y="25" width="60" height="30" rx="3" fill="#dcfce7" stroke="#22c55e" stroke-width="1.5"/>  <text x="130" y="43" text-anchor="middle" font-family="sans-serif" font-size="8" fill="#166534">Work</text>  <line x1="160" y1="40" x2="180" y2="40" stroke="#6b7280" stroke-width="1.5"/>  <polygon points="180,40 175,37 175,43" fill="#6b7280"/>  <rect x="180" y="25" width="60" height="30" rx="3" fill="#fef3c7" stroke="#f59e0b" stroke-width="1.5"/>  <text x="210" y="43" text-anchor="middle" font-family="sans-serif" font-size="8" fill="#92400e">Event</text>  <text x="120" y="75" text-anchor="middle" font-family="sans-serif" font-size="7" fill="#9ca3af">"do X" → does X → "X done"</text>  <!-- Divider -->  <line x1="260" y1="20" x2="260" y2="90" stroke="#e5e7eb" stroke-width="1"/>  <!-- Event Chain Pattern -->  <text x="370" y="15" text-anchor="middle" font-family="sans-serif" font-size="10" font-weight="bold" fill="#7c3aed">Event Chain</text>  <rect x="280" y="25" width="50" height="25" rx="3" fill="#f3e8ff" stroke="#a855f7" stroke-width="1.5"/>  <text x="305" y="41" text-anchor="middle" font-family="sans-serif" font-size="7" fill="#7c3aed">Event A</text>  <line x1="330" y1="37" x2="345" y2="37" stroke="#a855f7" stroke-width="1.5"/>  <polygon points="345,37 340,34 340,40" fill="#a855f7"/>  <rect x="345" y="25" width="50" height="25" rx="3" fill="#f3e8ff" stroke="#a855f7" stroke-width="1.5"/>  <text x="370" y="41" text-anchor="middle" font-family="sans-serif" font-size="7" fill="#7c3aed">Event B</text>  <line x1="395" y1="37" x2="410" y2="37" stroke="#a855f7" stroke-width="1.5"/>  <polygon points="410,37 405,34 405,40" fill="#a855f7"/>  <rect x="410" y="25" width="50" height="25" rx="3" fill="#f3e8ff" stroke="#a855f7" stroke-width="1.5"/>  <text x="435" y="41" text-anchor="middle" font-family="sans-serif" font-size="7" fill="#7c3aed">Event C</text>  <text x="370" y="75" text-anchor="middle" font-family="sans-serif" font-size="7" fill="#9ca3af">each handler emits next</text></svg>
</div>

The **command-event pattern** separates the action that causes a change from the event that records it. An HTTP handler receives a command (create a user), performs the work (validate data, store user), and emits an event (UserCreated). The command is imperative—it asks for something to happen. The event is declarative—it states what happened. This separation clarifies responsibilities and enables loose coupling.

**Event chains** occur when handlers emit additional events. An OrderPlaced event might trigger an inventory handler that emits InventoryReserved, which triggers a payment handler that emits PaymentProcessed, which triggers a fulfillment handler. Each step in the chain is a separate handler with its own isolation, error handling, and potential for independent evolution.

The **saga pattern** uses event chains to implement long-running processes that span multiple steps. A refund saga might involve reversing a payment, restoring inventory, updating the order status, and notifying the customer. Each step emits an event that triggers the next step. If a step fails, compensation events can trigger rollback of previous steps.

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

### Alternative: State-Driven Saga with Observers

The same order processing can be implemented using **state transitions** and **observers**. The HTTP handler drives the workflow through state transitions, while observers react automatically to perform side effects. This approach is more declarative and reduces boilerplate.

First, define the order states in your OpenAPI schema:

```yaml
# openapi.yaml (excerpt)
components:
  schemas:
    OrderStatus:
      type: string
      enum: [draft, placed, paid, shipped]
```

Then implement the workflow:

```aro
(* HTTP handler drives the entire workflow through state transitions *)
(processOrder: Order API) {
    <Extract> the <order-data> from the <request: body>.
    <Create> the <order> with <order-data>.

    (* Each Accept triggers its observers *)
    <Accept> the <transition: draft_to_placed> on <order: status>.
    <Accept> the <transition: placed_to_paid> on <order: status>.
    <Accept> the <transition: paid_to_shipped> on <order: status>.

    <Store> the <order> into the <order-repository>.
    <Return> a <Created: status> with <order>.
}

(* Observers react to state transitions with side effects *)
(Reserve Inventory: status StateObserver<draft_to_placed>) {
    <Extract> the <order> from the <transition: entity>.
    <Retrieve> the <inventory> from the <inventory-service> for <order: items>.
    <Update> the <inventory> with { reserved: true }.
    <Store> the <inventory> into the <inventory-service>.
}

(Process Payment: status StateObserver<placed_to_paid>) {
    <Extract> the <order> from the <transition: entity>.
    <Send> the <charge> to the <payment-gateway> with {
        amount: <order: total>,
        method: <order: paymentMethod>
    }.
}

(Ship Order: status StateObserver<paid_to_shipped>) {
    <Extract> the <order> from the <transition: entity>.
    <Send> the <shipment> to the <shipping-service> with <order>.
}

(Notify Customer: status StateObserver<paid_to_shipped>) {
    <Extract> the <order> from the <transition: entity>.
    <Send> the <notification> to the <email-service> with {
        to: <order: customerEmail>,
        template: "order-shipped"
    }.
}
```

This state-driven approach demonstrates:
- **Centralized flow**: The HTTP handler drives the workflow through sequential `<Accept>` calls
- **Implicit triggers**: Observers fire automatically when state transitions occur
- **Focused observers**: Each observer handles one side effect, no event emission needed
- **Same fan-out**: Multiple observers react to `paid_to_shipped` (shipping and notification)
- **Less code**: ~35 lines vs ~70 lines in the event-driven version

Both approaches achieve the same result. Choose explicit events when you need rich custom payloads or complex choreography. Choose state observers when your workflow maps naturally to state transitions and observers need only the entity itself.

---

## 11.3 Event Design Guidelines

Good event design requires thinking about both producers and consumers.

**Include sufficient context in event payloads.** Handlers should have what they need without additional queries. If a UserUpdated event only contains the user identifier, every handler must retrieve the user to learn what changed. If the event includes the changes, previous values, who made the change, and when, handlers can react immediately.

**Use past tense consistently.** Events record what happened, not what should happen. "UserCreated" states a fact. "CreateUser" requests an action. The distinction matters because it clarifies the nature of the communication—events are announcements, not requests.

**Be specific rather than generic.** "UserUpdated" could mean many things. "UserEmailChanged" is unambiguous. Specific events allow handlers to know exactly what occurred and whether they should react. A handler that only cares about email changes can ignore password resets if they are separate events.

**Treat event payloads as immutable.** The payload is a snapshot of state at the moment the event was emitted. Handlers should not expect to modify the payload or to have modifications affect other handlers. Each handler receives an independent view of the event.

**Design for evolution.** Events are contracts between producers and consumers. Changing an event's structure can break consumers. When you add fields, make them optional so existing consumers continue to work. When you remove fields, ensure no consumers still depend on them. Version events if incompatible changes are necessary.

---

## 11.4 Best Practices

**Name events from the perspective of the domain, not the infrastructure.** "CustomerJoinedLoyaltyProgram" is a domain event. "DatabaseRowInserted" is an infrastructure event. Domain events communicate business meaning; infrastructure events communicate implementation details. Prefer domain events because they remain stable as implementations change.

**Document the contract between event producers and consumers.** The payload structure is an implicit contract—producers must provide what consumers expect. Documenting this contract makes the expectation explicit. Include what fields are present, their types, and their semantics. When the contract changes, communicate the change to all affected parties.

**Use events for cross-cutting concerns.** Audit logging, analytics, notifications, and other concerns that touch many parts of the application are natural fits for events. The code that creates a user does not need to know about audit logging—it just emits UserCreated, and an audit handler captures it.

**Test handlers in isolation.** Because handlers are independent feature sets with well-defined inputs (the event), they are straightforward to test. Construct a mock event with the expected payload, invoke the handler, and verify the behavior. This unit testing approach scales to complex systems.

---

*Next: Chapter 12 — OpenAPI Integration*
