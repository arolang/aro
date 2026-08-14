# Chapter 39: Concurrency

ARO's concurrency model is radically simple: **feature sets are async, and statements wait only for what they read**. This chapter explains how ARO handles concurrent operations without requiring you to think about threads, locks, or async/await.

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

<div style="text-align: center; margin: 2em 0;">
<svg width="520" height="200" viewBox="0 0 520 200" xmlns="http://www.w3.org/2000/svg" font-family="sans-serif">
  <!-- Title: concurrent dispatch -->
  <text x="260" y="16" text-anchor="middle" font-size="10" fill="#374151" font-style="italic">concurrent dispatch</text>

  <!-- Event Bus (dark) -->
  <rect x="10" y="25" width="110" height="120" rx="4" fill="#1f2937" stroke="#1f2937" stroke-width="2"/>
  <text x="65" y="80" text-anchor="middle" font-size="11" fill="#ffffff" font-weight="bold">Event</text>
  <text x="65" y="96" text-anchor="middle" font-size="11" fill="#ffffff" font-weight="bold">Bus</text>

  <!-- Arrow to Handler A -->
  <line x1="120" y1="50" x2="210" y2="50" stroke="#1f2937" stroke-width="2"/>
  <polygon points="210,50 200,45 200,55" fill="#1f2937"/>

  <!-- Arrow to Handler B -->
  <line x1="120" y1="85" x2="210" y2="85" stroke="#1f2937" stroke-width="2"/>
  <polygon points="210,85 200,80 200,90" fill="#1f2937"/>

  <!-- Arrow to Handler C -->
  <line x1="120" y1="120" x2="210" y2="120" stroke="#1f2937" stroke-width="2"/>
  <polygon points="210,120 200,115 200,125" fill="#1f2937"/>

  <!-- Handler A (indigo) -->
  <rect x="212" y="30" width="130" height="38" rx="4" fill="#e0e7ff" stroke="#6366f1" stroke-width="2"/>
  <text x="277" y="50" text-anchor="middle" font-size="11" fill="#4338ca" font-weight="bold">Handler A</text>
  <text x="277" y="64" text-anchor="middle" font-size="8" fill="#4338ca">async</text>

  <!-- Handler B (indigo) -->
  <rect x="212" y="66" width="130" height="38" rx="4" fill="#e0e7ff" stroke="#6366f1" stroke-width="2"/>
  <text x="277" y="86" text-anchor="middle" font-size="11" fill="#4338ca" font-weight="bold">Handler B</text>
  <text x="277" y="100" text-anchor="middle" font-size="8" fill="#4338ca">async</text>

  <!-- Handler C (indigo) -->
  <rect x="212" y="102" width="130" height="38" rx="4" fill="#e0e7ff" stroke="#6366f1" stroke-width="2"/>
  <text x="277" y="122" text-anchor="middle" font-size="11" fill="#4338ca" font-weight="bold">Handler C</text>
  <text x="277" y="136" text-anchor="middle" font-size="8" fill="#4338ca">async</text>

  <!-- Sequential bar (gray) spanning all three handlers -->
  <rect x="212" y="150" width="130" height="30" rx="4" fill="#f3f4f6" stroke="#9ca3af" stroke-width="2"/>
  <text x="277" y="169" text-anchor="middle" font-size="9" fill="#374151">statements execute</text>

  <!-- Title: sequential within each -->
  <text x="277" y="192" text-anchor="middle" font-size="9" fill="#374151" font-style="italic">ordered within each</text>
</svg>
</div>

## Statements Are Ordered

Inside a feature set, statements are written and read in order:

```aro
(Process Order: Order API) {
    Extract the <data> from the <request: body>.      (* 1. First *)
    Validate the <valid-data> for <data>.       (* 2. Second *)
    Create the <order> with <data>.                   (* 3. Third *)
    Store the <order> into the <order-repository>.      (* 4. Fourth *)
    Emit a <OrderConfirmed: event> with <order>.      (* 5. Fifth *)
    Return a <Created: status> with <order>.          (* 6. Last *)
}
```

No callbacks. No promises. No async/await syntax.

That is the order you read, and the order effects happen in. What it does *not* mean is that each statement finishes before the next one starts.

A statement's action starts where it is written; the program waits for it at the **first read of its result**. So statements that need nothing from each other run at the same time:

```aro
(Report: Analytics) {
    Read the <content> from "./big.csv".        (* starts *)
    Compute the <token> from <seed> * 7919.     (* starts — does not wait for the read *)
    Compute the <lines: count> from <content>.  (* waits for the read, here *)
    Log <token> to the <console>.
    Log <lines> to the <console>.
}
```

Two independent 2-second HTTP requests in one feature set take about 2.1 seconds, not 4.2. You did not ask for that and there is no syntax for it — the runtime derives it from which statement reads which binding.

