# Events

ARO is fundamentally event-driven. Feature sets respond to events rather than being called directly. This chapter explains how events work and how to build event-driven applications.

## Event-Driven Architecture

In ARO, feature sets are **triggered by events**, not called directly:

```
┌─────────────────────────────────────────────────────┐
│                   Event Bus                         │
├─────────────────────────────────────────────────────┤
│                                                     │
│  HTTPRequest ───► (GET /users: Handler)             │
│                                                     │
│  UserCreated ───► (Send Email: UserCreated Handler) │
│              ───► (Log Activity: UserCreated Handler)│
│                                                     │
│  FileCreated ───► (Process: FileCreated Handler)    │
│                                                     │
└─────────────────────────────────────────────────────┘
```

## Event Types

### HTTP Events

HTTP requests trigger route-based feature sets:

```aro
(* Triggered by GET /users *)
(GET /users: User API) {
    <Retrieve> the <users> from the <repository>.
    <Return> an <OK: status> with <users>.
}

(* Triggered by POST /users *)
(POST /users: User API) {
    <Extract> the <data> from the <request: body>.
    <Create> the <user> with <data>.
    <Return> a <Created: status> with <user>.
}

(* Triggered by GET /users/123 *)
(GET /users/{id}: User API) {
    <Extract> the <id> from the <request: parameters>.
    <Retrieve> the <user> from the <repository> where id = <id>.
    <Return> an <OK: status> with <user>.
}
```

### Domain Events

Custom events emitted by your application:

```aro
(* Emitting a domain event *)
(POST /orders: Order API) {
    <Create> the <order> with <order-data>.
    <Store> the <order> into the <repository>.

    (* Emit event for other handlers *)
    <Emit> an <OrderPlaced: event> with <order>.

    <Return> a <Created: status> with <order>.
}

(* Handling the domain event *)
(Send Confirmation: OrderPlaced Handler) {
    <Extract> the <order> from the <event: order>.
    <Send> the <email> to the <order: customerEmail>.
    <Return> an <OK: status> for the <notification>.
}
```

### File System Events

Triggered by file system changes:

```aro
(* File created *)
(Process New File: FileCreated Handler) {
    <Extract> the <path> from the <event: path>.
    <Read> the <content> from the <file: path>.
    <Process> the <result> from the <content>.
    <Return> an <OK: status> for the <processing>.
}

(* File modified *)
(Reload Config: FileModified Handler) {
    <Extract> the <path> from the <event: path>.
    if <path> is "./config.json" then {
        <Read> the <config> from the <file: path>.
        <Publish> as <app-config> <config>.
    }
    <Return> an <OK: status> for the <reload>.
}

(* File deleted *)
(Log Deletion: FileDeleted Handler) {
    <Extract> the <path> from the <event: path>.
    <Log> the <message> for the <console> with "File deleted: ${path}".
    <Return> an <OK: status> for the <logging>.
}
```

### Socket Events

Triggered by TCP connections:

```aro
(* Client connected *)
(Handle Connection: ClientConnected Handler) {
    <Extract> the <client-id> from the <event: connectionId>.
    <Extract> the <address> from the <event: remoteAddress>.
    <Log> the <message> for the <console> with "Client connected: ${address}".
    <Return> an <OK: status> for the <connection>.
}

(* Data received *)
(Process Data: DataReceived Handler) {
    <Extract> the <data> from the <event: data>.
    <Extract> the <connection> from the <event: connection>.
    <Process> the <response> from the <data>.
    <Send> the <response> to the <connection>.
    <Return> an <OK: status> for the <processing>.
}

(* Client disconnected *)
(Handle Disconnect: ClientDisconnected Handler) {
    <Extract> the <client-id> from the <event: connectionId>.
    <Log> the <message> for the <console> with "Client disconnected: ${client-id}".
    <Return> an <OK: status> for the <cleanup>.
}
```

## Emitting Events

Use `<Emit>` to publish domain events:

```aro
<Emit> a <EventName: event> with <data>.
<Emit> an <OrderPlaced: event> with <order>.
<Emit> a <UserRegistered: event> with <user>.
<Emit> a <PaymentProcessed: event> with <payment>.
```

### Event Naming

Events are named with a descriptive past-tense name:

