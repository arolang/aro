# ARO-0011: Concurrency Model

* Proposal: ARO-0011
* Author: ARO Language Team
* Status: **Implemented**
* Requires: ARO-0001

## Abstract

This proposal defines ARO's concurrency model: **feature sets are async, statements are sync**. Feature sets execute asynchronously in response to events. Within a feature set, all statements execute synchronously and serially.

## Philosophy

ARO's concurrency model matches how project managers think:

- **"When X happens, do Y"** - Feature sets are triggered by events
- **"Do this, then this, then this"** - Steps happen in order

Project managers don't think about threads, locks, race conditions, or async/await. They think about things happening and responding to them in sequence.

**The fundamental principle**: Events trigger feature sets asynchronously. Inside a feature set, everything runs top to bottom.

---

## The Model

### 1. Feature Sets Are Async

Every feature set runs asynchronously when triggered by an event:

```
┌─────────────────────────────────────────────────────────────┐
│                    Event Bus                                 │
│                                                              │
│  HTTP Request ──┬──► (listUsers: User API)                  │
│                 │                                            │
│  Socket Data ───┼──► (Handle Data: Socket Handler)          │
│                 │                                            │
│  File Changed ──┼──► (Process File: File Handler)           │
│                 │                                            │
│  UserCreated ───┴──► (Send Email: UserCreated Handler)      │
│                                                              │
│  (Multiple events can trigger multiple feature sets          │
│   running concurrently)                                      │
└─────────────────────────────────────────────────────────────┘
```

When multiple events arrive, multiple feature sets can execute simultaneously.

### 2. Statements Are Sync

Inside a feature set, statements execute **synchronously** and **serially**:

```aro
(Process Order: Order API) {
    <Extract> the <data> from the <request: body>.      (* 1. First *)
    <Validate> the <data> for the <order-schema>.       (* 2. Second *)
    <Create> the <order> with <data>.                   (* 3. Third *)
    <Store> the <order> in the <order-repository>.      (* 4. Fourth *)
    <Emit> an <OrderCreated: event> with <order>.       (* 5. Fifth *)
    <Return> a <Created: status> with <order>.          (* 6. Last *)
}
```

Each statement completes before the next one starts. No callbacks. No promises. No async/await syntax. Just sequential execution.

---

## Why This Model?

### 1. Simplicity

Traditional async code:
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
    <Emit> an <OrderCreated: event> with <order>.
    <Return> a <Created: status> with <order>.
}
```

No `async`. No `await`. Just statements in order.

### 2. No Race Conditions

Within a feature set, there's no shared mutable state problem:
- Variables are scoped to the feature set
- Statements execute serially
- No concurrent access to the same data

### 3. Natural Event Flow

Events naturally express concurrency:
- User requests an order while another user requests their profile
- Both feature sets run concurrently
- Each processes their own data independently

---

## How It Works

### Event Triggers Feature Set

```
HTTP POST /orders
    │
    ▼
┌─────────────────────────────────────┐
│ Runtime Event Bus                    │
│                                      │
│ Route matches "createOrder"          │
│ Spawn new execution context          │
│ Execute feature set statements       │
└─────────────────────────────────────┘
    │
    ▼
(createOrder: Order API) {
    statement 1
    statement 2
    statement 3
    ...
}
```

### Multiple Events, Multiple Executions

```
HTTP POST /orders (User A)  ──────────►  Execution Context 1
                                              │
HTTP GET /users (User B)    ──────────►  Execution Context 2
                                              │
Socket Data (Client C)      ──────────►  Execution Context 3
                                              │
FileChanged (config.json)   ──────────►  Execution Context 4

(All running concurrently, each executing their statements serially)
```

---

## Blocking Operations

From the programmer's perspective, I/O operations appear to block:

```aro
(Fetch Data: API) {
    <Fetch> the <data> from the <external-api>.
    <Transform> the <result> from <data>.
    <Return> an <OK: status> with <result>.
}
```

The programmer writes sequential code. The runtime handles the rest.

---

## Runtime Optimization (Under the Hood)

While the programmer writes synchronous-looking code, the ARO runtime executes operations **asynchronously** based on data dependencies. This is transparent to the user.

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
- User sees: synchronous execution
- Runtime does: parallel I/O with sequential semantics

### Why This Matters

The programmer never writes `async`/`await`. The runtime automatically:
- Overlaps I/O operations where possible
- Respects data dependencies
- Delivers results in the order written

This is the ARO philosophy: **write synchronous code, get async performance**.

---

## Event Emission

Feature sets can trigger other feature sets via events:

```aro
(Create User: User API) {
    <Extract> the <data> from the <request: body>.
    <Create> the <user> with <data>.
    <Store> the <user> in the <user-repository>.

    (* This triggers other feature sets asynchronously *)
    <Emit> a <UserCreated: event> with <user>.

    (* Continues immediately, doesn't wait for handlers *)
    <Return> a <Created: status> with <user>.
}

(* Runs asynchronously when UserCreated is emitted *)
(Send Welcome Email: UserCreated Handler) {
    <Extract> the <user> from the <event: user>.
    <Send> the <welcome-email> to the <user: email>.
    <Return> an <OK: status>.
}

(* Also runs asynchronously, concurrently with email *)
(Track Analytics: UserCreated Handler) {
    <Extract> the <user> from the <event: user>.
    <Record> the <signup: metric> with <user>.
    <Return> an <OK: status>.
}
```

When `<Emit>` executes:
1. The event is published to the event bus
2. Execution continues in the current feature set
3. Subscribed handlers start executing in parallel

---

## No Concurrency Primitives

ARO explicitly does **not** provide:

- `async` / `await` keywords
- Promises / Futures
- Threads / Task spawning
- Locks / Mutexes / Semaphores
- Channels
- Actors
- Race / All / Any combinators
- Parallel for loops

These are implementation concerns. The runtime handles them. The programmer writes sequential code that responds to events.

---

## Examples

### HTTP Server

```aro
(Application-Start: My API) {
    <Start> the <http-server> on port 8080.
    <Keepalive> the <application> for the <events>.
    <Return> an <OK: status>.
}

(* Each request triggers this feature set independently *)
(getUser: User API) {
    <Extract> the <id> from the <pathParameters: id>.
    <Retrieve> the <user> from the <user-repository> where id = <id>.
    <Return> an <OK: status> with <user>.
}
```

100 simultaneous requests = 100 concurrent feature set executions.
Each execution runs its statements serially.

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

---

## Summary

ARO's concurrency model is radically simple:

1. **Feature sets run async** - Triggered by events, run concurrently
2. **Statements appear sync** - Execute serially from programmer's view
3. **Runtime optimizes** - Async execution under the hood based on data flow
4. **No concurrency primitives** - The runtime handles all of it

Write synchronous code. Get async performance. No callbacks, no promises, no await.

---

## Revision History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2024-01 | Initial specification with full concurrency primitives |
| 2.0 | 2024-12 | Complete rewrite: event-driven async, serial sync execution |
| 2.1 | 2025-12 | Document async runtime optimization with sync semantics |
