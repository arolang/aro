# Chapter 13B: Handler Guards

*"The best conditional is one that never runs."*

---

## 13B.1 The Filtering Problem

Event handlers often care about only a subset of events carrying a given type. A payment handler only needs events where the order status is `paid`. An adult-only notification handler only needs events targeting users who are 18 or older. A premium shipping handler only needs events where both the customer tier is `premium` and the destination region is `express`.

The naive approach is to put conditionals inside the handler body:

```aro
(Process Payment: OrderUpdated Handler) {
    Extract the <status> from the <event: status>.
    when <status> = "paid" {
        (* ... do the work ... *)
    }
    Return an <OK: status> for the <processing>.
}
```

This works, but it means every `OrderUpdated` event causes the handler to start, extract data, and evaluate a condition — just to decide whether to do anything. The handler body carries conditional logic that is really about routing, not about processing.

ARO provides two mechanisms for moving this filtering to the handler's declaration, so the runtime can skip inappropriate events entirely before any statements run.

---

## 13B.2 Two Guard Mechanisms

| Mechanism | Syntax | Supports | When to use |
|-----------|--------|----------|-------------|
| **`when` guard** | `(Name: EventType Handler) when <field> >= value {` | Any comparison operator | Inequality, ranges, complex conditions |
| **Field-value guard** | `(Name: EventType Handler<field:value>)` | Equality only, with OR/AND | Simple equality matching on event fields |

Both guards evaluate before any statements in the handler body execute. A handler that fails its guard is silently skipped — no statements run, no error is produced, no log is written.

The two mechanisms can be combined when needed.

---

## 13B.3 The `when` Guard

The `when` keyword appears between the closing `)` of the header and the opening `{` of the body:

```aro
(Feature Name: EventType Handler) when <condition> {
    (* body only runs if condition is true *)
}
```

### Syntax

```aro
(Greet Adults: NotificationSent Handler) when <age> >= 18 {
    Extract the <user> from the <event: user>.
    Extract the <name> from the <user: name>.
    Log "Hello, " ++ <name> to the <console>.
    Return an <OK: status> for the <greeting>.
}
```

### Field Context

When the `Notify` action targets an object, the fields of that object are available directly in the `when` condition without an `Extract` step. The runtime binds the target's properties into the guard evaluation context automatically.

In the example above, `<age>` resolves to the `age` field of the notified object — not to anything declared inside the handler body.

For regular event handlers (not Notify), the event payload fields are available in the same way. If the event carries `{ status: "paid", amount: 150 }`, the guard `when <amount> > 100` resolves `amount` from the payload.

### Comparison Operators

The `when` guard supports the full set of comparison operators:

| Operator | Meaning |
|----------|---------|
| `=` | Equal |
| `!=` | Not equal |
| `<` | Less than |
| `<=` | Less than or equal |
| `>` | Greater than |
| `>=` | Greater than or equal |

String equality uses `=` and `!=`. Numeric comparisons use the full range. Boolean checks use `= true` or `= false`.

```aro
(* String equality *)
(Handle Paid Orders: OrderUpdated Handler) when <status> = "paid" {
    ...
}

(* Numeric comparison *)
(Flag Large Orders: OrderCreated Handler) when <amount> >= 1000 {
    ...
}

(* Boolean flag *)
(Process Verified Users: UserUpdated Handler) when <verified> = true {
    ...
}
```

---

## 13B.4 The Field-Value Guard

For equality matching, ARO provides a compact syntax that embeds the guard directly in the business activity string, inside angle brackets after `Handler`:

```aro
(Feature Name: EventType Handler<field:value>) {
    (* body only runs if event's 'field' equals 'value' *)
}
```

Note there is no space between `Handler` and `<`:

```aro
(Process Payment: OrderUpdated Handler<status:paid>) { ... }   (* correct *)
(Process Payment: OrderUpdated Handler <status:paid>) { ... }  (* incorrect *)
```

### Equality Matching

The guard checks whether the named field in the event payload equals the specified value. Matching is case-insensitive — `paid`, `PAID`, and `Paid` all match `<status:paid>`.

