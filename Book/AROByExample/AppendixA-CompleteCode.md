# Appendix A: Complete Code

This appendix contains the complete source code for the web crawler, with detailed comments explaining each line.

---

## A.1 openapi.yaml

Event schemas for typed extraction. This file defines the structure of all event data, enabling ARO to validate events at runtime.

```yaml
openapi: 3.0.3
info:
  title: ARO Crawler Events
  version: 1.0.0
  description: Event schemas for the ARO web crawler application

# No HTTP paths - this is an event-driven application
paths: {}

components:
  schemas:
    # CrawlPage event: triggers page fetching
    CrawlPageEvent:
      type: object
      required:
        - url
        - base
      properties:
        url:
          type: string
          description: The URL to crawl
        base:
          type: string
          description: The base domain for filtering

    # SavePage event: triggers file storage
    SavePageEvent:
      type: object
      required:
        - url
        - title
        - content
      properties:
        url:
          type: string
          description: The page URL
        title:
          type: string
          description: The page title
        content:
          type: string
          description: The markdown content
        base:
          type: string
          description: The base domain

    # ExtractLinks event: triggers link extraction
    ExtractLinksEvent:
      type: object
      required:
        - url
        - html
      properties:
        url:
          type: string
          description: The source page URL
        html:
          type: string
          description: The raw HTML content
        base:
          type: string
          description: The base domain for filtering

    # NormalizeUrl event: triggers URL normalization
    NormalizeUrlEvent:
      type: object
      required:
        - raw
        - source
        - base
      properties:
        raw:
          type: string
          description: The raw href value
        source:
          type: string
          description: The source page URL
        base:
          type: string
          description: The base domain

    # FilterUrl event: triggers URL filtering
    FilterUrlEvent:
      type: object
      required:
        - url
        - base
      properties:
        url:
          type: string
          description: The normalized URL
        base:
          type: string
          description: The base domain for filtering

    # QueueUrl event: triggers URL queuing
    QueueUrlEvent:
      type: object
      required:
        - url
        - base
      properties:
        url:
          type: string
          description: The URL to queue
        base:
          type: string
          description: The base domain

    # CrawlRequest: stored in repository
    CrawlRequest:
      type: object
      required:
        - id
        - url
        - base
      properties:
        id:
          type: string
          description: Hash of URL for deduplication
        url:
          type: string
          description: The URL to crawl
        base:
          type: string
          description: The base domain
```

---

## A.2 main.aro

The application entry point. Reads the starting URL and kicks off the crawl.

```aro
(* ============================================================
   ARO Web Crawler - Application Entry Point

   Reads CRAWL_URL from environment and starts the crawl process.
   ============================================================ *)

(Application-Start: Web Crawler) {
    Log "Starting Web Crawler..." to the <console>.

    (* Read starting URL from environment *)
    Extract the <start-url> from the <env: CRAWL_URL>.

    Log "Starting URL: ${<start-url>}" to the <console>.

    (* Create output directory *)
    Create the <output-path> with "./output".
    Make the <output-dir> to the <directory: output-path>.
    Log "Output directory created" to the <console>.

    (* Queue initial URL - Emit blocks until the entire crawl chain completes *)
    Emit a <QueueUrl: event> with { url: <start-url>, base: <start-url> }.

    Return an <OK: status> for the <startup>.
}

(Application-End: Success) {
    Log "🥁 Web Crawler completed!" to the <console>.
    Log the <metrics: table> to the <console>.
    Return an <OK: status> for the <shutdown>.
}
```

---

## A.3 crawler.aro

The core crawling logic. Fetches pages and triggers downstream processing.

```aro
(* ============================================================
   ARO Web Crawler - Crawl Logic

   Handles the CrawlPage event to fetch URLs, track crawled pages,
   and trigger link extraction.
   ============================================================ *)

(Crawl Page: CrawlPage Handler) {
    (* Typed event extraction - validates against CrawlPageEvent schema *)
    Extract the <event-data: CrawlPageEvent> from the <event>.

    Log "Crawling: ${<event-data: url>}" to the <console>.

    (* Fetch the page *)
    Request the <response> from the <event-data: url>.
    Extract the <html> from the <response: body>.

    (* Extract markdown content from HTML using ParseHtml action *)
    ParseHtml the <markdown-result: markdown> from the <html>.
    Extract the <title> from the <markdown-result: title>.
    Extract the <markdown-content> from the <markdown-result: markdown>.

    (* Save the markdown content to file *)
    Emit a <SavePage: event> with { url: <event-data: url>, title: <title>, content: <markdown-content>, base: <event-data: base> }.

    (* Extract links from the HTML *)
    Emit a <ExtractLinks: event> with { url: <event-data: url>, html: <html>, base: <event-data: base> }.

    Return an <OK: status> for the <crawl>.
}
```

---

## A.4 links.aro

Link extraction, normalization, filtering, and queuing.