Effects are the part that never moves. `Log`, `Store`, `Emit`, `Send` and friends run at their own statement and force whatever they read first, so anything you can observe still happens in the order you wrote it.

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
    Extract the <data> from the <request: body>.
    Validate the <valid-data> for <data>.
    Create the <order> with <data>.
    Store the <order> into the <order-repository>.
    Emit a <OrderConfirmed: event> with <order>.
    Return a <Created: status> with <order>.
}
```

No `async`. No `await`. Just statements in order.

### No Race Conditions

Within a feature set, there's no shared mutable state problem:

- Variables are scoped to the feature set
- Bindings are immutable, so overlapping statements cannot disagree about a value
- Effects are pinned to their statements, so observable order is the written order

### Natural Event Flow

Events naturally express concurrency:

- User A requests an order while User B requests their profile
- Both feature sets run concurrently
- Each processes their own data independently

## Where the Concurrency Actually Is

| Granularity | Concurrent? |
|---|---|
| Statements in one feature set | **Yes, where independent** — each waits only at the first read of its result |
| Effects (`Log`, `Store`, `Emit`, …) | No — pinned to their own statement, in source order |
| Iterations of `for each` | No |
| Iterations of `parallel for each` | Yes, up to the concurrency limit |
| Two feature sets triggered independently | Yes |
| An `Emit` and its handlers | Yes — the emitter continues immediately |
| A stream's producer and its consumer | Yes, bounded by the prefetch window |

So a feature set that makes five independent HTTP requests and reads them at the end makes them concurrently. One that reads each result before issuing the next request cannot — you have written a chain, and the runtime honours it.

### Which actions defer

Value-producing ones: reads (`Retrieve`, `Fetch`, `Read`, `Request`, `Extract`, `Parse`, …) and pure transformations (`Compute`, `Transform`, `Create`, `Filter`, `Map`, `Reduce`, `Sort`, `Render`, …).

Everything else runs at its statement. `Sleep` is the interesting exclusion: the delay *is* the effect, so `Sleep` followed by an unrelated `Log` still pauses. Repository writes, `Emit`, `Send`, service lifecycle and the branch consumers (`Compare`, `Validate`, `Accept`) all stay put too. The full list, with the reasoning for each exclusion, is ARO-0088 §2.

### When you need it off

`ARO_NO_DEFER=1` runs every action at its statement, as the runtime did before this model. It exists for one purpose: if a program misbehaves in a way that looks order-related, setting it tells you in one step whether overlap is involved.

### Errors

A failure is reported against the statement that caused it, not the one that noticed it. Because reads are total, a failing statement's result reads as empty and the error is raised no later than the end of the feature set — which means a `Log` sitting between the failure and the read will already have printed. That is the one place where deferral is visible in a way you have to think about.

## Event Emission

Feature sets can trigger other feature sets:

```aro
(Create User: User API) {
    Extract the <data> from the <request: body>.
    Create the <user> with <data>.
    Store the <user> into the <user-repository>.

    (* Triggers other feature sets asynchronously *)
    Emit a <UserCreated: event> with <user>.

    (* Continues immediately, doesn't wait for handler *)
    Return a <Created: status> with <user>.
}

(Send Welcome Email: UserCreated Handler) {
    Extract the <email> from the <event: email>.
    Send the <welcome-email> to the <email>.
    Return an <OK: status> for the <notification>.
}
```

When `Emit` executes:

1. The event is dispatched to the target feature set
2. Execution continues in the current feature set
3. The target handler starts executing independently

## No Concurrency Primitives in the Language

ARO's surface syntax has no:

- `async` / `await` keywords
- promises or futures
- thread or task creation
- locks, mutexes, semaphores
- channels
- race / all / any combinators

The runtime uses every one of these internally — that is how it runs your feature sets concurrently and keeps repositories consistent. The point is not that they don't exist; it's that they are never yours to manage. You write sequential code that responds to events, plus `parallel for each` when you explicitly want fan-out.

## Parallel For-Each Loops

While ARO doesn't expose traditional concurrency primitives, it **does** provide a high-level construct for parallel iteration: **`parallel for each`**. This enables true parallel execution across CPU cores for computationally intensive operations.

### Serial vs Parallel Iteration

By default, `for each` loops execute serially—one item after another:

```aro
for each <number> in <numbers> {
    Log <number> to the <console>.
}
```

Output: `1 2 3 4 5` (deterministic order)

The `parallel for each` variant executes iterations concurrently:

```aro
parallel for each <number> in <numbers> {
    Log <number> to the <console>.
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

Under the hood, `aro run` schedules iterations into a task group and keeps at most *N* in flight; a compiled binary does the same through the same runtime, with a tighter bound because compiled handlers occupy real threads while they wait. Either way:

- Each iteration gets its **own child scope**, with the loop variable and index bound in it
- A `where` filter is evaluated per item, in its own scope, before the body is scheduled
- Nothing is shared between iterations, so there is no race to lose

Bindings are immutable, so an iteration cannot write to a variable in the enclosing scope. To collect results, store them into a repository — repository operations are individually atomic — and read them back after the loop.

### Concurrency Control

By default, a parallel loop runs up to `min(item count, max(4, cores × 4))` iterations at once — a multiple of the core count, capped by how many items there are, so a ten-item loop never spawns more than ten. The multiple is deliberate: iterations usually spend their time waiting on something, not computing.

```aro
(* Uses the default bound *)
parallel for each <item> in <items> {
    Compute the <result> from <item>.
}
```

You can override concurrency with the `with` clause:

```aro
(* Limit to 4 concurrent iterations *)
parallel for each <item> in <items> with <concurrency: 4> {
    Compute the <result> from <item>.
}
```

### When to Use Parallel Iteration

Use `parallel for each` when:

- **Independence**: iterations don't depend on each other
- **I/O-bound work**: fetching twenty URLs, reading many files. Sequential statements never overlap, so this is the construct that turns twenty one-second requests into a few seconds instead of twenty
- **CPU-bound work**: heavy computation per iteration, across cores
- **Order doesn't matter**: completion order is not defined

**Don't use it for:**

- **Order-dependent logic**: when one iteration's result feeds the next
- **Small, cheap collections**: the coordination overhead outweighs the gain
- **Rate-limited services**: or if you must, bound it with `with <concurrency: N>` set to what the service tolerates

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
    Create the <numbers> with [1, 2, 3, 4, 5, 6, 7, 8, 9, 10].

    Log "=== Serial Iteration ===" to the <console>.
    for each <number> in <numbers> {
        Log <number> to the <console>.
    }

    Log "=== Parallel Iteration ===" to the <console>.
    parallel for each <number> in <numbers> {
        Log <number> to the <console>.
    }

    Return an <OK: status> for the <demo>.
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
    Start the <http-server> with <contract>.
    Keepalive the <application> for the <events>.
    Return an <OK: status> for the <startup>.
}

(* Each request triggers this independently *)
(getUser: User API) {
    Extract the <id> from the <pathParameters: id>.
    Retrieve the <user> from the <user-repository> where <id> = <id>.
    Return an <OK: status> with <user>.
}
```

### Socket Echo Server

```aro
(Application-Start: Echo Server) {
    Start the <socket-server> with { port: 9000 }.
    Keepalive the <application> for the <events>.
    Return an <OK: status> for the <startup>.
}

(* Each client message triggers this independently *)
(Handle Data: Socket Event Handler) {
    Extract the <data> from the <event: data>.
    Extract the <connection> from the <event: connection>.
    Send the <data> to the <connection>.
    Return an <OK: status> for the <echo>.
}
```

### File Watcher

```aro
(Application-Start: File Watcher) {
    Watch the <directory> for the <changes> with "./watched".
    Keepalive the <application> for the <events>.
    Return an <OK: status> for the <startup>.
}

(* Each file change triggers this independently *)
(Handle File Change: File Event Handler) {
    Extract the <path> from the <event: path>.
    Compute the <message> from "File changed: " ++ <path>.
    Log <message> to the <console>.
    Return an <OK: status> for the <handling>.
}
```

## CrawlPage Event Deduplication

When building web crawlers or recursive-fetch workflows with `CrawlPage` events, the runtime automatically deduplicates events by URL. If a URL is emitted more than once (because multiple pages link to the same target), only the first emission triggers the handler — subsequent ones are silently dropped.

```aro
(Crawl Page: Web Crawler) {
    Extract the <url> from the <event: url>.
    Fetch the <page> from <url>.
    Extract the <links> from the <page: links>.

    (* The runtime deduplicates: already-visited URLs are skipped *)
    for each <link> in <links> {
        Emit a <CrawlPage: event> with <link>.
    }

    Return an <OK: status> for the <crawl>.
}
```

The deduplication store is bounded to **100 000 URLs** (FIFO eviction) so that very large crawls cannot exhaust memory. If your crawl needs to revisit URLs or requires a larger cap, track visited state explicitly in a repository.

---

## Summary

| Concept | Behavior |
|---------|----------|
| Feature sets | Run concurrently — every trigger is an independent execution |
| Statements | Sequential, in source order; independent statements do **not** overlap |
| `parallel for each` | The one place you ask for concurrency; bounded, non-deterministic order |
| Events | `Emit` does not block; handlers run on their own |
| Shared state | Repositories and published symbols, each operation atomic |
| Concurrency primitives | None in the language; the runtime has them all |
| CrawlPage dedup | Automatic, bounded to 100K URLs |

Write sequential code per feature set. Let events and `parallel for each` provide the concurrency. The full specification is ARO-0088.

---

*Next: Chapter 40 — Context-Aware Response Formatting*
