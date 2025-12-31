# ARO-0007: Events and Reactive Systems

* Proposal: ARO-0007
* Author: ARO Language Team
* Status: **Implemented**
* Requires: ARO-0001, ARO-0005

## Abstract

This proposal defines event-driven architecture in ARO, including event emission, event handlers, state objects, repositories, and repository observers. Events enable loose coupling between feature sets while maintaining the simplicity of sequential code.

## Philosophy

Business processes are naturally event-driven:

- **"When an order is placed, send a confirmation email"**
- **"When a payment is received, update the order status"**
- **"When inventory changes, notify the warehouse"**

ARO embraces this natural model. Feature sets emit events; other feature sets react to them. No complex pub/sub infrastructure. No callback hell. Just simple, declarative event handling.

---

## 1. Event Emission

### 1.1 Syntax

Emit an event with data:

```aro
<Emit> a <EventType: event> with <data>.
```

Or emit with an inline object:

```aro
<Emit> a <UserCreated: event> with { email: <email>, name: <name> }.
```

### 1.2 Event Naming Conventions

Event types follow these conventions:

| Pattern | Example | Usage |
|---------|---------|-------|
| `EntityAction` | `UserCreated`, `OrderPlaced` | Entity lifecycle events |
| `ActionCompleted` | `PaymentProcessed`, `EmailSent` | Completion events |
| `ActionFailed` | `PaymentFailed`, `ValidationFailed` | Failure events |

### 1.3 Example

```aro
(createUser: User API) {
    <Extract> the <data> from the <request: body>.
    <Create> the <user> with <data>.
    <Store> the <user> in the <user-repository>.

    (* Emit event - handlers subscribe by event type *)
    <Emit> a <UserCreated: event> with <user>.

    <Return> a <Created: status> with <user>.
}

(updateEmail: User API) {
    <Extract> the <userId> from the <pathParameters: id>.
    <Extract> the <newEmail> from the <request: body>.
    <Retrieve> the <user> from the <user-repository> where id = <userId>.

    <Create> the <oldEmail> with <user: email>.
    <Update> the <user: email> with <newEmail>.
    <Store> the <user> in the <user-repository>.

    (* Emit with inline object *)
    <Emit> a <UserEmailChanged: event> with {
        userId: <userId>,
        oldEmail: <oldEmail>,
        newEmail: <newEmail>
    }.

    <Return> an <OK: status> with <user>.
}
```

---

## 2. Event Handlers

### 2.1 Handler Pattern

Feature sets receive events using the `Handler` business activity pattern:

```
(Feature Name: EventType Handler)
```

The handler receives event data in the `<event>` variable:

```aro
(Send Welcome Email: UserCreated Handler) {
    <Extract> the <user> from the <event: user>.
    <Extract> the <email> from the <user: email>.
    <Extract> the <name> from the <user: name>.

    <Send> the <welcome-email> to the <email> with {
        subject: "Welcome!",
        body: "Hello ${<name>}, welcome to our service!"
    }.

    <Return> an <OK: status> for the <notification>.
}
```

### 2.2 Multiple Handlers

Multiple handlers can subscribe to the same event type:

```aro
(* All three handlers execute when OrderCreated is emitted *)

(Send Order Confirmation: OrderCreated Handler) {
    <Extract> the <order> from the <event: order>.
    <Send> the <email> to the <order: email>.
    <Return> an <OK: status> for the <confirmation>.
}

(Update Inventory: OrderCreated Handler) {
    <Extract> the <order> from the <event: order>.
    <Extract> the <items> from the <order: items>.
    for each <item> in <items> {
        <Decrement> the <stock> for the <item: productId> with <item: quantity>.
    }
    <Return> an <OK: status> for the <inventory>.
}

(Track Revenue: OrderCreated Handler) {
    <Extract> the <order> from the <event: order>.
    <Extract> the <amount> from the <order: total>.
    <Increment> the <daily-revenue> by <amount>.
    <Return> an <OK: status> for the <analytics>.
}
```

### 2.3 Event Context Variables

Inside a handler, the `<event>` variable provides access to event data:

| Variable | Description |
|----------|-------------|
| `<event>` | The full event object |
| `<event: fieldName>` | Access specific field from event payload |

---

## 3. State-Guarded Handlers

Event handlers can filter events based on payload field values. Guards are specified using angle bracket syntax after "Handler".

### 3.1 Basic Guard Syntax