```aro
(Process Payment: OrderUpdated Handler<status:paid>) {
    Extract the <order> from the <event: order>.
    Extract the <amount> from the <order: amount>.
    Log "Processing payment of " ++ <amount> to the <console>.
    Return an <OK: status> for the <processing>.
}
```

This handler only executes when the `OrderUpdated` event carries a `status` field whose value is `"paid"` (case-insensitive). All other `OrderUpdated` events are silently skipped.

### Type Coercion

Non-string values are converted to strings for comparison:

| Field type | Conversion |
|------------|------------|
| String | Lowercased directly |
| Integer | String representation (`5` → `"5"`) |
| Double | String representation |
| Boolean | `"true"` or `"false"` |

So `<status:5>` matches an event where `status` is the integer `5` as well as the string `"5"`.

---

## 13B.5 OR Logic

To match any one of several values for the same field, separate the values with commas (no spaces):

```aro
(Track Fulfillment: OrderUpdated Handler<status:paid,shipped>) {
    Extract the <order> from the <event: order>.
    Log "Fulfillment update" to the <console>.
    Return an <OK: status> for the <tracking>.
}
```

This handler fires when `status` equals `"paid"` **OR** `"shipped"`. Any other status value is skipped.

```aro
(* Three-way OR *)
(Log Terminal States: OrderUpdated Handler<status:delivered,cancelled,refunded>) {
    Extract the <id> from the <event: orderId>.
    Log "Order " ++ <id> ++ " reached a terminal state" to the <console>.
    Return an <OK: status> for the <logging>.
}
```

---

## 13B.6 AND Logic

To require multiple conditions to all be true, separate them with semicolons:

```aro
(VIP Notification: OrderUpdated Handler<status:delivered;tier:premium>) {
    Extract the <order> from the <event: order>.
    Send the <vip-reward> to the <order: email>.
    Return an <OK: status> for the <notification>.
}
```

This handler fires only when `status` is `"delivered"` **AND** `tier` is `"premium"`. An order that is delivered but not premium, or premium but not yet delivered, does not trigger this handler.

---

## 13B.7 Combined OR and AND

Each semicolon-separated condition can itself have multiple comma-separated values. The full logic is: **each condition must match at least one of its values**, and **all conditions must match**:

```aro
(* (status = paid OR shipped) AND (tier = premium OR enterprise) *)
(Priority Fulfillment: OrderUpdated Handler<status:paid,shipped;tier:premium,enterprise>) {
    Extract the <order> from the <event: order>.
    Emit a <PriorityFulfillment: event> with <order>.
    Return an <OK: status> for the <priority>.
}
```

This is `(paid OR shipped) AND (premium OR enterprise)` — four value combinations, two conditions, one handler.

<div style="text-align: center; margin: 2em 0;">
<svg width="400" height="120" viewBox="0 0 400 120" xmlns="http://www.w3.org/2000/svg">
  <text x="200" y="16" text-anchor="middle" font-family="sans-serif" font-size="10" font-weight="bold" fill="#374151">Handler&lt;status:paid,shipped;tier:premium,enterprise&gt;</text>
  <!-- Condition 1 box -->
  <rect x="20" y="28" width="160" height="50" rx="5" fill="#dbeafe" stroke="#3b82f6" stroke-width="1.5"/>
  <text x="100" y="46" text-anchor="middle" font-family="sans-serif" font-size="9" font-weight="bold" fill="#1e40af">Condition 1 (OR)</text>
  <text x="100" y="62" text-anchor="middle" font-family="monospace" font-size="9" fill="#3b82f6">status = "paid"</text>
  <text x="100" y="74" text-anchor="middle" font-family="monospace" font-size="9" fill="#3b82f6">status = "shipped"</text>
  <!-- AND label -->
  <text x="200" y="58" text-anchor="middle" font-family="sans-serif" font-size="11" font-weight="bold" fill="#6b7280">AND</text>
  <!-- Condition 2 box -->
  <rect x="220" y="28" width="160" height="50" rx="5" fill="#dcfce7" stroke="#22c55e" stroke-width="1.5"/>
  <text x="300" y="46" text-anchor="middle" font-family="sans-serif" font-size="9" font-weight="bold" fill="#166534">Condition 2 (OR)</text>
  <text x="300" y="62" text-anchor="middle" font-family="monospace" font-size="9" fill="#22c55e">tier = "premium"</text>
  <text x="300" y="74" text-anchor="middle" font-family="monospace" font-size="9" fill="#22c55e">tier = "enterprise"</text>
  <!-- Result -->
  <text x="200" y="108" text-anchor="middle" font-family="sans-serif" font-size="9" fill="#6b7280">both conditions must pass → handler executes</text>
