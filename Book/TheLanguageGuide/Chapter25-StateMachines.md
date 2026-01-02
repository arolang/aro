# Chapter 25: State Machines

*"A business object is only as valid as its current state."*

---

## 25.1 Why State Machines Matter

Business entities rarely exist in a single state. An order is drafted, placed, paid, shipped, and delivered. A support ticket is opened, assigned, escalated, and resolved. A document is drafted, reviewed, approved, and published. These lifecycles define what operations are valid at each point in time.

Without explicit state management, code becomes defensive. Developers scatter validation checks throughout the codebase: "Is this order paid?", "Can we ship this?", "Has this been approved?" These checks duplicate business rules, create inconsistencies, and make the intended lifecycle invisible.

State machines make lifecycles explicit. They define what states exist, what transitions between states are valid, and what happens when an invalid transition is attempted. The state machine becomes a source of truth for the entity's lifecycle.

---

## 25.2 ARO's Approach to State

ARO takes a deliberately simple approach to state machines. There is no state machine library, no visual editor, no hierarchical states. Instead, ARO provides a single action—`Accept`—that validates and applies state transitions within your existing feature sets.

This simplicity is intentional. Most business logic needs straightforward linear or branching state flows, not the full complexity of hierarchical state machines with parallel regions and history states. By using a simple primitive, ARO keeps the language small while enabling the patterns that matter most.

States in ARO are defined as OpenAPI enum types. This means your API contract documents the valid states for each entity. Clients can see what states exist. Tooling can validate state values. The contract becomes the single source of truth.

---

## 25.3 Defining States in OpenAPI

States are defined as string enums in your OpenAPI specification. Here is how an order lifecycle might be defined:

```yaml
components:
  schemas:
    OrderStatus:
      type: string
      description: Valid order states in the lifecycle
      enum:
        - draft
        - placed
        - paid
        - shipped
        - delivered
        - cancelled
```

The enum values define all possible states. The order in the enum often reflects the expected progression, though this is convention rather than enforcement. An order typically flows from draft through placed, paid, shipped, to delivered—but the enum itself does not encode these transitions.

The entity schema references this status type:

```yaml
    Order:
      type: object
      properties:
        id:
          type: string
        status:
          $ref: '#/components/schemas/OrderStatus'
        customerId:
          type: string
        items:
          type: array
          items:
            $ref: '#/components/schemas/OrderItem'
```

This creates a clear contract: orders have a status field that must be one of the defined enum values. The API documentation shows clients exactly what states exist.

---

## 25.4 The Accept Action

<div style="float: right; margin: 0 0 1em 1.5em;">
<svg width="180" height="200" viewBox="0 0 180 200" xmlns="http://www.w3.org/2000/svg">
  <!-- Title -->
  <text x="90" y="15" text-anchor="middle" font-family="sans-serif" font-size="10" font-weight="bold" fill="#374151">Accept Action Flow</text>

  <!-- Current State -->
  <rect x="55" y="30" width="70" height="28" rx="4" fill="#dbeafe" stroke="#3b82f6" stroke-width="1.5"/>
  <text x="90" y="48" text-anchor="middle" font-family="sans-serif" font-size="9" fill="#1e40af">Current State</text>

  <!-- Arrow down -->
  <line x1="90" y1="58" x2="90" y2="72" stroke="#6b7280" stroke-width="1.5"/>
  <polygon points="90,72 86,66 94,66" fill="#6b7280"/>

  <!-- Check box -->
  <rect x="40" y="75" width="100" height="28" rx="4" fill="#fef3c7" stroke="#f59e0b" stroke-width="1.5"/>
  <text x="90" y="93" text-anchor="middle" font-family="sans-serif" font-size="9" fill="#92400e">Validate: from?</text>

  <!-- Branch -->
  <line x1="90" y1="103" x2="90" y2="115" stroke="#6b7280" stroke-width="1"/>

  <!-- Yes branch -->
  <line x1="90" y1="115" x2="50" y2="130" stroke="#22c55e" stroke-width="1.5"/>
  <polygon points="50,130 56,124 52,132" fill="#22c55e"/>
  <text x="55" y="125" font-family="sans-serif" font-size="7" fill="#22c55e">match</text>

  <!-- No branch -->
  <line x1="90" y1="115" x2="130" y2="130" stroke="#ef4444" stroke-width="1.5"/>
  <polygon points="130,130 124,124 128,132" fill="#ef4444"/>
  <text x="120" y="125" font-family="sans-serif" font-size="7" fill="#ef4444">no match</text>

  <!-- Success: Update -->
  <rect x="15" y="135" width="70" height="28" rx="4" fill="#dcfce7" stroke="#22c55e" stroke-width="1.5"/>
  <text x="50" y="153" text-anchor="middle" font-family="sans-serif" font-size="9" fill="#166534">Update to: to</text>

  <!-- Failure: Error -->
  <rect x="95" y="135" width="70" height="28" rx="4" fill="#fee2e2" stroke="#ef4444" stroke-width="1.5"/>
  <text x="130" y="153" text-anchor="middle" font-family="sans-serif" font-size="9" fill="#991b1b">Throw Error</text>

  <!-- Continue -->
  <line x1="50" y1="163" x2="50" y2="180" stroke="#22c55e" stroke-width="1.5"/>
  <polygon points="50,180 46,174 54,174" fill="#22c55e"/>
  <text x="50" y="193" text-anchor="middle" font-family="sans-serif" font-size="8" fill="#166534">continue</text>