```aro
(* Only handle OrderUpdated when status is "paid" *)
(Process Payment: OrderUpdated Handler<status:paid>) {
    <Extract> the <order> from the <event: order>.
    <Process> the <payment> for the <order>.
    <Return> an <OK: status> for the <processing>.
}
```

### 3.2 OR Logic with Comma

Multiple values for the same field are separated by commas:

```aro
(* Handle when status is paid OR shipped *)
(Track Fulfillment: OrderUpdated Handler<status:paid,shipped>) {
    <Extract> the <order> from the <event: order>.
    <Log> "Fulfillment update" to the <console>.
    <Return> an <OK: status> for the <tracking>.
}
```

### 3.3 AND Logic with Semicolon

Multiple conditions use semicolon for AND logic:

```aro
(* Only handle premium customers with delivered orders *)
(VIP Notification: OrderUpdated Handler<status:delivered;tier:premium>) {
    <Extract> the <order> from the <event: order>.
    <Send> the <vip-reward> to the <order: email>.
    <Return> an <OK: status> for the <notification>.
}
```

### 3.4 Nested Field Access

Use dot notation for nested fields:

```aro
(* Access nested user.status field *)
(Handle Active Users: UserUpdated Handler<user.status:active>) {
    <Extract> the <user> from the <event: user>.
    <Return> an <OK: status> for the <handling>.
}
```

### 3.5 Guard Semantics

- Guards are evaluated **before** handler execution
- All guards must match for the handler to execute (AND logic across guards)
- Field values are compared case-insensitively
- Non-matching events are silently skipped

---

## 4. State Objects

Many business processes are naturally state machines:

- **Order Lifecycle**: draft -> placed -> paid -> shipped -> delivered
- **User Onboarding**: registered -> verified -> active
- **Approval Workflows**: pending -> approved/rejected

ARO handles state transitions using OpenAPI enums and the `<Accept>` action.

### 4.1 Defining States in OpenAPI

States are defined as string enums in `openapi.yaml`:

```yaml
# openapi.yaml
openapi: 3.0.3
info:
  title: Order API
  version: 1.0.0

components:
  schemas:
    OrderStatus:
      type: string
      enum:
        - draft
        - placed
        - paid
        - shipped
        - delivered
        - cancelled

    Order:
      type: object
      properties:
        id:
          type: string
        status:
          $ref: '#/components/schemas/OrderStatus'
        customerId:
          type: string
      required:
        - id
        - status
```

### 4.2 The Accept Action

Syntax:

```aro
<Accept> the <transition: from_to_target> on <object: field>.
```

Where:
- `from` is the expected current state
- `target` is the target state
- `_to_` is the separator between states
- `object: field` is the field being transitioned

Examples:

```aro
(* Transition from draft to placed *)
<Accept> the <transition: draft_to_placed> on <order: status>.

(* Transition from placed to paid *)
<Accept> the <transition: placed_to_paid> on <order: status>.

(* Transition from paid to shipped *)
<Accept> the <transition: paid_to_shipped> on <order: status>.
```

### 4.3 Error Handling

If the current state doesn't match the expected `from` state:

```
Cannot accept state draft->placed on order: status. Current state is "paid".
```

This follows ARO's "Code Is The Error Message" philosophy.

### 4.4 Complete State Example

```aro
(placeOrder: Order Management) {
    <Extract> the <order-id> from the <pathParameters: id>.
    <Retrieve> the <order> from the <order-repository>.

    (* Accept state transition from draft to placed *)
    <Accept> the <transition: draft_to_placed> on <order: status>.

    <Store> the <order> into the <order-repository>.
    <Emit> an <OrderPlaced: event> with <order>.
    <Return> an <OK: status> with <order>.
}

(payOrder: Order Management) {
    <Extract> the <order-id> from the <pathParameters: id>.
    <Retrieve> the <order> from the <order-repository>.

    (* Must be placed to accept payment *)
    <Accept> the <transition: placed_to_paid> on <order: status>.

    <Store> the <order> into the <order-repository>.
    <Emit> an <OrderPaid: event> with <order>.
    <Return> an <OK: status> with <order>.
}

(shipOrder: Order Management) {
    <Extract> the <order-id> from the <pathParameters: id>.
    <Retrieve> the <order> from the <order-repository>.

    (* Must be paid to ship *)
    <Accept> the <transition: paid_to_shipped> on <order: status>.

    <Store> the <order> into the <order-repository>.
    <Emit> an <OrderShipped: event> with <order>.
    <Return> an <OK: status> with <order>.
}
```

### 4.5 State Observers

