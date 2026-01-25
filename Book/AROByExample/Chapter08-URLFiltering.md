# Chapter 8: URL Filtering

*"A good crawler knows what not to crawl."*

---

## What We Will Learn

- Conditional execution with `when` guards
- String containment checks
- Domain filtering to stay on-site
- The final filtering handler

---

## 8.1 Why Filter?

If we followed every link we found, our crawler would quickly leave the starting site and wander across the entire internet. We need to filter URLs to:

1. Stay within the original domain
2. Avoid crawling external sites
3. Focus on the content we actually want

The `FilterUrl` handler decides which URLs proceed to the queue.

---

## 8.2 The Architectural Decision

**Our Choice:** Filter by domain substring match.

**Alternative Considered:** We could use more sophisticated filtering: robots.txt compliance, URL patterns, depth limits, or content type checks. For this example, domain filtering is sufficient and demonstrates the key ARO patterns.

**Why This Approach:** Domain containment is simple and effective. If the URL contains the base domain, it is on-site. This catches most cases without complex logic. A production crawler would add more rules, but the pattern remains the same.

---

## 8.3 The When Guard

ARO has a powerful construct for conditional execution: the `when` guard.

```aro
<Emit> a <SomeEvent: event> with <data> when <condition>.
```

The action only executes if the condition is true. This is not an if/else—there is no else branch. If the condition is false, the statement is simply skipped.

Guards can use various conditions:

```aro
(* String containment *)
<Action> ... when <string> contains <substring>.

(* Numeric comparison *)
<Action> ... when <count> > 0.

(* Equality *)
<Action> ... when <status> = "active".
```

---

## 8.4 Building the Filter Handler

Add to `links.aro`:

```aro
(Filter URL: FilterUrl Handler) {
    (* Extract from event data structure *)
    <Extract> the <event-data> from the <event: data>.
    <Extract> the <url> from the <event-data: url>.
    <Extract> the <base-domain> from the <event-data: base>.

    <Return> an <OK: status> for the <filter>.
}
```

The event carries just two things:

- `url` — The normalized absolute URL
- `base` — The base domain to match against

---

## 8.5 Applying the Filter

Now add the conditional emit:

```aro
(Filter URL: FilterUrl Handler) {
    (* Extract from event data structure *)
    <Extract> the <event-data> from the <event: data>.
    <Extract> the <url> from the <event-data: url>.
    <Extract> the <base-domain> from the <event-data: base>.

    (* Filter URLs that belong to the same domain as base-domain *)
    <Log> "Queuing: ${<url>}" to the <console> when <url> contains <base-domain>.
    <Emit> a <QueueUrl: event> with { url: <url>, base: <base-domain> } when <url> contains <base-domain>.

    <Return> an <OK: status> for the <filter>.
}
```

Both the log and the emit have `when <url> contains <base-domain>` guards. If the URL contains the base domain, both execute. If not, both are skipped.

For example, if `base-domain` is `https://example.com`:

- `https://example.com/page` — Contains base, passes
- `https://example.com/docs/api` — Contains base, passes
- `https://other-site.com/page` — Does not contain base, filtered

---

## 8.6 How Contains Works

The `contains` check is a simple substring match. This works for domain filtering because:

- All our URLs are absolute (thanks to normalization)
- The base domain appears at the start of same-site URLs
- External URLs have different domains, no substring match

However, there are edge cases. `https://example.com.malicious.com` would match because it contains `example.com`. For a tutorial crawler, this is acceptable. A production crawler would use proper URL parsing.

---

## 8.7 The Complete Handler

```aro
(Filter URL: FilterUrl Handler) {
    (* Extract from event data structure *)
    <Extract> the <event-data> from the <event: data>.
    <Extract> the <url> from the <event-data: url>.
    <Extract> the <base-domain> from the <event-data: base>.

    (* Filter URLs that belong to the same domain as base-domain *)
    <Log> "Queuing: ${<url>}" to the <console> when <url> contains <base-domain>.
    <Emit> a <QueueUrl: event> with { url: <url>, base: <base-domain> } when <url> contains <base-domain>.

    <Return> an <OK: status> for the <filter>.
}
```

This is a short handler. It does one thing: check the domain and conditionally emit. The `when` guard makes the intent clear.

---

## 8.8 The Queue Handler

The final handler in the link pipeline queues URLs for crawling. Add to `links.aro`:

```aro
(Queue URL: QueueUrl Handler) {
    (* Extract from event data structure *)
    <Extract> the <event-data> from the <event: data>.
    <Extract> the <url> from the <event-data: url>.
    <Extract> the <base-domain> from the <event-data: base>.

    (* Check if already crawled *)
    <Retrieve> the <crawled-urls> from the <crawled-repository>.
    <Create> the <single-url-list> with [<url>].
    <Compute> the <uncrawled-urls: difference> from <single-url-list> with <crawled-urls>.
    <Compute> the <uncrawled-count: count> from <uncrawled-urls>.

    (* Only queue if not already crawled *)
    <Log> "Queued: ${<url>}" to the <console> when <uncrawled-count> > 0.
    <Emit> a <CrawlPage: event> with { url: <url>, base: <base-domain> } when <uncrawled-count> > 0.

    <Return> an <OK: status> for the <queue>.
}
```

