# Chapter 11: Set Operations

*"Tracking what you have seen is the key to not seeing it twice."*

---

## What We Will Learn

- Why set operations are essential for crawlers
- The `union` operation for combining sets
- The `difference` operation for finding new items
- The `count` operation for checking set size
- How repositories provide persistent state

---

## 11.1 The Deduplication Problem

A web crawler faces a fundamental problem: pages link to each other. Page A links to page B, page B links to page C, and page C links back to page A. Without deduplication, the crawler would loop forever.

We need to track which URLs we have already crawled. Before processing a new URL, we check if it is in the "already crawled" set. If yes, skip it. If no, add it and proceed.

---

## 11.2 The Architectural Decision

**Our Choice:** Use in-memory set operations with a repository for persistence.

**Alternative Considered:** We could use a database for tracking crawled URLs. This would persist across restarts and scale to massive crawls. However, for a tutorial crawler, in-memory is simpler and demonstrates ARO's set operations effectively.

**Why This Approach:** ARO has built-in set operations that are perfect for this task. Repositories persist data across handler executions within a single run. The code is clean and the pattern is reusable for other deduplication needs.

---

## 11.3 Set Operations in ARO

ARO provides three key set operations through `<Compute>`:

| Operation | Syntax | Result |
|-----------|--------|--------|
| `union` | `Compute the <result: union> from <set-a> with <set-b>.` | All items from both sets |
| `difference` | `Compute the <result: difference> from <set-a> with <set-b>.` | Items in set-a but not in set-b |
| `count` | `Compute the <result: count> from <set>.` | Number of items |

These operations treat lists as sets—duplicate items within a list are considered once.

---

## 11.4 The Union Operation

Union combines two sets:

```aro
Create the <set-a> with ["apple", "banana"].
Create the <set-b> with ["banana", "cherry"].
Compute the <combined: union> from <set-a> with <set-b>.
(* combined = ["apple", "banana", "cherry"] *)
```

In our crawler, we use union to add new URLs to the crawled set:

```aro
Compute the <updated-crawled: union> from <crawled-urls> with <single-url-list>.
```

This adds the new URL to the existing set of crawled URLs.

---

## 11.5 The Difference Operation

Difference finds items in one set but not another:

```aro
Create the <all-urls> with ["a", "b", "c"].
Create the <crawled> with ["a", "c"].
Compute the <uncrawled: difference> from <all-urls> with <crawled>.
(* uncrawled = ["b"] *)
```

In our crawler, we use difference to check if a URL is new:

```aro
Create the <single-url-list> with [<url>].
Compute the <new-urls: difference> from <single-url-list> with <crawled-urls>.
Compute the <new-url-count: count> from <new-urls>.
```

If `new-url-count` is 0, the URL is already in `crawled-urls`. If it is 1, the URL is new.

---

## 11.6 Repositories for Persistence

Handlers are stateless—they execute and end. To persist data across handler executions, we use **repositories**.

```aro
(* Store data *)
Store the <value> into the <repository-name>.

(* Retrieve data *)
Retrieve the <value> from the <repository-name>.
```

Repository names are arbitrary identifiers. In our crawler, we use `crawled-repository` to store the set of crawled URLs.

Repositories are:

- **In-memory** — Data is lost when the application stops
- **Shared** — All handlers can access the same repository
- **Persistent within a run** — Data survives across handler executions

---

## 11.7 The Deduplication Pattern

### General-Purpose Approach: Retrieve / Difference / Union

The set operations from Sections 11.4 and 11.5 can be combined into a general-purpose deduplication pattern. This approach works for any scenario where you need to compare collections:

```aro
(* 1. Retrieve the current set *)
Retrieve the <crawled-urls> from the <crawled-repository>.

(* 2. Wrap the new URL in a list *)
Create the <single-url-list> with [<url>].

(* 3. Check if it's new *)
Compute the <new-urls: difference> from <single-url-list> with <crawled-urls>.
Compute the <new-url-count: count> from <new-urls>.

(* 4. If count is 0, URL is already crawled *)
match <new-url-count> {
    case 0 {
        Return an <OK: status> for the <skip>.
    }
}

(* 5. Add URL to crawled set *)
Compute the <updated-crawled: union> from <crawled-urls> with <single-url-list>.
Store the <updated-crawled> into the <crawled-repository>.

(* 6. Proceed with crawling *)
```