State observers react to state transitions after they occur:

```
(Feature Name: fieldName StateObserver)                       (* All transitions *)
(Feature Name: fieldName StateObserver<from_to_target>)       (* Specific transition *)
```

Examples:

```aro
(* Observe ALL status field transitions *)
(Audit Status Changes: status StateObserver) {
    <Extract> the <fromState> from the <transition: fromState>.
    <Extract> the <toState> from the <transition: toState>.
    <Extract> the <orderId> from the <transition: entityId>.
    <Log> "Order ${orderId}: ${fromState} -> ${toState}" to the <console>.
    <Return> an <OK: status> for the <audit>.
}

(* Observe ONLY draft->placed transition *)
(Notify Order Placed: status StateObserver<draft_to_placed>) {
    <Extract> the <orderId> from the <transition: entityId>.
    <Log> "Order ${orderId} has been placed!" to the <console>.
    <Return> an <OK: status> for the <notification>.
}
```

Transition data available to observers:

| Field | Description |
|-------|-------------|
| `transition: fieldName` | Field that transitioned (e.g., "status") |
| `transition: objectName` | Object containing the field (e.g., "order") |
| `transition: fromState` | State before transition |
| `transition: toState` | State after transition |
| `transition: entityId` | Entity ID if available |
| `transition: entity` | Full object after transition |

---

## 5. Repositories

Repositories provide persistent storage that survives across feature set executions within the same business activity.

### 5.1 Repository Definition

A **repository** is a named storage container that:

- Persists for the lifetime of the application
- Is scoped to a **business activity** by default
- Is identified by names ending with `-repository`

### 5.2 Naming Convention

Repository names MUST end with `-repository`:

```aro
<message-repository>      (* Valid repository *)
<user-repository>         (* Valid repository *)
<order-repository>        (* Valid repository *)
<messages>                (* NOT a repository - regular variable *)
```

### 5.3 Business Activity Scoping

Repositories are scoped to their business activity:

```
+-------------------------------------------------------------+
|                    Application Scope                         |
|  (Exported repositories available to all activities)         |
|                                                              |
|  +-------------------------------------------------------+  |
|  |              Business Activity: "Chat API"             |  |
|  |                                                        |  |
|  |   <message-repository>  <user-repository>              |  |
|  |                                                        |  |
|  |   Accessible by: postMessage, getMessages              |  |
|  +-------------------------------------------------------+  |
|                                                              |
|  +-------------------------------------------------------+  |
|  |              Business Activity: "Order API"            |  |
|  |                                                        |  |
|  |   <order-repository>  <inventory-repository>           |  |
|  |                                                        |  |
|  |   Accessible by: createOrder, getOrders                |  |
|  +-------------------------------------------------------+  |
|                                                              |
+-------------------------------------------------------------+
```

### 5.4 Store Operation

The `<Store>` action persists data to a repository:

```aro
<Store> the <data> into the <name-repository>.
```

Behavior:
- If the repository doesn't exist, it's created
- Data is appended to the repository (list semantics)

Syntax variations:
```aro
<Store> the <user> into the <user-repository>.
<Store> the <message> in the <message-repository>.
<Store> the <order> to the <order-repository>.
```

### 5.5 Retrieve Operation

The `<Retrieve>` action fetches data from a repository:

```aro
<Retrieve> the <items> from the <name-repository>.
```

Behavior:
- Returns all items stored in the repository
- Returns an empty list if the repository is empty or doesn't exist
- Never throws an error for missing repositories

Filtering:
```aro
<Retrieve> the <user> from the <user-repository> where id = <user-id>.
```

Single-value retrieval:
```aro
(* Last stored value *)
<Retrieve> the <latest> from the <user-repository: last>.

(* First stored value *)
<Retrieve> the <oldest> from the <user-repository: first>.

(* By numeric index - 0 = most recent *)
<Retrieve> the <newest> from the <user-repository: 0>.
```

### 5.6 Repository Example

```aro
(* POST /messages - Store a new message *)
(postMessage: Chat API) {
    <Extract> the <data> from the <request: body>.
    <Extract> the <text> from the <data: message>.
    <Extract> the <author> from the <data: author>.

    <Create> the <message> with {
        id: <generated-id>,
        text: <text>,
        author: <author>,
        timestamp: now
    }.

    <Store> the <message> into the <message-repository>.

    <Return> a <Created: status> with <message>.
}

(* GET /messages - Retrieve all messages *)
(getMessages: Chat API) {
    <Retrieve> the <messages> from the <message-repository>.
    <Return> an <OK: status> with { messages: <messages> }.
}

(* GET /messages/{id} - Retrieve single message *)
(getMessage: Chat API) {
    <Extract> the <id> from the <pathParameters: id>.
    <Retrieve> the <message> from the <message-repository> where id = <id>.
    <Return> an <OK: status> with <message>.
}
```

