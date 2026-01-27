# Chapter 5: Fetching Pages

*"The heart of a crawler is fetching and parsing."*

---

## What We Will Learn

- Handling the `CrawlPage` event
- Making HTTP requests with `<Request>`
- Parsing HTML to Markdown with `<ParseHtml>`
- Emitting downstream events for saving and link extraction
- Building the first part of `crawler.aro`

---

## 5.1 The Crawl Handler's Responsibility

The `CrawlPage` handler is the core of our crawler. It must:

1. Receive the URL from the event
2. Fetch the page content
3. Convert HTML to Markdown
4. Emit events for saving and link extraction

That is the entire job. Notice what is *not* here: deduplication. The `QueueUrl` handler (Chapter 8) ensures that `CrawlPage` only ever receives URLs that have not been crawled before. By the time this handler fires, we know the URL is new. This keeps the handler focused on a single responsibility: fetching and converting.

---

## 5.2 The Architectural Decision

**Our Choice:** Convert HTML to Markdown immediately after fetching.

**Alternative Considered:** We could store raw HTML and convert later. This would let us re-process pages with different conversion settings. However, it doubles storage requirements and adds complexity. For a crawler that produces readable output, immediate conversion is simpler.

**Why This Approach:** Markdown is our final format. Converting early means we handle HTML only once, in one place. The `<ParseHtml>` action does the heavy lifting, so the code stays clean.

---

## 5.3 Starting the Handler

Create `crawler.aro` with the basic handler structure:

```aro
(* ============================================================
   ARO Web Crawler - Crawl Logic

   Handles the CrawlPage event to fetch URLs and trigger
   link extraction.
   ============================================================ *)

(Crawl Page: CrawlPage Handler) {
    <Return> an <OK: status> for the <crawl>.
}
```

Run the application:

```bash
CRAWL_URL="https://example.com" aro run .
```

You should see the handler trigger. Now let us add the real logic.

---

## 5.4 Extracting Event Data

Add extraction of the URL and base domain:

```aro
(Crawl Page: CrawlPage Handler) {
    (* Extract from event data *)
    <Extract> the <event-data> from the <event: data>.
    <Extract> the <url> from the <event-data: url>.
    <Extract> the <base-domain> from the <event-data: base>.

    <Log> "Crawling: ${<url>}" to the <console>.

    <Return> an <OK: status> for the <crawl>.
}
```

The event data has two fields: `url` (the page to fetch) and `base` (the domain we started with, for filtering). We log the URL so we can see the crawler's progress.

---

## 5.5 Fetching the Page

Now we fetch the actual content:

```aro
    (* Previous code... *)

    (* Fetch the page *)
    <Request> the <html> from the <url>.
```

`<Request>` makes an HTTP GET request and returns the response body. It is that simple. ARO handles redirects, HTTPS, and common errors automatically.

---

## 5.6 Parsing HTML to Markdown

The `<ParseHtml>` action converts HTML to structured data:

```aro
    (* Previous code... *)

    (* Extract markdown content from HTML using ParseHtml action *)
    <ParseHtml> the <markdown-result: markdown> from the <html>.
    <Extract> the <title> from the <markdown-result: title>.
    <Extract> the <markdown-content> from the <markdown-result: markdown>.
```

The `<ParseHtml>` action with the `markdown` specifier returns an object containing:

- `title` -- The page title from `<title>` tag
- `markdown` -- The body content converted to Markdown

We extract both for saving.

---

## 5.7 Emitting Downstream Events

Finally, we emit events for the next stages:

```aro
    (* Previous code... *)

    (* Save the markdown content to file *)
    <Emit> a <SavePage: event> with { url: <url>, title: <title>, content: <markdown-content>, base: <base-domain> }.

    (* Extract links from the HTML *)
    <Emit> a <ExtractLinks: event> with { url: <url>, html: <html>, base: <base-domain> }.

    <Return> an <OK: status> for the <crawl>.
```

We emit two events:

- `SavePage` -- To save the Markdown content to a file
- `ExtractLinks` -- To find links in the original HTML

Note that we pass `html` (not `markdown-content`) to `ExtractLinks`. Links are easier to extract from HTML than Markdown.

---

## 5.8 The Complete crawler.aro (Part 1)

Here is everything we have built:

```aro
(* ============================================================
   ARO Web Crawler - Crawl Logic

   Handles the CrawlPage event to fetch URLs and trigger
   link extraction.
   ============================================================ *)

(Crawl Page: CrawlPage Handler) {
    <Extract> the <event-data> from the <event: data>.
    <Extract> the <url> from the <event-data: url>.
    <Extract> the <base-domain> from the <event-data: base>.
    <Log> "Crawling: ${<url>}" to the <console>.
    <Request> the <html> from the <url>.
    <ParseHtml> the <markdown-result: markdown> from the <html>.
    <Extract> the <title> from the <markdown-result: title>.
    <Extract> the <markdown-content> from the <markdown-result: markdown>.
    <Emit> a <SavePage: event> with { url: <url>, title: <title>, content: <markdown-content>, base: <base-domain> }.
    <Emit> a <ExtractLinks: event> with { url: <url>, html: <html>, base: <base-domain> }.
    <Return> an <OK: status> for the <crawl>.
}
```

Eleven lines. Extract, log, fetch, parse, emit, return. Every line does exactly one thing, and the handler reads like a description of what it does.

---

## 5.9 What ARO Does Well Here

**Simple HTTP.** `<Request> the <html> from the <url>.` -- One line for HTTP GET. No client setup, no promise handling, no error callbacks.

**Built-in HTML Parsing.** The `<ParseHtml>` action handles real-world HTML. It extracts titles, converts content, and produces clean Markdown without external libraries.

**Focused Handler.** Because deduplication is handled upstream by the `QueueUrl` handler (which uses atomic `<Store>` with `new-entry` to guarantee uniqueness), this handler does not need to worry about duplicate URLs. It does one thing: fetch and convert. This is the power of event-driven design -- each handler has a single, clear responsibility.

**Readable Flow.** The entire handler reads top-to-bottom like a description of what it does. There is no branching, no conditional logic, no state management. Just a straight pipeline from event to output.

---

## 5.10 What Could Be Better

**No Request Configuration.** We cannot set timeouts, headers, or authentication. For simple crawling this is fine, but complex scenarios need more control.

**No Retry Logic.** If a request fails, the handler fails. Built-in retry with backoff would make the crawler more robust.

---

## Chapter Recap

- The `CrawlPage` handler is the core of our crawler
- Deduplication is handled upstream by `QueueUrl`, keeping this handler focused
- `<Request>` makes HTTP requests; the response body is returned directly
- `<ParseHtml> ... markdown` converts HTML to Markdown and extracts the title
- We emit `SavePage` and `ExtractLinks` events for downstream handlers
- Event-driven design lets each handler focus on a single responsibility

---

*Next: Chapter 6 - Link Extraction*
