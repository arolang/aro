# Chapter 29: Concurrency

ARO's concurrency model is radically simple: **feature sets are async, statements are sync**. This chapter explains how ARO handles concurrent operations without requiring you to think about threads, locks, or async/await.

## The Philosophy

ARO's concurrency model matches how project managers think:

- **"When X happens, do Y"** - Feature sets are triggered by events
- **"Do this, then this, then this"** - Steps happen in order

You don't think about threads, locks, race conditions, or async/await. You think about things happening and responding to them in sequence.

## Feature Sets Are Async

Every feature set runs asynchronously when triggered by an event:

```
+-----------------------------------------------------+
|                    Event Bus                         |
|                                                      |
|  HTTP Request --+---> (listUsers: User API)          |
|                 |                                    |
|  Socket Data ---+---> (Handle Data: Socket Handler)  |
|                 |                                    |
|  File Changed --+---> (Process File: File Handler)   |
|                 |                                    |
|  UserCreated ---+---> (Send Email: Notification)     |
|                                                      |
|  (Multiple events trigger multiple feature sets     |
|   running concurrently)                              |
+-----------------------------------------------------+
```

When multiple events arrive, multiple feature sets execute simultaneously. 100 HTTP requests = 100 concurrent feature set executions.

## Statements Are Sync

Inside a feature set, statements execute **synchronously** and **serially**:

```aro
(Process Order: Order API) {
    <Extract> the <data> from the <request: body>.      (* 1. First *)
    <Validate> the <data> for the <order-schema>.       (* 2. Second *)
    <Create> the <order> with <data>.                   (* 3. Third *)
    <Store> the <order> in the <order-repository>.      (* 4. Fourth *)
    <Emit> to <Send Confirmation> with <order>.         (* 5. Fifth *)
    <Return> a <Created: status> with <order>.          (* 6. Last *)
}
```

Each statement completes before the next one starts. No callbacks. No promises. No async/await syntax. Just sequential execution.

## Why This Model?

### Simplicity

Traditional async code in JavaScript:

```javascript
async function processOrder(req) {
    const data = await extractData(req);
    const validated = await validate(data);
    const order = await createOrder(validated);
    await storeOrder(order);
    await emitEvent('OrderCreated', order);
    return { status: 201, body: order };
}
```

ARO code:

```aro
(Process Order: Order API) {
    <Extract> the <data> from the <request: body>.
    <Validate> the <data> for the <order-schema>.
    <Create> the <order> with <data>.
    <Store> the <order> in the <order-repository>.
    <Emit> to <Send Confirmation> with <order>.
    <Return> a <Created: status> with <order>.
}
```

No `async`. No `await`. Just statements in order.

### No Race Conditions

Within a feature set, there's no shared mutable state problem:

- Variables are scoped to the feature set
- Statements execute serially
- No concurrent access to the same data

### Natural Event Flow

Events naturally express concurrency:

- User A requests an order while User B requests their profile
- Both feature sets run concurrently
- Each processes their own data independently

## Runtime Optimization

While you write synchronous-looking code, the ARO runtime executes operations **asynchronously** based on data dependencies. This is transparent to you.

### How It Works

The runtime performs **data-flow driven execution**:

1. **Eager Start**: I/O operations begin immediately (non-blocking)
2. **Dependency Tracking**: The runtime tracks which variables each statement needs
3. **Lazy Synchronization**: Only wait for data when it's actually used
4. **Preserved Semantics**: Results appear in statement order

### Example

```aro
(Process Config: File Handler) {
    <Open> the <config-file> from the <path>.        (* 1. Starts file load *)
    <Compute> the <hash> for the <request>.          (* 2. Runs immediately *)
    <Log> the <status> for the <request>.            (* 3. Runs immediately *)
    <Parse> the <config> from the <config-file>.     (* 4. Waits for file *)
    <Return> an <OK: status> with <config>.
}
```

**What happens:**

- Statement 1 kicks off file loading (async, returns immediately)
- Statements 2 and 3 execute while the file loads in background
- Statement 4 waits only if the file isn't ready yet
- You see: synchronous execution
- Runtime does: parallel I/O with sequential semantics

**Write synchronous code. Get async performance.**

## Event Emission

Feature sets can trigger other feature sets:

```aro
(Create User: User API) {
    <Extract> the <data> from the <request: body>.
    <Create> the <user> with <data>.
    <Store> the <user> in the <user-repository>.

    (* Triggers other feature sets asynchronously *)
    <Emit> to <Send Welcome Email> with <user>.

    (* Continues immediately, doesn't wait for handler *)
    <Return> a <Created: status> with <user>.
}

(Send Welcome Email: Notifications) {
    <Extract> the <email> from the <event: email>.
    <Send> the <welcome-email> to the <email>.
    <Return> an <OK: status>.
}
```

When `<Emit>` executes:

1. The event is dispatched to the target feature set
2. Execution continues in the current feature set
3. The target handler starts executing independently

## No Concurrency Primitives

ARO explicitly does **not** provide:

- `async` / `await` keywords
- Promises / Futures
- Threads / Task spawning
- Locks / Mutexes / Semaphores
- Channels
- Actors
- Parallel for loops

These are implementation concerns. The runtime handles them. You write sequential code that responds to events.

## Examples

### HTTP Server

```aro
(Application-Start: My API) {
    <Start> the <http-server> on port 8080.
    <Keepalive> the <application> for the <events>.
    <Return> an <OK: status>.
}

(* Each request triggers this independently *)
(getUser: User API) {
    <Extract> the <id> from the <pathParameters: id>.
    <Retrieve> the <user> from the <user-repository> where id = <id>.
    <Return> an <OK: status> with <user>.
}
```

### Socket Echo Server

```aro
(Application-Start: Echo Server) {
    <Start> the <socket-server> on port 9000.
    <Keepalive> the <application> for the <events>.
    <Return> an <OK: status>.
}

(* Each client message triggers this independently *)
(Handle Data: Socket Event Handler) {
    <Extract> the <data> from the <event: data>.
    <Extract> the <connection> from the <event: connection>.
    <Send> the <data> to the <connection>.
    <Return> an <OK: status>.
}
```

### File Watcher

```aro
(Application-Start: File Watcher) {
    <Watch> the <directory> for the <changes> with "./watched".
    <Keepalive> the <application> for the <events>.
    <Return> an <OK: status>.
}

(* Each file change triggers this independently *)
(Handle File Change: File Event Handler) {
    <Extract> the <path> from the <event: path>.
    <Extract> the <type> from the <event: type>.
    <Log> the <change: message> with <path> and <type>.
    <Return> an <OK: status>.
}
```

## Summary

| Concept | Behavior |
|---------|----------|
| Feature sets | Run async (triggered by events) |
| Statements | Appear sync (serial execution) |
| I/O operations | Async under the hood |
| Events | Non-blocking dispatch |
| Concurrency primitives | None needed |

Write synchronous code. Get async performance. No callbacks, no promises, no await.

---

*Next: Chapter 30 — Context-Aware Response Formatting*