| Event Name | Meaning |
|------------|---------|
| `UserCreated` | A user was created |
| `OrderPlaced` | An order was placed |
| `PaymentProcessed` | A payment was processed |
| `EmailSent` | An email was sent |
| `FileUploaded` | A file was uploaded |

### Event Data

Include relevant data with the event:

```aro
(* Include the full entity *)
<Emit> an <OrderPlaced: event> with <order>.

(* Include specific fields *)
<Emit> a <UserCreated: event> with {
    userId: <user: id>,
    email: <user: email>,
    timestamp: <current-time>
}.
```

## Handling Events

### Handler Naming

Event handlers include "Handler" in the business activity:

```aro
(Feature Name: EventName Handler)
```

Examples:
```aro
(Send Welcome Email: UserCreated Handler) { ... }
(Update Inventory: OrderPlaced Handler) { ... }
(Generate Invoice: PaymentProcessed Handler) { ... }
(Index Content: FileCreated Handler) { ... }
```

### Accessing Event Data

Use `<Extract>` to get event data:

```aro
(Notify Admin: OrderPlaced Handler) {
    <Extract> the <order> from the <event: order>.
    <Extract> the <order-id> from the <order: id>.
    <Extract> the <total> from the <order: total>.

    <Create> the <notification> with {
        message: "New order #${order-id} for $${total}"
    }.
    <Send> the <notification> to the <admin-channel>.
    <Return> an <OK: status> for the <notification>.
}
```

### Multiple Handlers

Multiple handlers can respond to the same event:

```aro
(* Handler 1: Send confirmation *)
(Send Confirmation: OrderPlaced Handler) {
    <Extract> the <order> from the <event: order>.
    <Send> the <confirmation-email> to the <order: customerEmail>.
    <Return> an <OK: status> for the <email>.
}

(* Handler 2: Update inventory *)
(Update Stock: OrderPlaced Handler) {
    <Extract> the <order> from the <event: order>.
    <Extract> the <items> from the <order: lineItems>.
    (* Update stock for each item *)
    <Update> the <inventory> for the <items>.
    <Return> an <OK: status> for the <inventory>.
}

(* Handler 3: Notify warehouse *)
(Notify Warehouse: OrderPlaced Handler) {
    <Extract> the <order> from the <event: order>.
    <Send> the <picking-list> to the <warehouse-system>.
    <Return> an <OK: status> for the <notification>.
}
```

All handlers execute independently when the event is emitted.

## Event Flow Patterns

### Saga Pattern

Chain of events for complex workflows:

```aro
(* Step 1: Place order *)
(POST /orders: Order API) {
    <Create> the <order> with <order-data>.
    <Store> the <order> into the <repository>.
    <Emit> an <OrderPlaced: event> with <order>.
    <Return> a <Created: status> with <order>.
}

(* Step 2: Reserve inventory *)
(Reserve Inventory: OrderPlaced Handler) {
    <Extract> the <order> from the <event: order>.
    <Reserve> the <stock> for the <order: items>.

    if <reservation: success> then {
        <Emit> an <InventoryReserved: event> with <order>.
    } else {
        <Emit> an <InventoryFailed: event> with <order>.
    }

    <Return> an <OK: status> for the <reservation>.
}

(* Step 3a: Process payment (on success) *)
(Process Payment: InventoryReserved Handler) {
    <Extract> the <order> from the <event: order>.
    <Charge> the <payment> for the <order>.

    if <payment: success> then {
        <Emit> a <PaymentSucceeded: event> with <order>.
    } else {
        <Emit> a <PaymentFailed: event> with <order>.
    }

    <Return> an <OK: status> for the <payment>.
}

(* Step 3b: Cancel order (on failure) *)
(Cancel Order: InventoryFailed Handler) {
    <Extract> the <order> from the <event: order>.
    <Transform> the <cancelled> from the <order> with { status: "cancelled" }.
    <Store> the <cancelled> into the <repository>.
    <Emit> an <OrderCancelled: event> with <cancelled>.
    <Return> an <OK: status> for the <cancellation>.
}
```

### Fan-Out Pattern

One event triggers multiple independent handlers:

```aro
(* Source: User registration *)
(POST /register: Auth API) {
    <Create> the <user> with <registration-data>.
    <Store> the <user> into the <repository>.
    <Emit> a <UserRegistered: event> with <user>.
    <Return> a <Created: status> with <user>.
}

(* Fan-out: Multiple handlers *)
(Send Welcome Email: UserRegistered Handler) { ... }
(Create Profile: UserRegistered Handler) { ... }
(Track Analytics: UserRegistered Handler) { ... }
(Notify Sales: UserRegistered Handler) { ... }
```

