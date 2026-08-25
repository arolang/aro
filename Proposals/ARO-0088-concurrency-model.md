# ARO-0088: Concurrency Model

- **Status:** Accepted (describes the implemented runtime — [Issue #485](https://git.ausdertechnik.de/arolang/aro/-/issues/485))
- **Author:** ARO Language Team
- **Created:** 2026-08-09
- **Related:** ARO-0005 (Application Architecture), ARO-0007 (Events & Reactive), ARO-0002 (Control Flow — iteration), ARO-0051 (Streaming Execution), ARO-0008 (I/O Services), ARO-0090 (Streaming I/O — deferral vs. materialization)

## Abstract

This proposal specifies ARO's concurrency model: what runs at the same time as what, what ordering a program may rely on, and what the runtime does underneath.

The central rule is **demand-driven overlap**. A statement's action starts where it is written, but the program only *waits* for it where its result is read. Statements whose results nobody needs yet run concurrently with the statements after them, and the cost of a feature set becomes its critical path rather than the sum of its statements. Effects — anything observable — stay pinned to their own statement, so source order still means what it looks like it means.

Before this proposal the only specification text was §4 of ARO-0005, which had drifted from the runtime in both directions: it denied constructs that exist (`parallel for each`, actors, futures) while promising overlap that did not happen. Concurrency is the one area where a wrong specification is expensive — a reader who trusts it writes code whose failure mode is a nondeterministic result, not a compile error.

## Motivation

ARO's premise is that the programmer writes sequential business logic and the runtime deals with concurrency (ARO-0005 §1). That premise only holds if the boundary is written down. Three questions come up in practice and had no authoritative answer:

1. **Does the next statement start before the previous action finishes?**
2. **When two feature sets touch the same repository, what is guaranteed?**
3. **What does `parallel for each` actually parallelise, and what is unsafe inside it?**

This document answers all three, with the source of truth being the runtime itself.

## 1. The Levels

```
+-----------------------------------------------------------------------+
| Feature sets       CONCURRENT                                          |
|   Independent triggers (HTTP requests, events, file changes, sockets)  |
|   run their feature sets at the same time.                             |
+-----------------------------------------------------------------------+
| Statements         CONCURRENT WHERE INDEPENDENT                        |
|   A statement starts where it is written. The program waits for it at  |
|   the first read of its result — so statements that need nothing from  |
|   it run alongside it.                                                 |
+-----------------------------------------------------------------------+
| Effects            ORDERED                                             |
|   Log, Store, Emit, Send, … run at their own statement, in source      |
|   order, forcing what they read first.                                 |
+-----------------------------------------------------------------------+
| Iterations         SEQUENTIAL, or CONCURRENT on request                |
|   `for each` -> one at a time; `parallel for each` -> up to N at once. |
+-----------------------------------------------------------------------+
| Streams            PIPELINED                                           |
|   The producer prepares the next elements while the consumer works on  |
|   the current one, bounded by a prefetch window.                       |
+-----------------------------------------------------------------------+
```

## 2. Statement Execution

### The rule

> A statement's action **starts** at its position in source order.
> The program **waits** for it at the first read of the binding it produces.

Nothing else is promised, and nothing less is. Consider:

```aro
(Report: Analytics) {
    Read the <content> from "./big.csv".        (* 1 starts *)
    Compute the <token> from <seed> * 7919.     (* 2 starts — does not wait for 1 *)
    Compute the <lines: count> from <content>.  (* 3 waits for 1 *)
    Log <token> to the <console>.               (* 4 waits for 2 *)
    Log <lines> to the <console>.               (* 5 waits for 3 *)
}
```

Statement 2 does not wait for statement 1, because it needs nothing from it. Statement 3 is where the file read is actually awaited, because that is where its content is first needed. The feature set costs `max(read, token)` rather than `read + token`.

Measured, on two independent 2-second HTTP requests in one feature set:

| | Before | After |
|---|---|---|
| `aro run` | 4.18s | 2.14s |
| compiled binary | 4.2s | 2.85s |

### Eager start, lazy join

Work begins at the statement; only the *wait* moves. The alternative — starting nothing until someone reads it — was rejected for two reasons:

1. **An unread statement would never run.** A `Retrieve` whose result is never read would silently not happen, which contradicts ARO's error philosophy: the program says to do it, so it is done.
2. **Reads of mutable state would drift.** A `Retrieve` reads the repository at the point in time its line implies. If the read were deferred to the force site, it could observe a `Store` written by a *later* statement and quietly return different data than the source suggests.

### What a program may rely on

| Guarantee | Holds |
|---|---|
| Effects run at their own statement, in source order | Yes |
| An effect sees the finished value of everything it reads | Yes |
| A read yields the value its producing statement computed | Yes |
| A statement's action has started once the statement is passed | Yes |
| A failure is reported, whether or not anyone read the result | Yes |
| A pure statement has *finished* before the next statement starts | **No** |
| Two statements' side effects interleave | **No** — effects are never deferred |

### Which actions defer

Deferral is an allowlist of verbs that either compute a value or read one, never both-and-something-else:

- **Reads** — `Retrieve`, `Fetch`, `Read`, `Request`, `Load`, `Find`, `Probe`, `Receive`, `Extract`, `Parse`, `Get`
- **Pure transformations** — `Compute`, `Calculate`, `Derive`, `Transform`, `Create`, `Build`, `Construct`, `Filter`, `Map`, `Reduce`, `Aggregate`, `Split`, `Group`, `Sort`, `Merge`, `Combine`, `Join`, `Concat`, `Render`, `Format`

An allowlist, not "everything that is not an effect", because semantic role is too coarse to decide this: `ActionSemanticRole.classify` files `Update` and `Delete` under `.own` next to `Compute`, and deferring a repository delete would move a world-changing effect to wherever someone happened to read its result.

Deliberately excluded, with reasons:

| Excluded | Why |
|---|---|
| `Sleep`, `Delay`, `Pause` | The delay **is** the effect. `Sleep` followed by an unrelated `Log` is a pacing idiom; deferring it would delete the pause. |
| `Store`, `Update`, `Delete`, `Send`, `Write`, `Commit`, `Push`, `Stage`, `Tag`, `Notify` | Observable state changes. |
| `Log`, `Return`, `Throw`, `Publish`, `Emit` | Output and control flow — the force-at-site set. |
| `Compare`, `Validate`, `Accept` | Feed branches; a guard that has not decided yet is not a guard. |
| `Start`, `Stop`, `Connect`, `Close`, `Keepalive` | Service lifecycle, ordered against everything by definition. |
| `Assert`, `Then` | A test that runs only if someone reads it is not a test. |
| `Render`, `Repaint` | They paint a terminal. `ActionSemanticRole.classify` files both under `.response`; deferring `Render` floated a menu banner above the log lines that precede it in source. |

### Statement scope

Each statement gets its own scope for the framework variables that carry its modifiers (`_with_`, `_where_value_`, `_literal_`, …). Without it a deferred action would read the *next* statement's modifiers, because the next statement rebinds them before the deferred one runs. Everything else an action binds — its result, and any auxiliary name — writes through to the feature set, where consumers look for it.

## 3. Force Points

A **force point** is where the program waits for a deferred result:

- **Reading the binding** — directly, by field access (`<obj: field>`, dotted paths), in a `when` guard, in a `with` expression, or as the collection of a `for each`.
- **An effect that reads it** — the effect forces its inputs before it runs, which is what keeps observable output in source order.
- **`Emit`** — payloads are forced at the emitting statement. Deferring them to "first handler read" was tried and abandoned: an unforced handle escaping into an event would have to be understood by every path that binds, serialises, or ships that payload.
- **Feature-set exit** — everything still outstanding is forced before the feature set returns. This is what stops a failure nobody read from disappearing.

Forcing is memoized: many readers of one binding wait for one execution, and a second read is free.

## 4. Errors

A deferred failure is reported with the statement that **caused** it, not the statement that noticed it. The error is built at the deferred statement — verb, result, object, feature set, source location — and carried with the handle, so the message names the right line even though it surfaces later.

Reads stay total: a read of a failed result yields an empty value rather than throwing at an arbitrary point, and the recorded failure is raised at feature-set exit. The consequence to know: **a failure can be reported after side effects that followed its statement have already run.** A `Log` between a failing `Retrieve` and the read of its result will have printed.

## 5. Feature Sets Run Concurrently

Every trigger starts an independent execution. Two HTTP requests, an event handler, and a file-change handler can all be in flight at once.

```
+---------------------------------------------------------------+
|                          Event Bus                            |
|                                                               |
|  HTTP GET /users  --+--> (listUsers: User API)      ---+       |
|  HTTP POST /users --+--> (createUser: User API)     ---+       |
|  UserCreated ------ +--> (Send Email: ... Handler)  ---+       |
|  file changed  -----+--> (Reload: File Handler)     ---+       |
|                                                       |       |
|                    all four in flight simultaneously  v       |
+---------------------------------------------------------------+
```

Each execution gets its own binding scope. Nothing is shared implicitly: two concurrent executions of the same feature set cannot see each other's variables. The only shared, mutable surfaces are **repositories** (§7) and **published symbols**.

## 6. `parallel for each`

The one place a program asks for concurrency explicitly.

```aro
(* Sequential: one iteration at a time, deterministic order *)
for each <url> in <urls> {
    Request the <page> from <url>.
    Store the <page> into the <page-repository>.
}

(* Concurrent: up to N iterations at a time, non-deterministic order *)
parallel for each <url> in <urls> {
    Request the <page> from <url>.
    Store the <page> into the <page-repository>.
}

(* Explicit bound *)
parallel for each <url> in <urls> with <concurrency: 8> {
    Request the <page> from <url>.
}
```

### Semantics

| Property | Behaviour |
|---|---|
| Completion order | Non-deterministic. Never write code that depends on it. |
| Statements *inside* one iteration | Sequential, exactly as §2 |
| Iteration scope | Each iteration gets a fresh child scope; the loop variable and index are bound there |
| Writes to outer bindings | Not possible — bindings are immutable; accumulate through a repository instead |
| Default concurrency | `min(item count, max(4, cores × 4))` |
| `with <concurrency: N>` | Overrides the default; `N ≤ 0` is rejected with a diagnostic and clamped to 1 |
| Filters (`where`) | Evaluated per item in its own child scope before the body is scheduled |

The default bound is deliberately not "one task per item": an unbounded fan-out over a 500-element collection used to spawn 500 tasks and exhaust the thread pool. When iteration cost is dominated by an external service, set `with <concurrency: N>` to that service's tolerance rather than the machine's.

### What is safe inside a parallel iteration

Safe: computing, requesting, storing to repositories, emitting events, logging.
Unsafe: anything that assumes an ordering between iterations, or that one iteration observes another's effects.

Repository writes from concurrent iterations are serialised by the repository's own isolation (§8) — the *result* is consistent, but the *order* in which entries land is not defined.

## 7. Event Dispatch

`Emit` hands the event to the bus and the emitting feature set continues; it does not wait for handlers. The bus is an actor, so its own state transitions are serialised, and it offers three delivery strategies:

```
Emit
 |
 +-- publish()              fire-and-forget: one task per matching handler.
 |                          Highest fan-out, no bound on concurrent handlers.
 |
 +-- publishAndTrack()      awaited: the caller resumes only once every
 |                          handler has finished. Used where the emitting
 |                          statement's ordering matters.
 |
 +-- publishBackpressured() pooled: work items queue and a fixed worker set
                            drains them. Bounds concurrent handler bodies
                            under recursive fan-out (observer -> store ->
                            observer -> ...).
```

Repository observers use `publishAndTrack` by default, so `Store` does not return until observers have run. Setting `ARO_ASYNC_OBSERVERS` switches them to the pooled path, which **changes ordering**: `Store` returns before its observers complete. It is opt-in for exactly that reason.

### Quiescence and shutdown

The runtime tracks in-flight handlers and pending publishes. `awaitPendingEvents` waits for the whole cascade to drain — including events emitted *by* handlers — with a default timeout of 10 seconds, after which it warns and continues. This is what makes `Keepalive` shutdown orderly: on SIGINT/SIGTERM the runtime stops accepting new work, drains, then runs `Application-End`.

## 8. Shared State

Local bindings are immutable and per-execution, so the only ways two concurrent executions can interact are:

| Surface | Isolation |
|---|---|
| Repositories | Actor-isolated. Each `Store`, `Retrieve`, `Update`, `Delete` is atomic with respect to other operations. |
| Published symbols (`Publish as`) | Actor-isolated global registry. |
| Event bus | Actor. |
| External I/O (files, sockets, HTTP) | Not isolated by ARO — the OS's semantics apply. |

"Atomic per operation" is the whole guarantee. There are no multi-statement transactions: a read-then-write across two statements can interleave with another execution doing the same, and ARO provides no lock to prevent it. Where that matters, model the state transition as a single action — `Accept` for state machines (ARO-0022) — rather than as read-modify-write.

## 9. Interpreter and Compiled Binaries

Both modes share one runtime. `aro build` emits LLVM IR that calls the same Swift implementations through the C ABI, including the loop constructs (`aro_parallel_for_each_execute`), so the semantics in this document apply unchanged to compiled output.

Compiled mode adds two bounds that the interpreter does not need, because compiled handlers block real threads rather than suspending:

- A **global execution gate** of `4 × CPU count` concurrent compiled executions. A blocked action yields its slot, so waiting on I/O does not consume gate capacity.
- A **per-loop limit** of 2 in-flight iterations for `parallel for each`, released on iteration completion rather than on yield, which bounds total threads under recursive event chains (branching factor B, depth D would otherwise grow as B^D).

The consequence: a compiled `parallel for each` is more conservatively bounded than the interpreted one, and statement overlap yields a smaller (still real) win — 2.85s versus 2.14s on the two-request measurement above. Both produce the same results; only throughput differs.

Compiled binaries reach the same model through the C ABI: a deferred action returns a handle, the value accessors materialize it on access, and the code generator emits a drain at each feature set's exit so unread work still runs and its failures still reach the error path.

## 10. Configuration and Diagnostics

| Variable | Default | Effect |
|---|---|---|
| `ARO_ASYNC_OBSERVERS` | off | Route repository observers through the bounded pool. **Changes ordering** — see §6. |
| `ARO_OBSERVER_WORKERS` | `max(4, cores × 2)` | Worker count for the pooled path. |
| `ARO_OBSERVER_QUEUE_CAPACITY` | 4096 | Queued work ceiling; producers suspend when full. |
| `ARO_FORCE_WARN_SECONDS` | 5 | Warn when a read blocks this long on a pending value. `0` disables. |
| `ARO_HTTP_CONCURRENCY` | 8 | Concurrent outbound HTTP requests. |
| `ARO_STREAM_PREFETCH` | 2 | How far a stream's producer may run ahead of its consumer (§12). |
| `ARO_NO_DEFER` | off | Run every action at its statement, as the runtime did before this proposal. An escape hatch for diagnosis: if a program's behaviour changes with it set, overlap is involved. |

Slow-force warnings name the binding and its source location, which is usually enough to identify the statement responsible for a stall.

## 11. What ARO Does Not Expose

ARO has no surface syntax for:

- `async` / `await`
- explicit futures or promises
- thread or task creation
- locks, mutexes, semaphores, condition variables
- channels
- race / all / any combinators

The runtime uses all of these internally. The distinction that matters is between the **language surface**, which offers exactly one concurrency construct (`parallel for each`), and the **runtime**, which is an ordinary concurrent Swift program. Earlier specification text conflated the two and claimed ARO "has no actors" while the event bus was one.

## 12. Streams

A streaming pipeline is sequential *per element* — one element flows through every stage before the next starts — but the producer and consumer overlap: while the loop body works on the current element, the source is already reading and parsing the next ones.

The overlap is bounded by a prefetch window (default 2, `ARO_STREAM_PREFETCH`). A bounded hand-off is the point: `AsyncThrowingStream`'s default policy buffers without limit, and its alternatives *drop* elements — neither is backpressure. With a bounded channel the producer suspends when the window is full and resumes as the consumer drains it, so a fast source cannot outrun a slow body into memory.

The window bounds the hand-off this stage owns. A source that ignores backpressure entirely — an array, a socket pushing as fast as it can — still produces at its own pace upstream; prefetch cannot retrofit backpressure onto a producer that has none.

## 13. Deferral is not Materialization

Two axes that are easy to conflate and are independent:

- **Deferral** (this proposal) is *when* a statement runs. A deferrable action starts at its statement and is waited for at the first read of its result.
- **Materialization** (ARO-0090) is *whether* a value is built at all. A request body that a feature set only moves never becomes a value, so nothing bounds its size; one that a feature set reads does, and `x-aro-max-body` bounds it.

A body binding is not a deferred future. It is a value that happens not to have been read yet, and reading it forces nothing except the bytes themselves. The prefetch window of §12 is what bounds the memory while they flow.

## Summary

| Question | Answer |
|---|---|
| Do statements overlap? | Yes, where independent — a statement starts at its line and is awaited at the first read of its result. |
| Do feature sets overlap? | Yes. Every trigger is an independent execution. |
| How do I ask for parallelism? | `parallel for each`, optionally `with <concurrency: N>`. |
| What is shared? | Repositories and published symbols, both actor-isolated. |
| What is atomic? | A single repository operation. Nothing larger. |
| Does `Emit` block? | No. Handlers run independently; shutdown drains them. |
| Is an unread request body a future? | No — see §13. It is a value not yet built (ARO-0090). |
| Is compiled output different? | Same semantics, tighter concurrency bounds. |
| When does a failure surface? | At the failing statement's identity, reported no later than feature-set exit. |

## Related Proposals

- **ARO-0005 (Application Architecture)** — application lifecycle and the event-driven premise. Its §4 now defers to this document.
- **ARO-0007 (Events & Reactive)** — event declaration, handlers, repository observers.
- **ARO-0002 (Control Flow)** — `for each` iteration, of which `parallel for each` is the concurrent form.
- **ARO-0051 (Streaming Execution)** — streaming pipelines, which are sequential per element.
- **ARO-0022 (State Guards)** — `Accept`, the single-statement state transition referenced in §7.