This handler performs a final deduplication check. Even though the crawl handler also checks, URLs can arrive here from multiple sources. The double-check ensures no duplicates.

The `when <uncrawled-count> > 0` guard only emits if the URL has not been crawled.

---

## 8.9 The Complete links.aro

We now have four handlers in `links.aro`. Here is the complete file:

```aro
(* ============================================================
   ARO Web Crawler - Link Extraction using ParseHtml Action

   Uses the built-in ParseHtml action for proper HTML parsing.
   ============================================================ *)

(Extract Links: ExtractLinks Handler) {
    <Log> "ExtractLinks handler triggered" to the <console>.

    (* Extract from event data structure *)
    <Extract> the <event-data> from the <event: data>.
    <Extract> the <html> from the <event-data: html>.
    <Extract> the <source-url> from the <event-data: url>.
    <Extract> the <base-domain> from the <event-data: base>.

    (* Use ParseHtml action to extract all href attributes from anchor tags *)
    <ParseHtml> the <links: links> from the <html>.
    <Compute> the <link-count: count> from the <links>.
    <Log> "Found ${<link-count>} links" to the <console>.

    (* Process each extracted link using for each *)
    for each <raw-url> in <links> {
        <Emit> a <NormalizeUrl: event> with {
            raw: <raw-url>,
            source: <source-url>,
            base: <base-domain>
        }.
    }

    <Return> an <OK: status> for the <extraction>.
}

(Normalize URL: NormalizeUrl Handler) {
    (* Extract from event data structure *)
    <Extract> the <event-data> from the <event: data>.
    <Extract> the <raw-url> from the <event-data: raw>.
    <Extract> the <source-url> from the <event-data: source>.
    <Extract> the <base-domain> from the <event-data: base>.

    (* Determine URL type and normalize *)
    match <raw-url> {
        case /^https?:\/\// {
            (* Already absolute URL *)
            <Emit> a <FilterUrl: event> with { url: <raw-url>, base: <base-domain> }.
        }
        case /^\/$/ {
            (* Just "/" means root - use base domain as-is *)
            <Emit> a <FilterUrl: event> with { url: <base-domain>, base: <base-domain> }.
        }
        case /^\// {
            (* Root-relative URL: prepend base domain *)
            <Create> the <absolute-url> with "${<base-domain>}${<raw-url>}".
            <Emit> a <FilterUrl: event> with { url: <absolute-url>, base: <base-domain> }.
        }
        case /^(#|mailto:|javascript:|tel:|data:)/ {
            (* Skip fragments and special URLs *)
        }
    }

    <Return> an <OK: status> for the <normalization>.
}

(Filter URL: FilterUrl Handler) {
    (* Extract from event data structure *)
    <Extract> the <event-data> from the <event: data>.
    <Extract> the <url> from the <event-data: url>.
    <Extract> the <base-domain> from the <event-data: base>.

    (* Filter URLs that belong to the same domain as base-domain *)
    <Log> "Queuing: ${<url>}" to the <console> when <url> contains <base-domain>.
    <Emit> a <QueueUrl: event> with { url: <url>, base: <base-domain> } when <url> contains <base-domain>.

    <Return> an <OK: status> for the <filter>.
}

(Queue URL: QueueUrl Handler) {
    (* Extract from event data structure *)
    <Extract> the <event-data> from the <event: data>.
    <Extract> the <url> from the <event-data: url>.
    <Extract> the <base-domain> from the <event-data: base>.

    (* Check if already crawled *)
    <Retrieve> the <crawled-urls> from the <crawled-repository>.
    <Create> the <single-url-list> with [<url>].
    <Compute> the <uncrawled-urls: difference> from <single-url-list> with <crawled-urls>.
    <Compute> the <uncrawled-count: count> from <uncrawled-urls>.

    (* Only queue if not already crawled *)
    <Log> "Queued: ${<url>}" to the <console> when <uncrawled-count> > 0.
    <Emit> a <CrawlPage: event> with { url: <url>, base: <base-domain> } when <uncrawled-count> > 0.

    <Return> an <OK: status> for the <queue>.
}
```

---

## 8.10 What ARO Does Well Here

**Readable Guards.** `when <url> contains <base-domain>` reads like English. The intent is immediately clear.

**Flexible Conditions.** Guards work with containment, comparison, and equality. You can express most filtering logic.

**No Boilerplate.** No if/else blocks, no boolean variables, no nested conditionals. The guard is part of the action.

---

## 8.11 What Could Be Better

**No Negation.** You cannot write `when not`. To skip certain URLs, you would need a different pattern.

**Limited Comparisons.** String operations are limited to `contains`. Operations like `startsWith` or `endsWith` would be useful.

---

## Chapter Recap

- `when` guards make actions conditional
- `<url> contains <base-domain>` checks for substring match
- Filtered URLs simply do not emit events—no explicit discard
- The queue handler performs a final deduplication check
- Our link pipeline is complete: Extract → Normalize → Filter → Queue

---

*Next: Chapter 9 - Storing Results*