### Event Sourcing Pattern

Store events as the source of truth:

```aro
(POST /accounts/{id}/deposit: Account API) {
    <Extract> the <account-id> from the <request: parameters>.
    <Extract> the <amount> from the <request: body amount>.

    <Create> the <event> with {
        type: "Deposited",
        accountId: <account-id>,
        amount: <amount>,
        timestamp: <current-time>
    }.

    (* Store the event *)
    <Store> the <event> into the <event-store>.

    (* Emit for projections *)
    <Emit> a <Deposited: event> with <event>.

    <Return> an <OK: status> with <event>.
}

(* Projection: Update balance *)
(Update Balance: Deposited Handler) {
    <Extract> the <account-id> from the <event: accountId>.
    <Extract> the <amount> from the <event: amount>.
    <Retrieve> the <account> from the <account-repository> where id = <account-id>.
    <Compute> the <new-balance> from <account: balance> + <amount>.
    <Transform> the <updated> from the <account> with { balance: <new-balance> }.
    <Store> the <updated> into the <account-repository>.
    <Return> an <OK: status> for the <projection>.
}
```

## Built-in Events

### Application Events

| Event | When Triggered |
|-------|----------------|
| `ApplicationStarted` | After Application-Start completes |
| `ApplicationStopping` | Before Application-End runs |

### HTTP Events

| Event | When Triggered |
|-------|----------------|
| `HTTPRequestReceived` | HTTP request arrives |
| `HTTPResponseSent` | HTTP response sent |

### File Events

| Event | When Triggered |
|-------|----------------|
| `FileCreated` | File created in watched directory |
| `FileModified` | File modified in watched directory |
| `FileDeleted` | File deleted in watched directory |
| `FileRenamed` | File renamed in watched directory |

### Socket Events

| Event | When Triggered |
|-------|----------------|
| `ClientConnected` | TCP client connects |
| `DataReceived` | Data received from client |
| `ClientDisconnected` | TCP client disconnects |

## Best Practices

### Name Events Clearly

```aro
(* Good - past tense, specific *)
<Emit> an <OrderPlaced: event> with <order>.
<Emit> a <PaymentFailed: event> with <payment>.
<Emit> a <UserEmailVerified: event> with <user>.

(* Avoid - vague, present tense *)
<Emit> an <Order: event> with <order>.
<Emit> a <Process: event> with <data>.
```

### Include Sufficient Data

```aro
(* Good - enough context *)
<Emit> an <OrderShipped: event> with {
    orderId: <order: id>,
    customerId: <order: customerId>,
    trackingNumber: <shipment: trackingNumber>,
    carrier: <shipment: carrier>,
    estimatedDelivery: <shipment: estimatedDelivery>
}.

(* Avoid - too little context *)
<Emit> an <OrderShipped: event> with <order-id>.
```

### Handle Events Idempotently

Events may be delivered multiple times:

```aro
(Process Payment: OrderPlaced Handler) {
    <Extract> the <order> from the <event: order>.
    <Extract> the <order-id> from the <order: id>.

    (* Check if already processed *)
    <Retrieve> the <existing> from the <payment-repository> where orderId = <order-id>.

    if <existing> is not empty then {
        (* Already processed - skip *)
        <Return> an <OK: status> for the <idempotent>.
    }

    (* Process payment *)
    <Charge> the <payment> for the <order>.
    <Store> the <payment> into the <payment-repository>.
    <Return> an <OK: status> for the <payment>.
}
```

### Keep Handlers Focused

```aro
(* Good - single responsibility *)
(Send Confirmation Email: OrderPlaced Handler) {
    <Extract> the <order> from the <event: order>.
    <Send> the <confirmation> to the <order: customerEmail>.
    <Return> an <OK: status> for the <email>.
}

(* Avoid - too many responsibilities *)
(Handle Order: OrderPlaced Handler) {
    (* Don't do email, inventory, analytics, and notifications in one handler *)
}
```

## Next Steps

- [Application Lifecycle](ApplicationLifecycle.md) - Startup and shutdown events
- [HTTP Services](HTTPServices.md) - HTTP request events
- [File System](FileSystem.md) - File system events