This pattern is flexible and works well when you need to compare arbitrary sets, compute differences, or build up collections over time. However, for the common case of "store a value and check if it was new," ARO offers a simpler approach.

### Simpler Approach: Atomic Store with `new-entry` Binding

When `<Store>` stores a plain value (not a collection) into a repository, the runtime automatically binds `new-entry` to the execution context:

- `new-entry = 1` — the value was newly stored (it did not exist before)
- `new-entry = 0` — the value is a duplicate (it was already in the repository)

This eliminates the need for Retrieve, difference, and union entirely. The repository Actor serializes all concurrent `<Store>` calls, so only the first caller for a given value gets `new-entry = 1`. All subsequent callers get `new-entry = 0`, regardless of timing.

Here is the pattern our crawler actually uses:

```aro
(Queue URL: QueueUrl Handler) {
    (* Extract from event data structure *)
    Extract the <event-data> from the <event: data>.
    Extract the <url> from the <event-data: url>.
    Extract the <base-domain> from the <event-data: base>.

    (* Atomic store - the repository Actor serializes concurrent access,
       so only the first caller for a given URL gets is-new-entry = 1 *)
    Store the <url> into the <crawled-repository>.

    (* Only emit CrawlPage if this URL was newly stored *)
    Log "Queued: ${<url>}" to the <console> when <new-entry> > 0.
    Emit a <CrawlPage: event> with { url: <url>, base: <base-domain> } when <new-entry> > 0.

    Return an <OK: status> for the <queue>.
}
```

This is the preferred pattern when deduplication is your goal. One `<Store>` call replaces what previously required five steps (Retrieve, Create, Compute difference, Compute count, match, Compute union, Store).

---

## 11.8 How Atomic Store Eliminates Race Conditions

You might wonder what happens when two handlers try to store the same URL at the same time. Consider this scenario:

1. Page A emits link to `/page-x`
2. Page B also emits link to `/page-x`
3. Both `/page-x` events reach the queue handler simultaneously

With the old Retrieve/difference/union pattern, both handlers could read the same state, both conclude the URL is new, and both emit CrawlPage events — resulting in a duplicate fetch.

The atomic Store with `new-entry` binding eliminates this entirely. The repository is backed by an Actor, which serializes all concurrent `<Store>` calls. Regardless of timing:

- The first caller to reach `<Store>` gets `new-entry = 1` and emits the CrawlPage event
- The second caller gets `new-entry = 0` and the `when <new-entry> > 0` guard prevents the emit

No double-checking is needed. A single `<Store>` in the queue handler is sufficient because the Actor guarantees that only one caller ever sees `new-entry = 1` for a given value.

---

## 11.9 What ARO Does Well Here

**Intuitive Set Operations.** Union and difference are natural ways to think about set manipulation. The syntax is clear and readable.

**Simple Persistence.** Repositories provide state persistence without database setup. For single-run applications, this is perfect.

**Pattern Reusability.** The deduplication pattern works for any scenario: seen items, processed records, handled events.

---

## 11.10 What Could Be Better

**No Persistent Storage.** Repositories are in-memory only. If the crawler crashes, progress is lost. A persistent option would enable resumable crawls.

**Limited Set Operations.** We have union, difference, and count. Operations like intersection, subset checking, or symmetric difference would be useful.

---

## Chapter Recap

- Set operations (`union`, `difference`, `count`) provide general-purpose collection manipulation
- Repositories persist data across handler executions
- The general-purpose deduplication pattern uses Retrieve/difference/union for comparing arbitrary sets
- The atomic `<Store>` with `new-entry` binding provides a simpler pattern for single-value deduplication
- The repository Actor serializes concurrent `<Store>` calls, eliminating race conditions without double-checking
- `new-entry = 1` means newly stored; `new-entry = 0` means duplicate

---

*Next: Chapter 12 - Putting It Together*