</svg>
</div>

The `Accept` action validates and applies state transitions. It checks that an object's current state matches an expected "from" state, and if so, updates it to a "to" state. If the current state does not match, execution stops with a descriptive error.

The syntax uses the `_to_` separator to specify the transition:

```aro
<Accept> the <transition: from_to_target> on <object: field>.
```

The transition specifier contains both states separated by `_to_`. The object specifier identifies which entity and which field to examine and update.

Here is a concrete example that transitions an order from draft to placed:

```aro
<Accept> the <transition: draft_to_placed> on <order: status>.
```

This statement does three things:

1. Retrieves the current value of `order.status`
2. Validates that the current value equals `"draft"`
3. Updates `order.status` to `"placed"`

If the order's status is not `"draft"`, execution stops with an error. The caller receives a message explaining what went wrong.

---

## 25.5 State Transition Validation

The Accept action provides clear error messages when transitions fail. If you attempt to place an order that has already been paid:

```
Cannot accept state draft->placed on order: status. Current state is "paid".
```

This message tells you exactly what happened: the transition expected the order to be in draft state, but it was actually in paid state. No stack traces, no cryptic error codes—just a clear statement of the business rule violation.

This follows ARO's happy path philosophy. You write code for the expected flow. The runtime handles the error cases automatically, generating messages that describe the problem in business terms.

Consider what this means for debugging. When a user reports "I can't place my order," you know immediately that the order is not in draft state. The error message tells you the actual state. You can investigate why the order reached that state without the transition being attempted first.

---

## 25.6 Complete Example: Order Lifecycle

