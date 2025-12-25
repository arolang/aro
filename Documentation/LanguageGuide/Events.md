# Events

ARO is fundamentally event-driven. Feature sets respond to events rather than being called directly. This chapter explains how events work and how to build event-driven applications.

## Event-Driven Architecture

In ARO, feature sets are **triggered by events**, not called directly:

```
┌─────────────────────────────────────────────────────────────┐
│                        Event Bus                            │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  HTTPRequest ───► (listUsers: User API)  [via operationId] │
│                                                             │
│  FileCreated ───► (Process: FileCreated Handler)           │
│                                                             │
│  ClientConnected ─► (Handle: ClientConnected Handler)      │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

## Event Types

### HTTP Events (Contract-First)

ARO uses **contract-first** HTTP development. Routes are defined in `openapi.yaml`, and feature sets are named after `operationId` values:

**openapi.yaml:**
```yaml
openapi: 3.0.3
info:
  title: User API
  version: 1.0.0

paths:
  /users:
    get:
      operationId: listUsers
    post:
      operationId: createUser
  /users/{id}:
    get:
      operationId: getUser
```

**handlers.aro:**
```aro
(* Triggered by GET /users - matches operationId *)
(listUsers: User API) {
    <Retrieve> the <users> from the <repository>.
    <Return> an <OK: status> with <users>.
}

(* Triggered by POST /users *)
(createUser: User API) {
    <Extract> the <data> from the <request: body>.
    <Create> the <user> with <data>.
    <Return> a <Created: status> with <user>.
}

