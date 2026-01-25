# Chapter 5: Fetching Pages

*"The heart of a crawler is fetching and parsing."*

---

## What We Will Learn

- Handling the `CrawlPage` event
- Making HTTP requests with `<Request>`
- Parsing HTML to Markdown with `<ParseHtml>`
- Using the `match` expression for control flow
- Building the first part of `crawler.aro`

---

## 5.1 The Crawl Handler's Responsibility

The `CrawlPage` handler is the core of our crawler. It must:

1. Receive the URL from the event
2. Check if we have already crawled this URL
3. Mark the URL as crawled
4. Fetch the page content
5. Convert HTML to Markdown
6. Emit events for saving and link extraction

This is the largest handler in our application. Let us build it step by step.

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

   Handles the CrawlPage event to fetch URLs, track crawled pages,
   and trigger link extraction.
   ============================================================ *)

(Crawl Page: CrawlPage Handler) {
    <Log> "CrawlPage handler triggered" to the <console>.

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
    <Log> "CrawlPage handler triggered" to the <console>.

    (* Extract from event data *)
    <Extract> the <event-data> from the <event: data>.
    <Extract> the <url> from the <event-data: url>.
    <Extract> the <base-domain> from the <event-data: base>.

    <Log> "Extracted URL: ${<url>}" to the <console>.

    <Return> an <OK: status> for the <crawl>.
}
```

The event data has two fields: `url` (the page to fetch) and `base` (the domain we started with, for filtering).

---

## 5.5 Checking for Duplicates

Before fetching, we check if we have already crawled this URL:

```aro
(Crawl Page: CrawlPage Handler) {
    <Log> "CrawlPage handler triggered" to the <console>.

    <Extract> the <event-data> from the <event: data>.
    <Extract> the <url> from the <event-data: url>.
    <Extract> the <base-domain> from the <event-data: base>.

    <Log> "Extracted URL: ${<url>}" to the <console>.

    (* Check if already crawled *)
    <Retrieve> the <crawled-urls> from the <crawled-repository>.
    <Create> the <single-url-list> with [<url>].
    <Compute> the <new-urls: difference> from <single-url-list> with <crawled-urls>.
    <Compute> the <new-url-count: count> from <new-urls>.

    <Return> an <OK: status> for the <crawl>.
}
```

This uses set operations (covered in detail in Chapter 11):

- `<Retrieve>` gets the list of crawled URLs from the repository
- `<Create>` wraps our URL in a list
- `<Compute> ... difference` finds URLs in the first list but not the second
- `<Compute> ... count` counts how many new URLs there are

If `new-url-count` is 0, we have already crawled this URL.

---

## 5.6 Using Match for Control Flow

ARO does not have if/else. Instead, it uses `match`:

```aro
(Crawl Page: CrawlPage Handler) {
    <Log> "CrawlPage handler triggered" to the <console>.

    <Extract> the <event-data> from the <event: data>.
    <Extract> the <url> from the <event-data: url>.
    <Extract> the <base-domain> from the <event-data: base>.

    <Log> "Extracted URL: ${<url>}" to the <console>.

    <Retrieve> the <crawled-urls> from the <crawled-repository>.
    <Create> the <single-url-list> with [<url>].
    <Compute> the <new-urls: difference> from <single-url-list> with <crawled-urls>.
    <Compute> the <new-url-count: count> from <new-urls>.

    (* Skip if already crawled - use match to check count *)
    match <new-url-count> {
        case 0 {
            <Return> an <OK: status> for the <skip>.
        }
    }

    <Log> "Crawling: ${<url>}" to the <console>.

    <Return> an <OK: status> for the <crawl>.
}
```

The `match` expression checks `new-url-count`. If it is 0, we return early. If it is anything else, execution continues past the match block.

---

## 5.7 Marking the URL as Crawled

Before fetching (to prevent duplicate requests), we mark the URL as crawled:

```aro
    (* Previous code... *)

    <Log> "Crawling: ${<url>}" to the <console>.

    (* Mark URL as crawled before fetching to prevent duplicate requests *)
    <Compute> the <updated-crawled: union> from <crawled-urls> with <single-url-list>.
    <Store> the <updated-crawled> into the <crawled-repository>.
```

The `union` operation combines the existing crawled URLs with our new URL. We store the result back to the repository.

---

## 5.8 Fetching the Page

Now we fetch the actual content:

```aro
    (* Previous code... *)

    (* Fetch the page *)
    <Request> the <html> from the <url>.
    <Compute> the <html-len: length> from the <html>.
    <Log> "Fetched HTML length: ${<html-len>}" to the <console>.