<div style="float: left; margin: 0 1.5em 1em 0;">
<svg width="140" height="280" viewBox="0 0 140 280" xmlns="http://www.w3.org/2000/svg">
  <!-- Title -->
  <text x="70" y="15" text-anchor="middle" font-family="sans-serif" font-size="10" font-weight="bold" fill="#374151">Order Lifecycle</text>

  <!-- Draft -->
  <rect x="35" y="28" width="70" height="24" rx="12" fill="#e0e7ff" stroke="#6366f1" stroke-width="1.5"/>
  <text x="70" y="44" text-anchor="middle" font-family="sans-serif" font-size="9" fill="#4338ca">draft</text>

  <!-- Arrow to placed -->
  <line x1="70" y1="52" x2="70" y2="68" stroke="#22c55e" stroke-width="1.5"/>
  <polygon points="70,68 66,62 74,62" fill="#22c55e"/>

  <!-- Placed -->
  <rect x="35" y="72" width="70" height="24" rx="12" fill="#dbeafe" stroke="#3b82f6" stroke-width="1.5"/>
  <text x="70" y="88" text-anchor="middle" font-family="sans-serif" font-size="9" fill="#1e40af">placed</text>

  <!-- Arrow to paid -->
  <line x1="70" y1="96" x2="70" y2="112" stroke="#22c55e" stroke-width="1.5"/>
  <polygon points="70,112 66,106 74,106" fill="#22c55e"/>

  <!-- Paid -->
  <rect x="35" y="116" width="70" height="24" rx="12" fill="#dcfce7" stroke="#22c55e" stroke-width="1.5"/>
  <text x="70" y="132" text-anchor="middle" font-family="sans-serif" font-size="9" fill="#166534">paid</text>

  <!-- Arrow to shipped -->
  <line x1="70" y1="140" x2="70" y2="156" stroke="#22c55e" stroke-width="1.5"/>
  <polygon points="70,156 66,150 74,150" fill="#22c55e"/>

  <!-- Shipped -->
  <rect x="35" y="160" width="70" height="24" rx="12" fill="#fef3c7" stroke="#f59e0b" stroke-width="1.5"/>
  <text x="70" y="176" text-anchor="middle" font-family="sans-serif" font-size="9" fill="#92400e">shipped</text>

  <!-- Arrow to delivered -->
  <line x1="70" y1="184" x2="70" y2="200" stroke="#22c55e" stroke-width="1.5"/>
  <polygon points="70,200 66,194 74,194" fill="#22c55e"/>

  <!-- Delivered -->
  <rect x="35" y="204" width="70" height="24" rx="12" fill="#d1fae5" stroke="#10b981" stroke-width="2"/>
  <text x="70" y="220" text-anchor="middle" font-family="sans-serif" font-size="9" font-weight="bold" fill="#065f46">delivered</text>

  <!-- Cancel branch from draft -->
  <line x1="35" y1="40" x2="15" y2="40" stroke="#ef4444" stroke-width="1" stroke-dasharray="3,2"/>
  <line x1="15" y1="40" x2="15" y2="248" stroke="#ef4444" stroke-width="1" stroke-dasharray="3,2"/>
  <line x1="15" y1="248" x2="35" y2="248" stroke="#ef4444" stroke-width="1" stroke-dasharray="3,2"/>
  <polygon points="35,248 30,245 30,251" fill="#ef4444"/>

  <!-- Cancelled -->
  <rect x="35" y="236" width="70" height="24" rx="12" fill="#fee2e2" stroke="#ef4444" stroke-width="1.5"/>
  <text x="70" y="252" text-anchor="middle" font-family="sans-serif" font-size="9" fill="#991b1b">cancelled</text>

  <!-- Cancel label -->
  <text x="8" y="145" font-family="sans-serif" font-size="7" fill="#ef4444" transform="rotate(-90, 8, 145)">cancel</text>
</svg>
</div>

Let us walk through a complete order management service that uses state transitions. Orders flow through a lifecycle: they start as drafts, get placed, are paid for, ship, and finally arrive. At any point before placement, an order can be cancelled.

First, the OpenAPI contract defines the states and the operations that trigger transitions:

```yaml
paths:
  /orders/{id}/place:
    post:
      operationId: placeOrder
      summary: Place a draft order
      description: Transitions from draft to placed

  /orders/{id}/pay:
    post:
      operationId: payOrder
      summary: Record payment
      description: Transitions from placed to paid

  /orders/{id}/ship:
    post:
      operationId: shipOrder
      summary: Ship the order
      description: Transitions from paid to shipped

  /orders/{id}/deliver:
    post:
      operationId: deliverOrder
      summary: Mark as delivered
      description: Transitions from shipped to delivered

  /orders/{id}/cancel:
    post:
      operationId: cancelOrder
      summary: Cancel an order
      description: Only valid from draft state
```

Each endpoint documents which state transition it performs. This makes the API self-documenting—clients can see the lifecycle from the contract.

Now the ARO feature sets that implement these transitions:

```aro
(* Create a new order in draft state *)
(createOrder: Order Management) {
    <Extract> the <data> from the <request: body>.
    <Create> the <order: Order> with <data>.
    <Update> the <order: status> with "draft".
    <Store> the <order> into the <order-repository>.
    <Return> a <Created: status> with <order>.
}

(* Place an order - transitions from draft to placed *)
(placeOrder: Order Management) {
    <Extract> the <order-id> from the <pathParameters: id>.
    <Retrieve> the <order> from the <order-repository>
        where <id> is <order-id>.

    <Accept> the <transition: draft_to_placed> on <order: status>.

    <Store> the <order> into the <order-repository>.
    <Return> an <OK: status> with <order>.
}
```

The `createOrder` feature set explicitly sets the initial state to "draft". This makes the starting point clear in the code. The `placeOrder` feature set uses `Accept` to validate the transition before updating storage.

The remaining transitions follow the same pattern:

```aro
(* Pay for an order - transitions from placed to paid *)
(payOrder: Order Management) {
    <Extract> the <order-id> from the <pathParameters: id>.
    <Extract> the <payment> from the <request: body>.
    <Retrieve> the <order> from the <order-repository>
        where <id> is <order-id>.

    <Accept> the <transition: placed_to_paid> on <order: status>.

    <Update> the <order: paymentMethod> from the <payment: paymentMethod>.
    <Store> the <order> into the <order-repository>.
    <Return> an <OK: status> with <order>.
}

(* Ship an order - transitions from paid to shipped *)
(shipOrder: Order Management) {
    <Extract> the <order-id> from the <pathParameters: id>.
    <Extract> the <shipping> from the <request: body>.
    <Retrieve> the <order> from the <order-repository>
        where <id> is <order-id>.

    <Accept> the <transition: paid_to_shipped> on <order: status>.

    <Update> the <order: trackingNumber>
        from the <shipping: trackingNumber>.
    <Store> the <order> into the <order-repository>.
    <Return> an <OK: status> with <order>.
}

(* Deliver an order - transitions from shipped to delivered *)
(deliverOrder: Order Management) {
    <Extract> the <order-id> from the <pathParameters: id>.
    <Retrieve> the <order> from the <order-repository>
        where <id> is <order-id>.

    <Accept> the <transition: shipped_to_delivered> on <order: status>.

    <Store> the <order> into the <order-repository>.
    <Return> an <OK: status> with <order>.
}
```

Each feature set retrieves the order, validates and applies its transition, stores the result, and returns. The business logic is clear: you can pay a placed order, ship a paid order, and deliver a shipped order. Any attempt to skip steps fails with a descriptive error.

---

## 25.7 Cancellation Paths

Real business processes have more than one terminal state. Orders can be cancelled as well as delivered. The state machine must define which transitions lead to cancellation.

```aro
(* Cancel an order - only valid from draft state *)
(cancelOrder: Order Management) {
    <Extract> the <order-id> from the <pathParameters: id>.
    <Retrieve> the <order> from the <order-repository>
        where <id> is <order-id>.

    <Accept> the <transition: draft_to_cancelled> on <order: status>.

    <Store> the <order> into the <order-repository>.
    <Return> an <OK: status> with <order>.
}
```

This implementation only allows cancellation from the draft state. If you need to allow cancellation from multiple states, you have options.

One approach is multiple feature sets with different transitions:

```aro
(* Cancel from draft *)
(cancelDraftOrder: Order Management) {
    (* ... *)
    <Accept> the <transition: draft_to_cancelled> on <order: status>.
    (* ... *)
}

(* Cancel from placed - might require refund logic *)
(cancelPlacedOrder: Order Management) {
    (* ... *)
    <Accept> the <transition: placed_to_cancelled> on <order: status>.
    <Emit> a <RefundRequired: event> with <order>.
    (* ... *)
}
```

Another approach is conditional logic using standard control flow:

```aro
(cancelOrder: Order Management) {
    <Extract> the <order-id> from the <pathParameters: id>.
    <Retrieve> the <order> from the <order-repository>
        where <id> is <order-id>.

    (* Check current state and apply appropriate transition *)
    match <order: status> {
        case "draft" {
            <Accept> the <transition: draft_to_cancelled> on <order: status>.
        }
        case "placed" {
            <Accept> the <transition: placed_to_cancelled> on <order: status>.
            <Emit> a <RefundRequired: event> with <order>.
        }
    }

    <Store> the <order> into the <order-repository>.
    <Return> an <OK: status> with <order>.
}
```

The choice depends on whether the different cancellation paths have different side effects. If cancelling a placed order requires a refund but cancelling a draft does not, separate feature sets make the distinction clear.

---

## 25.8 What ARO Does Not Do

ARO's state machine approach is deliberately minimal. Understanding what it does not do helps you decide when simpler approaches suffice and when you need external tooling.

**No hierarchical states.** States are flat strings. If you need a state like "processing.validating" or "processing.charging", you would model these as separate states or use a separate field for the sub-state.

**No parallel states.** An entity has one state at a time. If you need to track multiple concurrent aspects—order fulfillment state and payment state separately—use multiple state fields, each with its own transitions.

**No entry or exit actions.** The Accept action does not automatically trigger code when entering or leaving a state. If you need side effects on state change, add explicit statements after the Accept action or emit events that handlers process.

**No state machine visualization.** ARO does not generate state diagrams from your code. The OpenAPI contract with its enum and operation descriptions serves as documentation. For visual diagrams, use external tools with your OpenAPI spec as input.

