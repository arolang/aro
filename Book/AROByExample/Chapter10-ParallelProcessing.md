# Chapter 10: Parallel Processing

*"Why process one link when you can process fifty at once?"*

---

## What We Will Learn

- The difference between sequential and parallel iteration
- Using `parallel for each` for concurrent execution
- How ARO manages concurrency
- When to use parallel vs. sequential processing

---

## 10.1 The Sequential Problem

In Chapter 6, we used `for each` to process links:

```aro
for each <raw-url> in <links> {
    Emit a <NormalizeUrl: event> with { ... }.
}
```

This processes links one at a time. For a page with 100 links, we emit 100 events sequentially. Each event triggers a handler, which might trigger more events, all in sequence.

For I/O-bound work like web crawling, this is inefficient. While waiting for one HTTP request to complete, we could be processing other URLs.

---

## 10.2 The Architectural Decision

**Our Choice:** Process links in parallel using `parallel for each`.

**Alternative Considered:** We could keep sequential processing. It is simpler and easier to debug. However, crawling is I/O-bound—most time is spent waiting for network responses. Parallel processing dramatically improves throughput.

**Why This Approach:** ARO makes parallelism easy. Changing `for each` to `parallel for each` is the only modification needed. The event-driven architecture naturally handles concurrent execution. There are no callbacks, no promises, no async/await—just a keyword change.

---

## 10.3 Parallel For Each

The syntax is simple:

```aro
parallel for each <item> in <list> {
    (* This block runs concurrently *)
}
```

Instead of processing items one by one, ARO runs the block for many items at once. "Many" is not "all": the runtime keeps a bounded number of iterations in flight — four, or four per CPU core, whichever is larger — and starts the next one as each finishes. You can name the bound yourself:

```aro
parallel for each <item> in <list> with <concurrency: 4> {
    (* At most four iterations run at a time *)
}
```

That clause is how you rate-limit a crawler, and we return to it in section 10.10.

---

## 10.4 Updating the Link Extraction Handler

Change the `for each` to `parallel for each` in `links.aro`:

```aro
(Extract Links: ExtractLinks Handler) {
    (* Typed event extraction - validates against ExtractLinksEvent schema *)
    Extract the <event-data: ExtractLinksEvent> from the <event>.

    (* Use ParseHtml action to extract all href attributes from anchor tags *)
    ParseHtml the <links: links> from the <event-data: html>.

    (* Process links in parallel - repository Actor ensures atomic dedup *)
    parallel for each <raw-url> in <links> {
        Emit a <NormalizeUrl: event> with {
            raw: <raw-url>,
            source: <event-data: url>,
            base: <event-data: base>
        }.
    }

    Return an <OK: status> for the <extraction>.
}
```

That is the only change: `for each` becomes `parallel for each`.

---

## 10.5 How ARO Handles Concurrency

When you use `parallel for each`, ARO:

1. Creates a task for each item in the list
2. Keeps up to the concurrency limit of them running at once, starting a new task as each finishes
3. Waits for all tasks to complete before continuing
4. Handles any errors from individual tasks

You do not manage threads, locks, or synchronization. ARO's runtime handles the complexity.

The event bus is also concurrent. When multiple events are emitted simultaneously, their handlers can run in parallel. This creates a natural pipeline where work flows through the system concurrently.

---

## 10.6 Concurrency in Our Crawler

With parallel processing, our crawler works like this:

1. Fetch page A
2. Extract 50 links from page A
3. **Simultaneously** emit 50 NormalizeUrl events
4. **Simultaneously** 50 normalization handlers run
5. **Simultaneously** filtered URLs emit QueueUrl events
6. **Simultaneously** new CrawlPage events are emitted
7. **Simultaneously** multiple pages are fetched

The entire pipeline runs concurrently. While one page is being fetched, others are being parsed, links are being normalized, and files are being written.

---

## 10.7 When to Use Parallel Processing

Use `parallel for each` when:

- Items are independent (processing one does not affect another)
- Work is I/O-bound (network, disk, external services)
- Order does not matter

Use sequential `for each` when:

- Items depend on each other
- Order matters
- You need to limit concurrent operations

For our crawler, links are independent, crawling is I/O-bound, and order does not matter. Parallel processing is ideal.

---

## 10.8 Potential Issues

Parallel processing is powerful but has considerations:

**Resource Limits.** Too many concurrent requests can overwhelm the target server. The loop's own bound (four per core by default) keeps the *process* healthy, but it is not a politeness budget — each iteration only emits an event, and the handlers those events wake up are not covered by it. Our crawler can still have far more HTTP requests in flight than the loop has iterations.

**Non-Deterministic Order.** With parallel execution, you cannot predict which task finishes first. Log output may appear in any order.

**Shared State.** If parallel tasks access shared state, you need to be careful about race conditions. Our crawler's repository operations are safe because the repository Actor serializes concurrent access, and the `<Store>` action's `new-entry` binding provides atomic check-and-store, ensuring race-safe deduplication even under `parallel for each`.

---

## 10.9 What ARO Does Well Here

**Trivial Parallelism.** One keyword change enables concurrent execution. No threads, no async/await, no promises.

**Safe by Default.** ARO's event-driven model and immutable data flow make parallel execution safe. You do not worry about locks or race conditions.

**Natural Scaling.** The same code works for 10 links or 10,000 links. ARO manages the parallelism.

---

## 10.10 What Could Be Better

**Concurrency Limits Bound Loops, Not Pipelines.** `with <concurrency: N>` caps one loop. It does not cap the event bus, so a crawler whose loop emits at four-at-a-time can still be fetching fifty pages, because each emit hands off to a handler and returns. There is no application-wide "at most N HTTP requests in flight" setting. The honest way to slow a crawler down today is a `<Sleep>` in the fetch handler:

```aro
Sleep the <pause> for 500ms.
```

**No Progress Tracking.** With many parallel tasks, there is no built-in way to track progress or know how many are complete. The `<metrics: table>` we print at shutdown tells you what happened, not what is happening.

**Debugging Is Sequential.** `aro debug` steps one statement at a time, which is exactly the wrong shape for a race. `aro run --record events.json` is the better tool here: it captures the event order so you can look at what actually interleaved after the fact.

---

## Chapter Recap

- `parallel for each` processes items concurrently
- Change from sequential to parallel is a single keyword
- ARO handles thread management and synchronization
- Use parallel for independent, I/O-bound operations
- Our crawler now fetches, parses, and processes concurrently

---

*Next: Chapter 11 - Set Operations*