---

## 6. Repository Observers

Repository observers allow feature sets to react automatically to repository changes.

### 6.1 Observer Pattern

Observers are feature sets with business activity pattern `{repository-name} Observer`:

```aro
(Audit Changes: user-repository Observer) {
    <Extract> the <changeType> from the <event: changeType>.
    <Extract> the <newValue> from the <event: newValue>.
    <Extract> the <oldValue> from the <event: oldValue>.

    <Log> "User repository: ${changeType}" to the <console>.
    <Return> an <OK: status> for the <audit>.
}
```

### 6.2 Event Payload

When a repository changes, observers receive:

| Field | Type | Description |
|-------|------|-------------|
| `repositoryName` | String | e.g., "user-repository" |
| `changeType` | String | "created", "updated", or "deleted" |
| `entityId` | String? | ID of changed entity (if available) |
| `newValue` | Any? | New value (nil for deletes) |
| `oldValue` | Any? | Previous value (nil for creates) |
| `timestamp` | Date | When the change occurred |

### 6.3 Change Types

Observers are triggered for:

- **created**: New item stored in repository
- **updated**: Existing item modified (matched by id)
- **deleted**: Item removed from repository

```aro
(Handle User Updates: user-repository Observer) {
    <Extract> the <changeType> from the <event: changeType>.

    (* Only process updates *)
    <Compare> the <changeType> equals "updated".

    <Extract> the <oldName> from the <event: oldValue: name>.
    <Extract> the <newName> from the <event: newValue: name>.

    <Log> "User renamed from ${oldName} to ${newName}" to the <console>.

    <Return> an <OK: status> for the <update>.
}
```

### 6.4 Delete Operation

To delete items and trigger observers:

```aro
<Delete> the <user> from the <user-repository> where id = <userId>.
```

### 6.5 Observer Flow

```
+-------------------------------------------------------------+
|                  Feature Set Execution                       |
+-------------------------------------------------------------+
|                                                              |
|   <Store> the <user> into the <user-repository>.            |
|                    |                                         |
|                    v                                         |
|   +--------------------------------------------+            |
|   |   RepositoryStorage                         |            |
|   |   - Captures old value (if update)          |            |
|   |   - Stores new value                        |            |
|   +--------------------------------------------+            |
|                    |                                         |
|                    v                                         |
|   +--------------------------------------------+            |
|   |   Emit RepositoryChangedEvent               |            |
|   |   - changeType: created | updated           |            |
|   |   - newValue: stored data                   |            |
|   |   - oldValue: previous data (if any)        |            |
|   +--------------------------------------------+            |
|                    |                                         |
|                    v                                         |
|   +--------------------------------------------+            |
|   |          EventBus                           |            |
|   |   - Routes to matching observers            |            |
|   +--------------------------------------------+            |
|                    |                                         |
|        +-----------+-----------+                             |
|        v                       v                             |
|   +--------------+       +--------------+                    |
|   | Audit Changes|       | Send Email   |                    |
|   |   Observer   |       |   Observer   |                    |
|   +--------------+       +--------------+                    |
|                                                              |
+-------------------------------------------------------------+
```

---

## 7. EventBus Architecture

The EventBus is the central hub for event routing in ARO applications.

### 7.1 Event Flow

```
+-------------------------------------------------------------+
|                      EventBus                                |
+-------------------------------------------------------------+
|                                                              |
|  Event Sources:                                              |
|  +-------------+  +-------------+  +-------------+           |
|  | HTTP Routes |  | File Events |  | Socket Data |           |
|  +------+------+  +------+------+  +------+------+           |
|         |                |                |                  |
|         +-------+--------+--------+-------+                  |
|                 |                                            |
|                 v                                            |
|  +------------------------------------------+               |
|  |           Event Router                    |               |
|  |                                           |               |
|  |  Match event to registered handlers:      |               |
|  |  - HTTP operationId -> Feature Set        |               |
|  |  - EventType -> Handler pattern           |               |
|  |  - Repository -> Observer pattern         |               |
|  |  - State change -> StateObserver          |               |
|  +------------------------------------------+               |
|                 |                                            |
|     +-----------+-----------+-----------+                    |
|     v           v           v           v                    |
|  +------+   +------+   +------+   +------+                  |
|  | FS 1 |   | FS 2 |   | FS 3 |   | FS N |                  |
|  +------+   +------+   +------+   +------+                  |
|                                                              |
|  Feature sets execute concurrently                           |
|                                                              |
+-------------------------------------------------------------+
```