**No automatic validation against the enum.** The Accept action validates that the current state matches the expected "from" state. It does not validate that both "from" and "to" are members of the OpenAPI enum. That validation happens when you store the entity or when an HTTP response is serialized.

These limitations are features, not bugs. They keep the language simple. For most business applications, flat states with explicit transitions are sufficient. When you need the full power of statecharts, integrate a dedicated state machine library through custom actions.

---

## 25.9 Combining States with Events

State transitions naturally pair with events. When an order moves to a new state, other parts of the system often need to react. Shipping needs to know when orders are paid. Notifications need to know when orders are delivered.

```aro
(shipOrder: Order Management) {
    <Extract> the <order-id> from the <pathParameters: id>.
    <Retrieve> the <order> from the <order-repository>
        where <id> is <order-id>.

    <Accept> the <transition: paid_to_shipped> on <order: status>.

    <Store> the <order> into the <order-repository>.

    (* Notify interested parties *)
    <Emit> an <OrderShipped: event> with <order>.

    <Return> an <OK: status> with <order>.
}

(* Handler reacts to the state change *)
(Notify Customer: OrderShipped Handler) {
    <Extract> the <order> from the <event: order>.
    <Extract> the <customer-email> from the <order: customerEmail>.
    <Extract> the <tracking> from the <order: trackingNumber>.

    <Send> the <shipping-notification: email> to <customer-email>
        with <tracking>.

    <Return> an <OK: status> for the <notification>.
}
```

The feature set that changes state is responsible for emitting events. Handlers subscribe to those events and perform side effects. This separation keeps the state transition code focused on the transition itself while allowing arbitrary reactions through the event system.

This pattern also supports saga-style workflows where a state change in one entity triggers state changes in others, each with its own validation.

### 22.9.1 State-Guarded Handlers

Sometimes you want handlers to only execute when an entity is in a specific state. Rather than checking the state inside the handler, you can filter events at the handler definition using state guards:

```aro
(* Only process orders that are in "paid" state *)
(Process Paid Order: OrderUpdated Handler<status:paid>) {
    <Extract> the <order> from the <event: order>.
    (* This handler only runs when order.status = "paid" *)
    <Process> the <fulfillment> for the <order>.
    <Return> an <OK: status> for the <processing>.
}
```

State guards use angle bracket syntax after "Handler":

- `<field:value>` - Match when field equals value
- `<field:value1,value2>` - Match when field equals any value (OR logic)
- `<field1:value;field2:value>` - Match when both conditions are true (AND logic)

```aro
(* Handle orders that are paid OR shipped *)
(Track Fulfillment: OrderUpdated Handler<status:paid,shipped>) {
    <Extract> the <order> from the <event: order>.
    <Log> "Tracking update" to the <console>.
    <Return> an <OK: status> for the <tracking>.
}

(* Only premium customers with delivered orders *)
(VIP Reward: OrderUpdated Handler<status:delivered;tier:premium>) {
    <Extract> the <order> from the <event: order>.
    <Send> the <reward> to the <order: email>.
    <Return> an <OK: status> for the <reward>.
}
```

State guards enable guaranteed ordering through state-based filtering. Instead of relying on event order, you can ensure handlers only execute when the entity has reached a specific state.

---

## 25.10 Best Practices

**Define all states in OpenAPI.** The contract should be the source of truth for what states exist. Clients and tooling can use this information.

**Use explicit initial states.** When creating entities, set their initial state explicitly rather than relying on defaults. This makes the starting point visible in the code.

**Document transitions in OpenAPI descriptions.** Each endpoint that changes state should document which transition it performs. The `description` field is a good place for this.

**Keep states coarse-grained.** Prefer fewer states with clear business meaning over many fine-grained states. "Processing" is often better than "validating", "charging", "confirming" as separate states unless those distinctions matter to callers.

**Emit events on state changes.** Other parts of the system often need to know when state changes. Emit events after successful transitions to enable loose coupling.

**Handle the cancelled state carefully.** Cancellation often needs cleanup—refunds, inventory release, notification. Use events to trigger this cleanup from handlers rather than cramming it into the cancellation feature set.

**Test transition failures.** Write tests that attempt invalid transitions and verify the correct error is returned. This documents the state machine constraints and catches regressions.

---

*Next: Chapter 26 — Modules and Imports*