```aro
(* ============================================================
   ARO Web Crawler - Link Extraction using ParseHtml Action

   Uses the built-in ParseHtml action for proper HTML parsing.
   ============================================================ *)

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

(Normalize URL: NormalizeUrl Handler) {
    (* Extract fields directly from the event *)
    Extract the <raw-url> from the <event: raw>.
    Extract the <source-url> from the <event: source>.
    Extract the <base-domain> from the <event: base>.

    (* Determine URL type and normalize *)
    match <raw-url> {
        case /^https?:\/\// {
            (* Already absolute URL - strip fragment and trailing slash *)
            Split the <frag-parts> from the <raw-url> by /#/.
            Extract the <no-fragment: first> from the <frag-parts>.
            Split the <slash-parts> from the <no-fragment> by /\/+$/.
            Extract the <clean-url: first> from the <slash-parts>.
            Emit a <FilterUrl: event> with { url: <clean-url>, base: <base-domain> }.
        }
        case /^\/$/ {
            (* Just "/" means root - use base domain as-is (no trailing slash) *)
            Emit a <FilterUrl: event> with { url: <base-domain>, base: <base-domain> }.
        }
        case /^\// {
            (* Root-relative URL: prepend base domain, strip fragment and trailing slash *)
            Create the <joined-url> with "${<base-domain>}${<raw-url>}".
            Split the <frag-parts> from the <joined-url> by /#/.
            Extract the <no-fragment: first> from the <frag-parts>.
            Split the <slash-parts> from the <no-fragment> by /\/+$/.
            Extract the <clean-url: first> from the <slash-parts>.
            Emit a <FilterUrl: event> with { url: <clean-url>, base: <base-domain> }.
        }
        case /^(#|mailto:|javascript:|tel:|data:)/ {
            (* Skip fragments and special URLs *)
        }
    }

    Return an <OK: status> for the <normalization>.
}

(Filter URL: FilterUrl Handler) {
    (* Extract fields directly from the event *)
    Extract the <url> from the <event: url>.
    Extract the <base-domain> from the <event: base>.

    (* Filter URLs that belong to the same domain as base-domain *)
    Emit a <QueueUrl: event> with { url: <url>, base: <base-domain> } when <url> contains <base-domain>.

    Return an <OK: status> for the <filter>.
}

(Queue URL: QueueUrl Handler) {
    (* Extract fields directly from the event *)
    Extract the <url> from the <event: url>.
    Extract the <base-domain> from the <event: base>.

    (* Generate deterministic id from URL hash for deduplication *)
    Compute the <url-id: hash> from the <url>.

    (* Store with id - repository deduplicates by id, observer only fires for new entries *)
    Create the <crawl-request> with { id: <url-id>, url: <url>, base: <base-domain> }.
    Store the <crawl-request> into the <crawled-repository>.

    Return an <OK: status> for the <queue>.
}

(Trigger Crawl: crawled-repository Observer) {
    (* React to new entries in the repository *)
    Extract the <crawl-request> from the <event: newValue>.
    Extract the <url> from the <crawl-request: url>.
    Extract the <base-domain> from the <crawl-request: base>.

    Log "Queued: ${<url>}" to the <console>.
    Emit a <CrawlPage: event> with { url: <url>, base: <base-domain> }.

    Return an <OK: status> for the <observer>.
}
```

---

## A.5 storage.aro

File storage handler.

```aro
(* ============================================================
   ARO Web Crawler - File Storage

   Saves crawled pages as Markdown files to the output directory
   with filenames derived from the URL hash.
   ============================================================ *)

(Save Page: SavePage Handler) {
    (* Extract fields directly from the event *)
    Extract the <url> from the <event: url>.
    Extract the <title> from the <event: title>.
    Extract the <content> from the <event: content>.

    (* Use URL hash as filename *)
    Compute the <url-hash: hash> from the <url>.
    Create the <file-path> with "./output/${<url-hash>}.md".

    Log "Saving: ${<url>} to ${<file-path>}" to the <console>.

    (* Format markdown file with frontmatter *)
    Create the <file-content> with "# ${<title>}\n\n**Source:** ${<url>}\n\n---\n\n${<content>}".

    (* Write content to file *)
    Write the <file-content> to the <file: file-path>.

    Return an <OK: status> for the <save>.
}
```

---

## A.6 Summary Statistics

| File | Lines | Handlers | Purpose |
|------|-------|----------|---------|
| openapi.yaml | 127 | — | Event schemas |
| main.aro | 31 | 2 | Application lifecycle |
| crawler.aro | 31 | 1 | Core crawling logic |
| links.aro | 103 | 5 | Link processing pipeline |
| storage.aro | 29 | 1 | File storage |
| **Total** | **194 + 127** | **9** | **Complete web crawler** |

---

## A.7 Event Types Summary

| Event | Emitted By | Handled By | Data |
|-------|------------|------------|------|
| QueueUrl | Application-Start, FilterUrl | Queue URL | url, base |
| CrawlPage | crawled-repository Observer | Crawl Page | url, base |
| SavePage | Crawl Page | Save Page | url, title, content, base |
| ExtractLinks | Crawl Page | Extract Links | url, html, base |
| NormalizeUrl | Extract Links | Normalize URL | raw, source, base |
| FilterUrl | Normalize URL | Filter URL | url, base |