(* Triggered by GET /users/123 *)
(getUser: User API) {
    <Extract> the <id> from the <pathParameters: id>.
    <Retrieve> the <user> from the <repository> where id = <id>.
    <Return> an <OK: status> with <user>.
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

## Handling Events

### Handler Naming

Event handlers include "Handler" in the business activity:

```aro
(Feature Name: EventName Handler)
```

Examples:
```aro
(Index Content: FileCreated Handler) { ... }
(Reload Config: FileModified Handler) { ... }
(Echo Data: DataReceived Handler) { ... }
(Log Connection: ClientConnected Handler) { ... }
```

### Accessing Event Data

Use `<Extract>` to get event data:

```aro
(Process Upload: FileCreated Handler) {
    <Extract> the <path> from the <event: path>.
    <Extract> the <filename> from the <event: filename>.

    <Read> the <content> from the <file: path>.
    <Transform> the <processed> from the <content>.
    <Store> the <processed> into the <processed-repository>.

    <Return> an <OK: status> for the <processing>.
}
```

### Multiple Handlers

Multiple handlers can respond to the same event:

```aro
(* Handler 1: Log the file *)
(Log Upload: FileCreated Handler) {
    <Extract> the <path> from the <event: path>.
    <Log> the <message> for the <console> with "File uploaded: ${path}".
    <Return> an <OK: status> for the <logging>.
}

(* Handler 2: Index the file *)
(Index Upload: FileCreated Handler) {
    <Extract> the <path> from the <event: path>.
    <Read> the <content> from the <file: path>.
    <Store> the <index-entry> into the <search-index>.
    <Return> an <OK: status> for the <indexing>.
}

(* Handler 3: Notify admin *)
(Notify Upload: FileCreated Handler) {
    <Extract> the <path> from the <event: path>.
    <Send> the <notification> to the <admin-channel>.
    <Return> an <OK: status> for the <notification>.
}
```

All handlers execute independently when the event is emitted.

## Built-in Events

### Application Events

| Event | When Triggered |
|-------|----------------|
| `ApplicationStarted` | After Application-Start completes |
| `ApplicationStopping` | Before Application-End runs |

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

## State Transition Events

State transition events are emitted automatically when the `<Accept>` action successfully transitions a state field. These events enable reactive programming around state changes.

### StateObserver Pattern

Feature sets become state observers when their business activity matches the pattern:

```aro
(Feature Name: fieldName StateObserver)                      (* All transitions on field *)
(Feature Name: fieldName StateObserver<from_to_target>)      (* Specific transition only *)
```

The `fieldName` filters which field's transitions to observe. The optional `<from_to_target>` filter restricts to a specific transition.

### Example: Audit Logging (All Transitions)

```aro
(* Observe all status changes *)
(Audit Order Status: status StateObserver) {
    <Extract> the <orderId> from the <transition: entityId>.
    <Extract> the <fromState> from the <transition: fromState>.
    <Extract> the <toState> from the <transition: toState>.

    <Log> the <audit: message> for the <console>
        with "[AUDIT] Order ${orderId}: ${fromState} -> ${toState}".

    <Return> an <OK: status> for the <audit>.
}
```

### Example: Shipping Notification (Specific Transition)

```aro
(* Notify ONLY when order ships (paid -> shipped) *)
(Send Shipping Notice: status StateObserver<paid_to_shipped>) {
    <Extract> the <order> from the <transition: entity>.
    <Extract> the <email> from the <order: customerEmail>.
    <Extract> the <tracking> from the <order: trackingNumber>.

    <Send> the <notification> to the <email> with {
        subject: "Your order has shipped!",
        body: "Track your package: ${tracking}"
    }.

    <Return> an <OK: status> for the <notification>.
}
```

### Transition Data Fields

| Field | Type | Description |
|-------|------|-------------|
| `transition: fieldName` | String | The field that changed (e.g., "status") |
| `transition: objectName` | String | The object type (e.g., "order") |
| `transition: fromState` | String | Previous state value |
| `transition: toState` | String | New state value |
| `transition: entityId` | String? | ID from object's "id" field, if present |
| `transition: entity` | Object | Full object after transition |

### Multiple Observers

Multiple observers can react to the same transition:

```aro
(* Observer 1: Audit all transitions *)
(Log Transitions: status StateObserver) {
    <Log> the <message> for the <console> with "State changed".
    <Return> an <OK: status> for the <logging>.
}

(* Observer 2: Only on draft -> placed *)
(Notify Placed: status StateObserver<draft_to_placed>) {
    <Send> the <webhook> to the <order-service>.
    <Return> an <OK: status> for the <notification>.
}

(* Observer 3: Only on shipped -> delivered *)
(Track Delivery: status StateObserver<shipped_to_delivered>) {
    <Increment> the <delivery-counter> by 1.
    <Return> an <OK: status> for the <analytics>.
}
```

All matching observers execute independently when a transition occurs.

## Long-Running Applications

For applications that need to stay alive to process events (servers, file watchers, etc.), use the `<Keepalive>` action:

```aro
(Application-Start: File Watcher) {
    <Log> the <startup: message> for the <console> with "Starting file watcher...".

    (* Start watching a directory *)
    <Watch> the <directory: "./uploads"> as <file-monitor>.

    (* Keep the application running to process file events *)
    <Keepalive> the <application> for the <events>.

    <Return> an <OK: status> for the <startup>.
}
```

The `<Keepalive>` action:
- Blocks execution until a shutdown signal is received (SIGINT/SIGTERM)
- Allows the event loop to process incoming events
- Enables graceful shutdown with Ctrl+C

## Best Practices

### Keep Handlers Focused

```aro
(* Good - single responsibility *)
(Log File Upload: FileCreated Handler) {
    <Extract> the <path> from the <event: path>.
    <Log> the <message> for the <console> with "Uploaded: ${path}".
    <Return> an <OK: status> for the <logging>.
}

(* Avoid - too many responsibilities *)
(Handle File: FileCreated Handler) {
    (* Don't do logging, indexing, notifications, and analytics in one handler *)
}
```

### Handle Events Idempotently

Events may be delivered multiple times:

```aro
(Process File: FileCreated Handler) {
    <Extract> the <path> from the <event: path>.

    (* Check if already processed *)
    <Retrieve> the <existing> from the <processed-files> where path = <path>.

    if <existing> is not empty then {
        (* Already processed - skip *)
        <Return> an <OK: status> for the <idempotent>.
    }

    (* Process file *)
    <Read> the <content> from the <file: path>.
    <Transform> the <processed> from the <content>.
    <Store> the <processed> into the <processed-files>.
    <Return> an <OK: status> for the <processing>.
}
```

## Next Steps

- [Application Lifecycle](applicationlifecycle.html) - Startup and shutdown events
- [HTTP Services](httpservices.html) - Contract-first HTTP routing
- [File System](filesystem.html) - File system events