</svg>
</div>

---

## 13B.8 Nested Field Access

The field-value guard supports dot notation for accessing nested fields in the event payload:

```aro
(Handle Active Users: UserUpdated Handler<user.status:active>) {
    Extract the <user> from the <event: user>.
    Log "Active user updated" to the <console>.
    Return an <OK: status> for the <handling>.
}

(* Deep nesting *)
(Premium Region Orders: OrderCreated Handler<customer.address.region:premium>) {
    Extract the <order> from the <event: order>.
    Emit a <PremiumRegionOrder: event> with <order>.
    Return an <OK: status> for the <routing>.
}
```

The dot path is resolved by navigating into nested dictionaries step by step. If any component along the path is missing, the guard evaluates to `false` and the handler is skipped.

---

## 13B.9 Guards with the Notify Action

Handler guards are particularly useful with the `Notify` action, which distributes a single notification to every item in a collection. The runtime emits one `NotificationSentEvent` per item in the list, and each delivery is evaluated independently against any guards.

```aro
(Application-Start: Notification Demo) {
    Create the <group> with [
        { name: "Bob",   age: 14 },
        { name: "Carol", age: 25 },
        { name: "Dave",  age: 15 },
        { name: "Eve",   age: 20 }
    ].
    Notify the <group> with "You have a new message.".
    Return an <OK: status> for the <startup>.
}

(* Only fires for users aged 16 or older *)
(Deliver Message: NotificationSent Handler) when <age> >= 16 {
    Extract the <user> from the <event: user>.
    Extract the <name> from the <user: name>.
    Log "Notified: " ++ <name> to the <console>.
    Return an <OK: status> for the <delivery>.
}
```

Result: Carol (25) and Eve (20) are notified. Bob (14) and Dave (15) are silently skipped. The handler body contains no conditional logic — the filtering is entirely declarative.

Without the handler guard, you would need to extract `age` from the user inside the handler and then use a `when` statement to skip work for underage users — but that approach is less clear and executes more code for events that should never have triggered the handler.

---

## 13B.10 Combining Both Guard Types

The two mechanisms can be combined on the same handler. The field-value guard is checked first (before execution starts), and the `when` guard runs as a second evaluation step:

```aro
(* Field-value guard: only OrderUpdated where status = paid or shipped *)
(* when guard: only when amount exceeds 500 *)
(Flag Large Fulfillments: OrderUpdated Handler<status:paid,shipped>) when <amount> > 500 {
    Extract the <order> from the <event: order>.
    Emit a <LargeFulfillment: event> with <order>.
    Return an <OK: status> for the <flagging>.
}
```

This pattern is useful when the field-value guard handles the coarse equality filter (is this even the right status?) and the `when` guard handles a numeric or relational condition that the field-value syntax cannot express.

---

## 13B.11 Declaration Guards vs Statement Guards

ARO has guards in two positions that look similar but serve different purposes:

**Declaration guard** (this chapter): appears on the feature set header, before the `{`:
```aro
(Handler Name: EventType Handler) when <age> >= 18 {
    (* entire body skipped if guard fails *)
}
```

**Statement guard**: appears on a single statement inside the body:
```aro
(Handler Name: EventType Handler) {
    when <age> >= 18 {
        Log "Adult user" to the <console>.
    }
    (* execution continues here regardless *)
}
```

The difference:
- **Declaration guard**: the entire handler does not execute. From the event bus's perspective, the handler was not eligible for this event.
- **Statement guard**: execution enters the handler, that one statement is conditionally skipped, and execution continues to the next statement.

Use a declaration guard when the handler has nothing to do for this event. Use a statement guard when the handler always runs but certain actions within it are conditional.