```

`<Request>` makes an HTTP GET request and returns the response body. It is that simple. ARO handles redirects, HTTPS, and common errors automatically.

---

## 5.9 Parsing HTML to Markdown

The `<ParseHtml>` action converts HTML to structured data:

```aro
    (* Previous code... *)

    (* Extract markdown content from HTML using ParseHtml action *)
    <ParseHtml> the <markdown-result: markdown> from the <html>.
    <Extract> the <title> from the <markdown-result: title>.
    <Extract> the <markdown-content> from the <markdown-result: markdown>.
```

The `<ParseHtml>` action with the `markdown` specifier returns an object containing:

- `title` — The page title from `<title>` tag
- `markdown` — The body content converted to Markdown

We extract both for saving.

---

## 5.10 Emitting Downstream Events

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

- `SavePage` — To save the Markdown content to a file
- `ExtractLinks` — To find links in the original HTML

Note that we pass `html` (not `markdown-content`) to `ExtractLinks`. Links are easier to extract from HTML than Markdown.

---

## 5.11 The Complete crawler.aro (Part 1)

Here is everything we have built:

```aro
(* ============================================================
   ARO Web Crawler - Crawl Logic

   Handles the CrawlPage event to fetch URLs, track crawled pages,
   and trigger link extraction.
   ============================================================ *)

(Crawl Page: CrawlPage Handler) {
    <Log> "CrawlPage handler triggered" to the <console>.

    (* Extract from event data *)
    <Extract> the <event-data> from the <event: data>.
    <Extract> the <url> from the <event-data: url>.
    <Extract> the <base-domain> from the <event-data: base>.

    <Log> "Extracted URL: ${<url>}" to the <console>.

    (* Check if already crawled *)
    <Retrieve> the <crawled-urls> from the <crawled-repository>.
    <Create> the <single-url-list> with [<url>].
    <Compute> the <new-urls: difference> from <single-url-list> with <crawled-urls>.
    <Compute> the <new-url-count: count> from <new-urls>.

    (* Skip if already crawled - use match to check count *)
    match <new-url-count> {
        case 0 {
            <Return> an <OK: status> for the <skip>.
        }
    }

    <Log> "Crawling: ${<url>}" to the <console>.

    (* Mark URL as crawled before fetching to prevent duplicate requests *)
    <Compute> the <updated-crawled: union> from <crawled-urls> with <single-url-list>.
    <Store> the <updated-crawled> into the <crawled-repository>.

    (* Fetch the page *)
    <Request> the <html> from the <url>.
    <Compute> the <html-len: length> from the <html>.
    <Log> "Fetched HTML length: ${<html-len>}" to the <console>.

    (* Extract markdown content from HTML using ParseHtml action *)
    <ParseHtml> the <markdown-result: markdown> from the <html>.
    <Extract> the <title> from the <markdown-result: title>.
    <Extract> the <markdown-content> from the <markdown-result: markdown>.

    (* Save the markdown content to file *)
    <Emit> a <SavePage: event> with { url: <url>, title: <title>, content: <markdown-content>, base: <base-domain> }.

    (* Extract links from the HTML *)
    <Emit> a <ExtractLinks: event> with { url: <url>, html: <html>, base: <base-domain> }.

    <Return> an <OK: status> for the <crawl>.
}
```

---

## 5.12 What ARO Does Well Here

**Simple HTTP.** `<Request> the <html> from the <url>.` — One line for HTTP GET. No client setup, no promise handling, no error callbacks.

**Built-in HTML Parsing.** The `<ParseHtml>` action handles real-world HTML. It extracts titles, converts content, and produces clean Markdown without external libraries.

**Readable Flow.** Despite doing a lot (duplicate check, fetch, parse, emit), the code reads top-to-bottom like a description of what it does.

---

## 5.13 What Could Be Better

**No Request Configuration.** We cannot set timeouts, headers, or authentication. For simple crawling this is fine, but complex scenarios need more control.

**No Retry Logic.** If a request fails, the handler fails. Built-in retry with backoff would make the crawler more robust.

**Limited Match.** The `match` expression works but feels awkward for simple "if zero, return" logic. A guard syntax would be cleaner.

---

## Chapter Recap

- The `CrawlPage` handler is the core of our crawler
- `<Request>` makes HTTP requests; response body is returned directly
- `<ParseHtml> ... markdown` converts HTML to Markdown and extracts the title
- `match` provides control flow; we use it to skip already-crawled URLs
- We emit `SavePage` and `ExtractLinks` events for downstream handlers
- Set operations (`difference`, `union`) help with deduplication

---

*Next: Chapter 6 - Link Extraction*