### 7.2 Event Matching Rules

| Event Type | Pattern | Example |
|------------|---------|---------|
| HTTP Request | `operationId` from OpenAPI | `(listUsers: User API)` |
| Domain Event | `{EventType} Handler` | `(Send Email: UserCreated Handler)` |
| Guarded Event | `{EventType} Handler<field:value>` | `(Process: Order Handler<status:paid>)` |
| Repository Change | `{repository-name} Observer` | `(Audit: user-repository Observer)` |
| State Transition | `{field} StateObserver` | `(Log: status StateObserver)` |
| Specific Transition | `{field} StateObserver<from_to_target>` | `(Log: status StateObserver<draft_to_placed>)` |

### 7.3 Execution Semantics

- Events are dispatched asynchronously
- Multiple handlers can respond to the same event
- Handlers run in isolation; failures don't affect other handlers
- Handler execution order is undefined
- The emitting feature set continues immediately (fire-and-forget)

---

## 8. Handler Guard vs State Observer

ARO provides two complementary mechanisms for reacting to state:

| Pattern | Syntax | Trigger |
|---------|--------|---------|
| Handler Guard | `EventName Handler<field:value>` | Domain events with matching payload |
| State Observer | `fieldName StateObserver<from_to_target>` | State transitions via Accept action |

### When to Use Each

**Use Handler Guard** when filtering events by current state:

```aro
(* Triggers for any OrderUpdated where status=shipped *)
(Notify Shipped: OrderUpdated Handler<status:shipped>) {
    <Extract> the <order> from the <event: order>.
    <Send> the <notification> to the <order: email>.
    <Return> an <OK: status>.
}
```

**Use State Observer** when reacting to a specific transition:

```aro
(* Triggers only when status transitions from paid to shipped *)
(Track Shipment: status StateObserver<paid_to_shipped>) {
    <Extract> the <orderId> from the <transition: entityId>.
    <Log> "Order shipped: ${orderId}" to the <console>.
    <Return> an <OK: status>.
}
```

---

## Grammar Extension

```ebnf
(* Event Emission *)
emit_statement = "<Emit>" , article , "<" , event_type , ":" , "event" , ">" ,
                 "with" , ( variable | inline_object ) , "." ;

event_type = identifier ;

(* Event Handler Business Activity *)
handler_activity = event_type , " Handler" , [ state_guard_block ] ;

(* State Guard *)
state_guard_block = "<" , state_guard , { ";" , state_guard } , ">" ;
state_guard = field_path , ":" , value_list ;
field_path = identifier , { "." , identifier } ;
value_list = identifier , { "," , identifier } ;

(* Accept Action *)
accept_statement = "<Accept>" , "the" , "<" , transition_spec , ">" ,
                   "on" , "<" , qualified_noun , ">" , "." ;

transition_spec = "transition" , ":" , state_transition ;
state_transition = identifier , "_to_" , identifier ;

(* State Observer Business Activity *)
state_observer_activity = [ field_name , " " ] , "StateObserver" ,
                          [ "<" , state_transition , ">" ] ;

(* Repository Observer Business Activity *)
repository_observer_activity = repository_name , " Observer" ;
repository_name = identifier , "-repository" ;
```

---

## Summary

| Concept | ARO Approach |
|---------|--------------|
| **Event Emission** | `<Emit> a <EventType: event> with <data>.` |
| **Event Handler** | `(Name: EventType Handler)` |
| **Guarded Handler** | `(Name: EventType Handler<field:value>)` |
| **State Definition** | OpenAPI enum |
| **State Transition** | `<Accept> the <transition: from_to_target>` |
| **State Observer** | `(Name: fieldName StateObserver<transition>)` |
| **Repository** | Names ending with `-repository` |
| **Store** | `<Store> the <data> into <repo-repository>.` |
| **Retrieve** | `<Retrieve> the <items> from <repo-repository>.` |
| **Repository Observer** | `(Name: repo-repository Observer)` |
| **Event Routing** | EventBus matches patterns to feature sets |

Write sequential event handlers. Get concurrent execution. No callbacks, no promises, no message queues.