---

## 13B.12 Choosing Between the Two Guard Types

| Use `when` guard | Use `<field:value>` guard |
|------------------|--------------------------|
| Inequality or range check (`>`, `<`, `>=`, `<=`) | Simple equality check |
| Boolean condition | One of several specific string/number values |
| Condition involving multiple fields with different operators | Field must equal one of a list of values |
| Condition involving arithmetic | Multiple fields must each equal specific values |

When a simple equality filter is all you need, the field-value guard is more concise:

```aro
(* Concise: field-value guard *)
(Handle Shipped: OrderUpdated Handler<status:shipped>) { ... }

(* More verbose: when guard for the same thing *)
(Handle Shipped: OrderUpdated Handler) when <status> = "shipped" { ... }
```

When you need something the field-value syntax cannot express, the `when` guard covers it:

```aro
(* Requires when guard: relational operator *)
(Flag High Value: OrderCreated Handler) when <amount> >= 1000 { ... }

(* Requires when guard: checking against a boolean *)
(Process Verified: UserUpdated Handler) when <verified> = true { ... }
```

---

## 13B.13 Silent Skipping

Both guard types, when they evaluate to false, cause the handler to be silently skipped:

- No error is thrown
- No log message is generated by the runtime
- The handler's return value is not evaluated
- Execution of other handlers for the same event is unaffected

This is intentional. A handler that does not fire for an event is not a failure — it is a routing decision. The event was delivered correctly; this handler was simply not the right recipient for this particular instance.

If you need to observe which handlers fired for debugging purposes, temporary `Log` statements inside handler bodies are more reliable than expecting skipped handlers to produce output.

---

## 13B.14 Complete Example: Order Processing Pipeline

A realistic order system where each stage fires only when the right conditions are met:

```aro
(* Fires when a new order is placed for a premium customer *)
(Priority Queue: OrderCreated Handler<customer.tier:premium>) {
    Extract the <order> from the <event: order>.
    Emit a <PriorityOrder: event> with <order>.
    Return an <OK: status> for the <queueing>.
}

(* Fires when payment is confirmed *)
(Reserve Inventory: OrderUpdated Handler<status:paid>) {
    Extract the <order> from the <event: order>.
    Extract the <items> from the <order: items>.
    Emit a <InventoryReserved: event> with <items>.
    Return an <OK: status> for the <reservation>.
}

(* Fires when the order ships, but only for large orders *)
(Notify Logistics: OrderUpdated Handler<status:shipped>) when <total> > 500 {
    Extract the <order> from the <event: order>.
    Send the <logistics-alert> to the <logistics: email>.
    Return an <OK: status> for the <notification>.
}

(* Fires when delivery is confirmed OR when order is cancelled *)
(Archive Order: OrderUpdated Handler<status:delivered,cancelled>) {
    Extract the <order> from the <event: order>.
    Store the <order> into the <archive-repository>.
    Return an <OK: status> for the <archiving>.
}

(* Fires when both status is refunded AND tier is premium *)
(Issue VIP Refund: OrderUpdated Handler<status:refunded;customer.tier:premium>) {
    Extract the <order> from the <event: order>.
    Emit a <VIPRefund: event> with <order>.
    Return an <OK: status> for the <refund>.
}
```

Each handler is self-describing. The declaration tells you exactly which events trigger it. No conditional logic in the body — every handler does its one job, fully, whenever it fires.

---

## 13B.15 Summary

ARO provides two complementary mechanisms for filtering which events a handler responds to:

1. **`when` guard** — appears between `)` and `{`, supports any comparison operator, ideal for inequalities and numeric ranges.

2. **Field-value guard** (`<field:value>`) — embedded in the business activity string after `Handler`, equality-only but with OR (`,`) and AND (`;`) logic and nested dot-path access.

Both:
- Evaluate before any statements in the handler body execute
- Silently skip the handler when the condition is not met
- Can be combined on the same handler declaration

Using guards on declarations instead of conditionals in bodies makes handlers more focused, more readable, and more efficient — the runtime can skip inappropriate events entirely rather than entering handlers only to exit them early.

---

*Next: Chapter 14 — OpenAPI Integration*
