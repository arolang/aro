# ARO-0022: State Guards for Event Handlers

* Proposal: ARO-0022
* Author: ARO Language Team
* Status: **Implemented**
* Requires: ARO-0001, ARO-0007

## Abstract

This proposal defines state guards for event handlers, allowing handlers to filter events based on entity field values. State guards enable declarative event filtering without conditional logic in the handler body.

## Motivation

Event handlers often need to react only to specific states or conditions within an event payload. Without state guards, developers must write conditional logic:

```aro
(* Without state guards - verbose conditional filtering *)
(Process Payment: OrderUpdated Handler) {
    <Extract> the <status> from the <event: status>.
    <Compare> the <status> equals "paid".
    (* Only executes if comparison passes *)
    <Process> the <payment> for the <event: order>.
    <Return> an <OK: status> for the <processing>.
}
```

State guards move this filtering to the handler declaration:

```aro
(* With state guards - declarative filtering *)
(Process Payment: OrderUpdated Handler<status:paid>) {
    <Process> the <payment> for the <event: order>.
    <Return> an <OK: status> for the <processing>.
}
```

---

## 1. Basic Syntax

### 1.1 Single Value Guard

Filter events where a field equals a specific value:

```
(Feature Name: EventType Handler<field:value>)
```

Example:

```aro
(* Only handles events where status is "paid" *)
(Process Payment: OrderUpdated Handler<status:paid>) {
    <Extract> the <order> from the <event: order>.
    <Process> the <payment> for the <order>.
    <Return> an <OK: status> for the <processing>.
}
```

### 1.2 Guard Placement

The guard appears immediately after `Handler` with no space:

```
Handler<guard>     (* Correct *)
Handler <guard>    (* Incorrect - space not allowed *)
```

---

## 2. OR Logic with Comma

Multiple values for the same field use comma separation. The handler executes if the field matches **any** of the values.

### 2.1 Syntax

```
(Feature Name: EventType Handler<field:value1,value2,value3>)
```

### 2.2 Example

```aro
(* Handles events where status is "paid" OR "shipped" *)
(Track Fulfillment: OrderUpdated Handler<status:paid,shipped>) {
    <Extract> the <order> from the <event: order>.
    <Log> "Fulfillment update for order" to the <console>.
    <Return> an <OK: status> for the <tracking>.
}
```

### 2.3 Semantics

- Values are separated by commas without spaces
- Matching uses OR logic: `status == "paid" OR status == "shipped"`
- All values are converted to lowercase for comparison

---

## 3. AND Logic with Semicolon

Multiple conditions use semicolon separation. The handler executes only if **all** conditions match.

### 3.1 Syntax

```
(Feature Name: EventType Handler<field1:value1;field2:value2>)
```

### 3.2 Example

```aro
(* Only handles premium customers with delivered orders *)
(VIP Notification: OrderUpdated Handler<status:delivered;tier:premium>) {
    <Extract> the <order> from the <event: order>.
    <Send> the <vip-reward> to the <order: email>.
    <Return> an <OK: status> for the <notification>.
}
```

### 3.3 Combined OR and AND

Each semicolon-separated guard can have comma-separated values:

```aro
(* status is (paid OR shipped) AND tier is (premium OR enterprise) *)
(Priority Processing: OrderUpdated Handler<status:paid,shipped;tier:premium,enterprise>) {
    <Extract> the <order> from the <event: order>.
    <Prioritize> the <processing> for the <order>.
    <Return> an <OK: status> for the <priority>.
}
```

---

## 4. Nested Field Access

Guards support dot notation for accessing nested fields in the event payload.

### 4.1 Syntax

```
(Feature Name: EventType Handler<parent.child.field:value>)
```

### 4.2 Example

```aro
(* Access nested user.status field *)
(Handle Active Users: UserUpdated Handler<user.status:active>) {
    <Extract> the <user> from the <event: user>.
    <Log> "Active user updated" to the <console>.
    <Return> an <OK: status> for the <handling>.
}

(* Deep nesting *)
(Premium Region: OrderCreated Handler<customer.address.region:premium>) {
    <Extract> the <order> from the <event: order>.
    <Apply> the <premium-shipping> to the <order>.
    <Return> an <OK: status> for the <shipping>.
}
```

### 4.3 Field Resolution

The field path is resolved by traversing the payload dictionary:

1. Split path by `.` separator
2. Navigate into nested dictionaries
3. Return `nil` if any component is missing
4. Compare final value against guard values

---

## 5. Guard Semantics

### 5.1 Evaluation Timing

Guards are evaluated **before** handler execution:

```
Event Received
    ↓
Parse State Guards from Business Activity
    ↓
Extract Payload from Event
    ↓
Evaluate All Guards (AND logic)
    ↓
If ALL match → Execute Handler
If ANY fails → Skip Handler (silent)
```

### 5.2 Case Sensitivity

All comparisons are **case-insensitive**:

```aro
(* All of these match status = "PAID", "Paid", or "paid" *)
(Process: Order Handler<status:paid>) { ... }
(Process: Order Handler<status:PAID>) { ... }
(Process: Order Handler<status:Paid>) { ... }
```

### 5.3 Non-Matching Events

Events that don't match guards are silently skipped:

- No error is thrown
- No log message is generated
- The handler simply doesn't execute

### 5.4 Type Coercion

Non-string field values are converted to strings for comparison:

| Field Type | Conversion |
|------------|------------|
| String | Lowercase directly |
| Number | String representation |
| Boolean | "true" or "false" |
| Other | `String(describing:)` |

---

## 6. Interaction with Other Patterns

### 6.1 State Guards vs State Observers

| Feature | State Guard | State Observer |
|---------|-------------|----------------|
| Syntax | `Handler<field:value>` | `StateObserver<from_to_target>` |
| Purpose | Filter by current value | React to transitions |
| Trigger | Domain events | `<Accept>` action |
| Use Case | "When status IS paid" | "When status CHANGES TO paid" |

### 6.2 Example Comparison

```aro
(* State Guard: Triggers on ANY OrderUpdated where status=shipped *)
(Track Shipment: OrderUpdated Handler<status:shipped>) {
    <Extract> the <order> from the <event: order>.
    <Notify> the <customer> for the <order>.
    <Return> an <OK: status>.
}

(* State Observer: Triggers ONLY when status transitions from paid TO shipped *)
(Log Transition: status StateObserver<paid_to_shipped>) {
    <Extract> the <orderId> from the <transition: entityId>.
    <Log> "Order ${orderId} shipped" to the <console>.
    <Return> an <OK: status>.
}
```

---

## 7. Implementation

### 7.1 StateGuard Structure

```swift
public struct StateGuard: Sendable {
    public let fieldPath: String
    public let validValues: Set<String>

    public func matches(payload: [String: any Sendable]) -> Bool
}
```

### 7.2 StateGuardSet Structure

```swift
public struct StateGuardSet: Sendable {
    public let guards: [StateGuard]

    public static func parse(from businessActivity: String) -> StateGuardSet
    public func allMatch(payload: [String: any Sendable]) -> Bool
}
```

### 7.3 EventBus Integration

The EventBus parses guards from handler business activities and filters events before dispatch:

```swift
// During handler registration
let guardSet = StateGuardSet.parse(from: featureSet.businessActivity)

// During event dispatch
if guardSet.isEmpty || guardSet.allMatch(payload: event.payload) {
    await executeHandler(featureSet, with: event)
}
```

---

## Grammar Extension

```ebnf
(* Handler Business Activity with State Guards *)
handler_activity = event_type , " Handler" , [ state_guard_block ] ;

(* State Guard Block *)
state_guard_block = "<" , state_guard , { ";" , state_guard } , ">" ;

(* Individual State Guard *)
state_guard = field_path , ":" , value_list ;

(* Field Path with Dot Notation *)
field_path = identifier , { "." , identifier } ;

(* Value List with OR Logic *)
value_list = value , { "," , value } ;

(* Value *)
value = identifier | string_literal ;
```

---

## Summary

| Concept | Syntax | Logic |
|---------|--------|-------|
| Single value | `Handler<field:value>` | Exact match |
| Multiple values | `Handler<field:a,b,c>` | OR |
| Multiple conditions | `Handler<f1:v1;f2:v2>` | AND |
| Combined | `Handler<f1:a,b;f2:c,d>` | (a OR b) AND (c OR d) |
| Nested field | `Handler<parent.child:value>` | Dot navigation |

State guards enable declarative, readable event filtering directly in the handler signature.

---

## References

- `Sources/ARORuntime/Events/StateGuard.swift` - Implementation
- ARO-0007: Events and Reactive Systems - Base event handler pattern
