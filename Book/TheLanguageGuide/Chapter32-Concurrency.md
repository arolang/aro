# Chapter 32: Concurrency

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
    <Log> <request> to the <console>.                 (* 3. Runs immediately *)
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

These are implementation concerns. The runtime handles them. You write sequential code that responds to events.

## Parallel For-Each Loops

While ARO doesn't expose traditional concurrency primitives, it **does** provide a high-level construct for parallel iteration: **`parallel for each`**. This enables true parallel execution across CPU cores for computationally intensive operations.

### Serial vs Parallel Iteration

By default, `for each` loops execute serially—one item after another:

```aro
for each <number> in <numbers> {
    <Log> <number> to the <console>.
}
```

Output: `1 2 3 4 5` (deterministic order)

The `parallel for each` variant executes iterations concurrently:

```aro
parallel for each <number> in <numbers> {
    <Log> <number> to the <console>.
}
```

Output: `3 1 5 2 4` (non-deterministic order, varies each run)

### Syntax

```aro
parallel for each <variable> in <collection> {
    (* Statements execute in parallel for each item *)
}
```

The loop body executes **simultaneously** for all items in the collection, utilizing available CPU cores.

### Execution Model

Under the hood, `parallel for each` uses:

- **DispatchQueue** for thread pool management
- **DispatchSemaphore** for concurrency limiting
- **NSLock** for thread-safe error tracking
- **Isolated contexts** per iteration (no shared mutable state)

Each iteration gets its own execution context, preventing race conditions while maintaining ARO's immutability guarantees.

### Concurrency Control

By default, parallel loops use `System.coreCount` threads (matching your CPU's logical cores):

```aro
(* Uses all available cores *)
parallel for each <item> in <items> {
    <Compute> the <result> from <item>.
}
```

You can override concurrency with the `with` clause:

```aro
(* Limit to 4 concurrent iterations *)
parallel for each <item> in <items> with <concurrency: 4> {
    <Compute> the <result> from <item>.
}
```

### When to Use Parallel Iteration

Use `parallel for each` when:

- **CPU-bound work**: Heavy computation per iteration
- **Independence**: Iterations don't depend on each other
- **Large collections**: Enough items to justify parallelism overhead
- **Order doesn't matter**: Results can be processed in any order

**Don't use it for:**

- **I/O-bound work**: Network/file operations (event-driven already handles concurrency)
- **Small collections**: Overhead exceeds benefits (< 100 items typically)
- **Order-dependent logic**: When sequence matters
- **Side effects**: Database writes, file modifications (use events instead)

### Thread Safety

ARO's immutability model ensures thread safety:

- Variables are bound once per iteration
- Each iteration has an isolated context
- No shared mutable state within feature sets
- Repositories use internal synchronization

You don't need locks or mutexes. The language prevents data races by design.

### Example

From `Examples/ParallelForEach/main.aro`:

```aro
(Application-Start: ForEach Demo) {
    <Create> the <numbers> with [1, 2, 3, 4, 5, 6, 7, 8, 9, 10].

    <Log> "=== Serial Iteration ===" to the <console>.
    for each <number> in <numbers> {
        <Log> <number> to the <console>.
    }

    <Log> "=== Parallel Iteration ===" to the <console>.
    parallel for each <number> in <numbers> {
        <Log> <number> to the <console>.
    }

    <Return> an <OK: status> for the <demo>.
}
```

Output (example):
```
=== Serial Iteration ===
1
2
3
4
5
6
7
8
9
10
=== Parallel Iteration ===
3
1
7
5
2
9
4
10
6
8
```

### Performance Characteristics

- **Non-deterministic order**: Items complete in unpredictable sequence
- **CPU utilization**: Scales with available cores (up to `System.coreCount`)
- **Overhead**: Thread management cost (~1-10ms startup)
- **Best for**: Compute-heavy operations (> 10ms per iteration)

**Write-once semantics**: Even in parallel execution, variables remain immutable within each iteration's context. The parallel loop doesn't violate ARO's constraint-based philosophy—it simply executes independent, immutable transformations simultaneously.

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
    <Compute> the <message> from "File " + <path> + " " + <type>.
    <Log> <message> to the <console>.
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

*Next: Chapter 33 — Context-Aware Response Formatting*
