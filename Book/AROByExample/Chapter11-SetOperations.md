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
| `union` | `<Compute> the <result: union> from <set-a> with <set-b>.` | All items from both sets |
| `difference` | `<Compute> the <result: difference> from <set-a> with <set-b>.` | Items in set-a but not in set-b |
| `count` | `<Compute> the <result: count> from <set>.` | Number of items |

These operations treat lists as sets—duplicate items within a list are considered once.

---

## 11.4 The Union Operation

Union combines two sets:

```aro
<Create> the <set-a> with ["apple", "banana"].
<Create> the <set-b> with ["banana", "cherry"].
<Compute> the <combined: union> from <set-a> with <set-b>.
(* combined = ["apple", "banana", "cherry"] *)
```

In our crawler, we use union to add new URLs to the crawled set:

```aro
<Compute> the <updated-crawled: union> from <crawled-urls> with <single-url-list>.
```

This adds the new URL to the existing set of crawled URLs.

---

## 11.5 The Difference Operation

Difference finds items in one set but not another:

```aro
<Create> the <all-urls> with ["a", "b", "c"].
<Create> the <crawled> with ["a", "c"].
<Compute> the <uncrawled: difference> from <all-urls> with <crawled>.
(* uncrawled = ["b"] *)
```

In our crawler, we use difference to check if a URL is new:

```aro
<Create> the <single-url-list> with [<url>].
<Compute> the <new-urls: difference> from <single-url-list> with <crawled-urls>.
<Compute> the <new-url-count: count> from <new-urls>.
```

If `new-url-count` is 0, the URL is already in `crawled-urls`. If it is 1, the URL is new.

---

## 11.6 Repositories for Persistence

Handlers are stateless—they execute and end. To persist data across handler executions, we use **repositories**.

```aro
(* Store data *)
<Store> the <value> into the <repository-name>.

(* Retrieve data *)
<Retrieve> the <value> from the <repository-name>.
```

Repository names are arbitrary identifiers. In our crawler, we use `crawled-repository` to store the set of crawled URLs.

Repositories are:

- **In-memory** — Data is lost when the application stops
- **Shared** — All handlers can access the same repository
- **Persistent within a run** — Data survives across handler executions

---

## 11.7 The Deduplication Pattern

Here is the complete pattern we use in the crawler:

```aro
(* 1. Retrieve the current set *)
<Retrieve> the <crawled-urls> from the <crawled-repository>.

(* 2. Wrap the new URL in a list *)
<Create> the <single-url-list> with [<url>].

(* 3. Check if it's new *)
<Compute> the <new-urls: difference> from <single-url-list> with <crawled-urls>.
<Compute> the <new-url-count: count> from <new-urls>.

(* 4. If count is 0, URL is already crawled *)
match <new-url-count> {
    case 0 {
        <Return> an <OK: status> for the <skip>.
    }
}

(* 5. Add URL to crawled set *)
<Compute> the <updated-crawled: union> from <crawled-urls> with <single-url-list>.
<Store> the <updated-crawled> into the <crawled-repository>.

(* 6. Proceed with crawling *)
```

This pattern appears twice in our crawler: once in the crawl handler (before fetching) and once in the queue handler (before emitting). The double-check handles race conditions in parallel execution.

---

## 11.8 Why Check Twice?

You might wonder why we check in both the crawl handler and the queue handler. With parallel execution, this sequence can happen:

1. Page A emits link to `/page-x`
2. Page B also emits link to `/page-x`
3. Both `/page-x` events reach the queue handler simultaneously
4. Both pass the "not crawled" check
5. Both emit CrawlPage events
6. Page X is fetched twice

By checking in the crawl handler too, we catch these race conditions. The first handler to reach the "mark as crawled" step wins. The second sees the URL is already crawled and skips.

---

## 11.9 What ARO Does Well Here

**Intuitive Set Operations.** Union and difference are natural ways to think about set manipulation. The syntax is clear and readable.

**Simple Persistence.** Repositories provide state persistence without database setup. For single-run applications, this is perfect.

**Pattern Reusability.** The deduplication pattern works for any scenario: seen items, processed records, handled events.

---

## 11.10 What Could Be Better

**No Persistent Storage.** Repositories are in-memory only. If the crawler crashes, progress is lost. A persistent option would enable resumable crawls.

**No Built-in Race Protection.** We handle race conditions manually with double-checking. Atomic "check and add" operations would be cleaner.

**Limited Set Operations.** We have union, difference, and count. Operations like intersection, subset checking, or symmetric difference would be useful.

---

## Chapter Recap

- Set operations are essential for deduplication
- `union` combines sets; `difference` finds unique items
- `count` checks set size (0 means empty)
- Repositories persist data across handler executions
- Double-checking handles parallel execution race conditions
- The deduplication pattern: retrieve, check, update, store

---

*Next: Chapter 12 - Putting It Together*
