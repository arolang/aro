# Chapter 6: Link Extraction

*"Finding links is easy. Finding the right links is the challenge."*

---

## What We Will Learn

- Using `<ParseHtml>` to extract links
- The different `ParseHtml` specifiers
- Typed event extraction with OpenAPI schemas (ARO-0046)
- Iterating over collections with `for each`
- Building the link extraction handler

---

## 6.1 The ExtractLinks Handler

After fetching a page, we need to find all the links it contains. The `ExtractLinks` handler receives the raw HTML and emits events for each discovered link.

Our pipeline processes links in stages:

```
ExtractLinks → NormalizeUrl → FilterUrl → QueueUrl → CrawlPage
```

This chapter covers the first stage: extraction.

---

## 6.2 The Architectural Decision

**Our Choice:** Extract links from the raw HTML, not from the converted Markdown.

**Alternative Considered:** We could extract links from Markdown. However, the Markdown conversion might alter or remove some links. HTML gives us the complete picture. Also, the `<ParseHtml>` action has a `links` specifier designed exactly for this purpose.

**Why This Approach:** HTML is the source of truth for links. The `<ParseHtml>` action parses HTML properly, handling edge cases like malformed markup. Using Markdown would require parsing it again and might miss links.

---

## 6.3 ParseHtml Specifiers

The `<ParseHtml>` action supports multiple specifiers:

| Specifier | Returns |
|-----------|---------|
| `markdown` | Object with `title` and `markdown` fields |
| `links` | List of all `href` values from anchor tags |
| `title` | Just the page title |

We have already used `markdown` in the crawl handler. Now we will use `links`:

```aro
<ParseHtml> the <links: links> from the <html>.
```

This returns a list like:
```
["/about", "https://example.com/page", "#section", "mailto:test@example.com"]
```

The list contains raw `href` values—relative paths, absolute URLs, fragments, and special schemes are all included. We will filter these in later stages.

---

## 6.4 Building the Handler

Create `links.aro` with the `ExtractLinks` handler:

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

    <Return> an <OK: status> for the <extraction>.
}
```

The event carries three pieces of data:

- `html` — The raw HTML content to parse
- `url` — The page we fetched (needed for relative URL resolution)
- `base` — The base domain (for filtering)

---

## 6.5 Typed Event Extraction (ARO-0046)

The field-by-field extraction in section 6.4 works well, but ARO provides a more concise alternative: **typed event extraction**. By defining the event structure in your OpenAPI specification, you can extract and validate the entire event in one statement.

### Defining the Event Schema

Add the event schema to your `openapi.yaml`:

```yaml
components:
  schemas:
    ExtractLinksEvent:
      type: object
      required:
        - url
        - html
      properties:
        url:
          type: string
          description: The page URL that was fetched
        html:
          type: string
          description: The raw HTML content
        base:
          type: string
          description: The base domain for filtering
```

### Using Typed Extraction

With the schema defined, the handler becomes:

```aro
(Extract Links: ExtractLinks Handler) {
    <Log> "ExtractLinks handler triggered" to the <console>.

    (* Typed extraction - validates against ExtractLinksEvent schema *)
    <Extract> the <event-data: ExtractLinksEvent> from the <event: data>.

    <Return> an <OK: status> for the <extraction>.
}
```

The PascalCase qualifier `ExtractLinksEvent` tells ARO to:
1. Look up the schema in `components.schemas`
2. Validate the event data against that schema
3. Fail fast if required properties are missing or types don't match

### Accessing Properties

After typed extraction, access properties using the qualifier syntax:

```aro
<ParseHtml> the <links: links> from the <event-data: html>.
<Log> "Processing links from ${<event-data: url>}" to the <console>.
```

### Typed vs Field-by-Field

| Approach | Pros | Cons |
|----------|------|------|
| **Field-by-field** | Explicit, educational | Verbose, no validation |
| **Typed extraction** | Concise, validated | Requires schema definition |

For production code, typed extraction catches errors earlier and provides documentation through the schema. For learning, field-by-field extraction makes the data flow explicit.

---

## 6.6 Extracting Links

Add the link extraction:

```aro
(Extract Links: ExtractLinks Handler) {
    <Log> "ExtractLinks handler triggered" to the <console>.

    <Extract> the <event-data> from the <event: data>.
    <Extract> the <html> from the <event-data: html>.
    <Extract> the <source-url> from the <event-data: url>.
    <Extract> the <base-domain> from the <event-data: base>.

    (* Use ParseHtml action to extract all href attributes from anchor tags *)
    <ParseHtml> the <links: links> from the <html>.
    <Compute> the <link-count: count> from the <links>.
    <Log> "Found ${<link-count>} links" to the <console>.

    <Return> an <OK: status> for the <extraction>.
}
```

We compute the count for logging. On a typical page, you might see "Found 47 links".

---

## 6.7 Iterating with For Each

To process each link, we use `for each`:

```aro
    (* Previous code... *)

    (* Process each extracted link *)
    for each <raw-url> in <links> {
        <Emit> a <NormalizeUrl: event> with {
            raw: <raw-url>,
            source: <source-url>,
            base: <base-domain>
        }.
    }

    <Return> an <OK: status> for the <extraction>.
```

The `for each` loop iterates over the list. For each item, it binds that item to `raw-url` and executes the block.

Note the event data we pass:

- `raw` — The raw href value (like "/about" or "https://...")
- `source` — The page URL (for resolving relative paths)
- `base` — The base domain (passed through for filtering)

---

## 6.8 Parallel Processing Preview

In Chapter 10, we will replace `for each` with `parallel for each`:

```aro
parallel for each <raw-url> in <links> {
    <Emit> a <NormalizeUrl: event> with { ... }.
}
```

This processes links concurrently. For now, sequential processing works fine. We will explore parallelism when we have more handlers to process.

---

## 6.9 The Complete Handler

Here is the complete `ExtractLinks` handler:

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
```

---

## 6.10 What ARO Does Well Here

**Built-in HTML Parsing.** `<ParseHtml>` handles real HTML with all its quirks. We do not need an external library or worry about malformed markup.

**Clean Iteration.** `for each <item> in <list>` reads naturally and handles the mechanics of iteration automatically.

**Separation of Concerns.** This handler does one thing: extract links and emit events. It does not normalize or filter. That is the job of downstream handlers.

---

## 6.11 What Could Be Better

**No Custom Selectors.** We can only extract links. What if we wanted all images? Or specific CSS classes? A more flexible selector system would help.

**No Link Context.** We get the `href` but not the link text or surrounding context. Sometimes that information is useful for deciding what to crawl.

---

## Chapter Recap

- `<ParseHtml> ... links` extracts all href values from anchor tags
- The result is a list of raw strings (relative and absolute URLs, fragments, etc.)
- Typed event extraction (`<Extract> the <data: SchemaName> from <event>`) validates data against OpenAPI schemas
- `for each <item> in <list>` iterates over collections
- We emit a `NormalizeUrl` event for each link, passing through the source and base
- This handler is focused: extract and emit, nothing more

---

*Next: Chapter 7 - URL Normalization*
