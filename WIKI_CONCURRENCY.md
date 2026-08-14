# Concurrency

ARO runs things at the same time without asking you to say so. This page is the practical version; the specification is [ARO-0088](https://git.ausdertechnik.de/arolang/aro/-/blob/main/Proposals/ARO-0088-concurrency-model.md).

## The one rule

> A statement's action **starts** where it is written.
> The program **waits** for it at the **first read of its result**.

Everything below follows from that.

```aro
(Report: Analytics) {
    Read the <content> from "./big.csv".        (* starts *)
    Compute the <token> from <seed> * 7919.     (* starts — does not wait for the read *)
    Compute the <lines: count> from <content>.  (* waits for the read, here *)
    Log <token> to the <console>.
    Log <lines> to the <console>.
}
```

The file read and the token computation happen together. The wait lands on the statement that actually needs the file. A feature set costs its **critical path**, not the sum of its statements.

Two independent 2-second HTTP requests in one feature set:

| | Time |
|---|---|
| `aro run` | ~2.1s |
| compiled binary | ~2.9s |
| before this model | ~4.2s |

## What overlaps

| | Concurrent? |
|---|---|
| Statements that don't read each other | **Yes** |
| Statements in a chain (`B` reads `A`'s result) | No — you wrote a dependency |
| Effects (`Log`, `Store`, `Emit`, `Send`, `Return`) | No — pinned to their statement, in source order |
| `for each` iterations | No |
| `parallel for each` iterations | Yes, up to the concurrency limit |
| Two feature sets triggered independently | Yes |
| An `Emit` and its handlers | Yes — the emitter continues immediately |
| A stream's producer and its consumer | Yes, bounded by the prefetch window |

## Getting more concurrency

If statements form a chain, the runtime cannot overlap them — that is your program's shape, not a limitation. Three ways to widen it:

**Collect the work, then fan out.**

```aro
parallel for each <url> in <urls> with <concurrency: 8> {
    Request the <page> from <url>.
    Store the <page> into the <page-repository>.
}
```

**Move slow follow-up work out of the request.** `Emit` an event and handle it elsewhere; the emitter continues immediately.

**Read late.** The wait happens at the first read, so reading a result only where you actually need it gives the runtime more room.

## Things worth knowing

**`Sleep` still sleeps.** It does not defer — the delay *is* the effect. `Sleep` followed by an unrelated `Log` still pauses.

**Effects stay in order.** A series of `Log` lines prints as written, even when the values came from statements that ran concurrently.

**Errors can be reported after later output.** A failure surfaces at the read of its result, and it names the statement that *caused* it. But `Log` statements between the failing statement and that read will already have printed. If an error looks like it arrived "late", this is why.

**Repository operations are atomic one at a time.** There are no multi-statement transactions. A read-then-write across two statements can interleave with another execution doing the same. Model the transition as a single action (`Accept`, ARO-0022) where that matters.

## Which actions defer

Value-producing ones:

- **Reads** — `Retrieve`, `Fetch`, `Read`, `Request`, `Load`, `Find`, `Probe`, `Receive`, `Extract`, `Parse`, `Get`
- **Transformations** — `Compute`, `Calculate`, `Derive`, `Transform`, `Create`, `Build`, `Construct`, `Filter`, `Map`, `Reduce`, `Aggregate`, `Split`, `Group`, `Sort`, `Merge`, `Combine`, `Join`, `Concat`, `Format`

Everything else runs at its statement — all effects, service lifecycle (`Start`, `Stop`, `Connect`, `Close`, `Keepalive`), branch consumers (`Compare`, `Validate`, `Accept`), the terminal painters (`Render`, `Repaint`), and the test verbs.

## Environment variables

| Variable | Default | Effect |
|---|---|---|
| `ARO_NO_DEFER` | off | Run every action at its statement, as before ARO-0088. Escape hatch for diagnosing order-related behaviour. |
| `ARO_STREAM_PREFETCH` | 2 | How far a stream's producer may run ahead of its consumer. |
| `ARO_FORCE_WARN_SECONDS` | 5 | Warn when a read blocks this long on a pending result. `0` disables. |
| `ARO_HTTP_CONCURRENCY` | 8 | Concurrent outbound HTTP requests. |
| `ARO_ASYNC_OBSERVERS` | off | Route repository observers through a bounded pool. **Changes ordering** — `Store` no longer waits for observers. |
| `ARO_OBSERVER_WORKERS` | cores × 2 | Worker count for that pool. |

## Debugging

If something looks order-dependent, run it with `ARO_NO_DEFER=1`. If the behaviour changes, overlap is involved; if it doesn't, look elsewhere. Slow-force warnings name the binding and its source location, which usually identifies the statement responsible for a stall.

## See also

- [ARO-0088 Concurrency Model](https://git.ausdertechnik.de/arolang/aro/-/blob/main/Proposals/ARO-0088-concurrency-model.md) — the specification
- [ARO-0007 Events & Reactive](https://git.ausdertechnik.de/arolang/aro/-/blob/main/Proposals/ARO-0007-events-reactive.md) — event dispatch
- [ARO-0051 Streaming Execution](https://git.ausdertechnik.de/arolang/aro/-/blob/main/Proposals/ARO-0051-streaming-execution.md) — streaming pipelines
