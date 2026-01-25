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
    <Emit> a <NormalizeUrl: event> with { ... }.
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
    (* This block runs concurrently for all items *)
}
```

Instead of processing items one by one, ARO processes all items simultaneously. The block executes once per item, but all executions happen in parallel.

---

## 10.4 Updating the Link Extraction Handler

Change the `for each` to `parallel for each` in `links.aro`:

```aro
(Extract Links: ExtractLinks Handler) {
    <Log> "ExtractLinks handler triggered" to the <console>.

    <Extract> the <event-data> from the <event: data>.
    <Extract> the <html> from the <event-data: html>.
    <Extract> the <source-url> from the <event-data: url>.
    <Extract> the <base-domain> from the <event-data: base>.

    <ParseHtml> the <links: links> from the <html>.
    <Compute> the <link-count: count> from the <links>.
    <Log> "Found ${<link-count>} links" to the <console>.

    (* Process each extracted link using parallel for *)
    parallel for each <raw-url> in <links> {
        <Emit> a <NormalizeUrl: event> with {
            raw: <raw-url>,
            source: <source-url>,
            base: <base-domain>
        }.
    }

    <Return> an <OK: status> for the <extraction>.
}
```

That is the only change: `for each` becomes `parallel for each`.

---

## 10.5 How ARO Handles Concurrency

When you use `parallel for each`, ARO:

1. Creates a task for each item in the list
2. Executes all tasks concurrently
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

**Resource Limits.** Too many concurrent requests can overwhelm the target server or exhaust system resources. Our crawler does not limit concurrency—a production crawler would.

**Non-Deterministic Order.** With parallel execution, you cannot predict which task finishes first. Log output may appear in any order.

**Shared State.** If parallel tasks access shared state, you need to be careful about race conditions. Our crawler's repository operations are safe because ARO handles the synchronization.

---

## 10.9 What ARO Does Well Here

**Trivial Parallelism.** One keyword change enables concurrent execution. No threads, no async/await, no promises.

**Safe by Default.** ARO's event-driven model and immutable data flow make parallel execution safe. You do not worry about locks or race conditions.

**Natural Scaling.** The same code works for 10 links or 10,000 links. ARO manages the parallelism.

---

## 10.10 What Could Be Better

**No Concurrency Limits.** You cannot limit how many parallel tasks run. For a web crawler, rate limiting is important to avoid overwhelming servers.

**No Progress Tracking.** With many parallel tasks, there is no built-in way to track progress or know how many are complete.

**Limited Debugging.** Debugging parallel execution is harder than sequential. ARO does not provide tools for tracing concurrent operations.

---

## Chapter Recap

- `parallel for each` processes items concurrently
- Change from sequential to parallel is a single keyword
- ARO handles thread management and synchronization
- Use parallel for independent, I/O-bound operations
- Our crawler now fetches, parses, and processes concurrently

---

*Next: Chapter 11 - Set Operations*
