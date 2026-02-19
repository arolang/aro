# Appendix A: Complete Code

This appendix contains the complete source code for the web crawler, with detailed comments explaining each line.

---

## A.1 main.aro

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
    Return an <OK: status> for the <shutdown>.
}
```

---

## A.2 crawler.aro

The core crawling logic. Fetches pages and triggers downstream processing.

```aro
(* ============================================================
   ARO Web Crawler - Crawl Logic

   Handles the CrawlPage event to fetch URLs, track crawled pages,
   and trigger link extraction.
   ============================================================ *)

(Crawl Page: CrawlPage Handler) {
    (* Extract from event data *)
    Extract the <event-data> from the <event: data>.
    Extract the <url> from the <event-data: url>.
    Extract the <base-domain> from the <event-data: base>.

    Log "Crawling: ${<url>}" to the <console>.

    (* Fetch the page *)
    Request the <html> from the <url>.

    (* Extract markdown content from HTML using ParseHtml action *)
    ParseHtml the <markdown-result: markdown> from the <html>.
    Extract the <title> from the <markdown-result: title>.
    Extract the <markdown-content> from the <markdown-result: markdown>.

    (* Save the markdown content to file *)
    Emit a <SavePage: event> with { url: <url>, title: <title>, content: <markdown-content>, base: <base-domain> }.

    (* Extract links from the HTML *)
    Emit a <ExtractLinks: event> with { url: <url>, html: <html>, base: <base-domain> }.

    Return an <OK: status> for the <crawl>.
}
```

---

## A.3 links.aro

Link extraction, normalization, filtering, and queuing.

```aro
(* ============================================================
   ARO Web Crawler - Link Extraction using ParseHtml Action

   Uses the built-in ParseHtml action for proper HTML parsing.
   ============================================================ *)

(Extract Links: ExtractLinks Handler) {
    (* Extract from event data structure *)
    Extract the <event-data> from the <event: data>.
    Extract the <html> from the <event-data: html>.
    Extract the <source-url> from the <event-data: url>.
    Extract the <base-domain> from the <event-data: base>.

    (* Use ParseHtml action to extract all href attributes from anchor tags *)
    ParseHtml the <links: links> from the <html>.

    (* Process links in parallel - repository Actor ensures atomic dedup *)
    parallel for each <raw-url> in <links> {
        Emit a <NormalizeUrl: event> with {
            raw: <raw-url>,
            source: <source-url>,
            base: <base-domain>
        }.
    }

    Return an <OK: status> for the <extraction>.
}

(Normalize URL: NormalizeUrl Handler) {
    (* Extract from event data structure *)
    Extract the <event-data> from the <event: data>.
    Extract the <raw-url> from the <event-data: raw>.
    Extract the <source-url> from the <event-data: source>.
    Extract the <base-domain> from the <event-data: base>.

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
    (* Extract from event data structure *)
    Extract the <event-data> from the <event: data>.
    Extract the <url> from the <event-data: url>.
    Extract the <base-domain> from the <event-data: base>.

    (* Filter URLs that belong to the same domain as base-domain *)
    Emit a <QueueUrl: event> with { url: <url>, base: <base-domain> } when <url> contains <base-domain>.

    Return an <OK: status> for the <filter>.
}

(Queue URL: QueueUrl Handler) {
    (* Extract from event data structure *)
    Extract the <event-data> from the <event: data>.
    Extract the <url> from the <event-data: url>.
    Extract the <base-domain> from the <event-data: base>.

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

## A.4 storage.aro

File storage handler.

```aro
(* ============================================================
   ARO Web Crawler - File Storage

   This file handles the SavePage event. It:
   - Generates a filename from the URL hash
   - Formats content with metadata
   - Writes the file to the output directory
   ============================================================ *)

(Save Page: SavePage Handler) {
    (* Extract event data *)
    Extract the <event-data> from the <event: data>.
    Extract the <url> from the <event-data: url>.
    Extract the <title> from the <event-data: title>.
    Extract the <content> from the <event-data: content>.

    (* Generate a hash of the URL for the filename.
       Hashes are unique and filesystem-safe.
       The actual URL is preserved in the file content. *)
    Compute the <url-hash: hash> from the <url>.

    (* Build the file path with string interpolation *)
    Create the <file-path> with "./output/${<url-hash>}.md".

    Log "Saving: ${<url>} to ${<file-path>}" to the <console>.

    (* Format the Markdown file with metadata.
       \n creates newlines.
       The file will have:
       - Title as H1
       - Source URL for reference
       - Separator
       - Actual content *)
    Create the <file-content> with "# ${<title>}\n\n**Source:** ${<url>}\n\n---\n\n${<content>}".

    (* Write the content to the file.
       The 'file:' specifier indicates the target is a file path. *)
    Write the <file-content> to the <file: file-path>.

    Return an <OK: status> for the <save>.
}
```

---

## A.5 Summary Statistics

| File | Lines | Handlers | Purpose |
|------|-------|----------|---------|
| main.aro | 30 | 2 | Application lifecycle |
| crawler.aro | 32 | 1 | Core crawling logic |
| links.aro | 105 | 5 | Link processing pipeline |
| storage.aro | 28 | 1 | File storage |
| **Total** | **195** | **9** | **Complete web crawler** |

---

## A.6 Event Types Summary

| Event | Emitted By | Handled By | Data |
|-------|------------|------------|------|
| QueueUrl | Application-Start, FilterUrl | Queue URL | url, base |
| CrawlPage | QueueUrl | Crawl Page | url, base |
| SavePage | Crawl Page | Save Page | url, title, content, base |
| ExtractLinks | Crawl Page | Extract Links | url, html, base |
| NormalizeUrl | Extract Links | Normalize URL | raw, source, base |
| FilterUrl | Normalize URL | Filter URL | url, base |
