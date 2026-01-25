# Appendix A: Complete Code

This appendix contains the complete source code for the web crawler, with detailed comments explaining each line.

---

## A.1 main.aro

The application entry point. Initializes state and starts the crawl.

```aro
(* ============================================================
   ARO Web Crawler - Application Entry Point

   This file contains the Application-Start feature set, which is
   the entry point for all ARO applications. It:
   - Reads the starting URL from an environment variable
   - Creates the output directory
   - Initializes the crawled-urls repository
   - Emits the first CrawlPage event
   - Keeps the application alive to process events
   ============================================================ *)

(Application-Start: Web Crawler) {
    (* Log startup message to console *)
    <Log> "Starting Web Crawler..." to the <console>.

    (* Read the CRAWL_URL environment variable.
       This is how we pass the starting URL to the crawler.
       If not set, the application will fail with a helpful error. *)
    <Extract> the <start-url> from the <env: CRAWL_URL>.

    (* Log the URL we're about to crawl *)
    <Log> "Starting URL: ${<start-url>}" to the <console>.

    (* Create a string containing the output path *)
    <Create> the <output-path> with "./output".

    (* Create the output directory on disk.
       The directory: specifier tells Make we're creating a directory. *)
    <Make> the <output-dir> to the <directory: output-path>.
    <Log> "Output directory created" to the <console>.

    (* Create an empty list to track crawled URLs.
       We start with no URLs crawled. *)
    <Create> the <crawled-urls> with [].

    (* Store the empty list in a named repository.
       Repositories persist data across handler executions.
       We'll use this to track which URLs we've already visited. *)
    <Store> the <crawled-urls> into the <crawled-repository>.

    (* Emit the first CrawlPage event to start the crawl.
       Event data is an object with url and base fields.
       'base' is the domain we'll filter against to stay on-site. *)
    <Emit> a <CrawlPage: event> with { url: <start-url>, base: <start-url> }.

    (* Keep the application running to process events.
       Without this, the app would emit the event and immediately exit.
       Keepalive blocks until Ctrl+C or all events are processed. *)
    <Keepalive> the <application> for the <events>.

    (* Return success status for the startup *)
    <Return> an <OK: status> for the <startup>.
}

(* Graceful shutdown handler.
   This runs when the application exits normally (not on crash).
   Optional but useful for cleanup or final logging. *)
(Application-End: Success) {
    <Log> "Web Crawler completed!" to the <console>.
    <Return> an <OK: status> for the <shutdown>.
}
```

---

## A.2 crawler.aro

The core crawling logic. Fetches pages and triggers downstream processing.

```aro
(* ============================================================
   ARO Web Crawler - Crawl Logic

   This file handles the CrawlPage event. It:
   - Checks if the URL has already been crawled
   - Marks the URL as crawled
   - Fetches the page via HTTP
   - Converts HTML to Markdown
   - Emits events for saving and link extraction
   ============================================================ *)

(Crawl Page: CrawlPage Handler) {
    (* Log that this handler was triggered *)
    <Log> "CrawlPage handler triggered" to the <console>.

    (* Events carry data in the 'data' field.
       First, extract the entire data object. *)
    <Extract> the <event-data> from the <event: data>.

    (* Then extract individual fields from the data object.
       The url is the page to crawl.
       The base is the original domain for filtering. *)
    <Extract> the <url> from the <event-data: url>.
    <Extract> the <base-domain> from the <event-data: base>.

    <Log> "Extracted URL: ${<url>}" to the <console>.

    (* === Deduplication Check ===
       Before fetching, check if we've already crawled this URL. *)

    (* Retrieve the current set of crawled URLs from the repository *)
    <Retrieve> the <crawled-urls> from the <crawled-repository>.

    (* Wrap our URL in a list for set operations.
       Set operations work on lists. *)
    <Create> the <single-url-list> with [<url>].

    (* Compute the difference: URLs in our list that aren't in crawled-urls.
       If the URL is already crawled, the difference will be empty. *)
    <Compute> the <new-urls: difference> from <single-url-list> with <crawled-urls>.

    (* Count how many new URLs we have (0 or 1) *)
    <Compute> the <new-url-count: count> from <new-urls>.

    (* Skip if already crawled.
       Match checks the count; if 0, we return early. *)
    match <new-url-count> {
        case 0 {
            (* URL already crawled, skip it *)
            <Return> an <OK: status> for the <skip>.
        }
    }

    (* URL is new, proceed with crawling *)
    <Log> "Crawling: ${<url>}" to the <console>.

    (* === Mark as Crawled ===
       Add the URL to crawled-urls BEFORE fetching.
       This prevents duplicate requests in parallel execution. *)

    (* Union combines our URL with existing crawled URLs *)
    <Compute> the <updated-crawled: union> from <crawled-urls> with <single-url-list>.

    (* Store the updated set back to the repository *)
    <Store> the <updated-crawled> into the <crawled-repository>.

    (* === Fetch the Page ===
       Make an HTTP GET request to the URL. *)
    <Request> the <html> from the <url>.

    (* Log the response size for debugging *)
    <Compute> the <html-len: length> from the <html>.
    <Log> "Fetched HTML length: ${<html-len>}" to the <console>.

    (* === Parse HTML ===
       Convert HTML to Markdown and extract the title.
       ParseHtml with 'markdown' specifier returns an object
       containing 'title' and 'markdown' fields. *)
    <ParseHtml> the <markdown-result: markdown> from the <html>.

    (* Extract title and content from the result *)
    <Extract> the <title> from the <markdown-result: title>.
    <Extract> the <markdown-content> from the <markdown-result: markdown>.

    (* === Emit Downstream Events ===
       SavePage will write the content to a file.
       ExtractLinks will find and process links in the HTML. *)

    (* Emit event to save the Markdown content *)
    <Emit> a <SavePage: event> with {
        url: <url>,
        title: <title>,
        content: <markdown-content>,
        base: <base-domain>
    }.

    (* Emit event to extract links.
       We pass the raw HTML, not Markdown, for link extraction. *)
    <Emit> a <ExtractLinks: event> with {
        url: <url>,
        html: <html>,
        base: <base-domain>
    }.

    <Return> an <OK: status> for the <crawl>.
}
```

---

## A.3 links.aro

Link extraction, normalization, filtering, and queuing.

```aro
(* ============================================================
   ARO Web Crawler - Link Extraction using ParseHtml Action

   This file contains four handlers that process links:
   1. ExtractLinks - Parse HTML to find all links
   2. NormalizeUrl - Convert relative URLs to absolute
   3. FilterUrl - Keep only same-domain URLs
   4. QueueUrl - Add new URLs to the crawl queue
   ============================================================ *)

(* === Handler 1: Extract Links ===
   Parses HTML to find all href values in anchor tags. *)
(Extract Links: ExtractLinks Handler) {
    <Log> "ExtractLinks handler triggered" to the <console>.

    (* Extract event data *)
    <Extract> the <event-data> from the <event: data>.
    <Extract> the <html> from the <event-data: html>.
    <Extract> the <source-url> from the <event-data: url>.
    <Extract> the <base-domain> from the <event-data: base>.

    (* ParseHtml with 'links' specifier extracts all href values.
       Returns a list of strings like ["/about", "https://...", "#section"] *)
    <ParseHtml> the <links: links> from the <html>.

    (* Count and log for debugging *)
    <Compute> the <link-count: count> from the <links>.
    <Log> "Found ${<link-count>} links" to the <console>.

    (* Process each link in parallel.
       'parallel for each' processes all items concurrently.
       Each iteration emits a NormalizeUrl event. *)
    parallel for each <raw-url> in <links> {
        <Emit> a <NormalizeUrl: event> with {
            raw: <raw-url>,
            source: <source-url>,
            base: <base-domain>
        }.
    }

    <Return> an <OK: status> for the <extraction>.
}

(* === Handler 2: Normalize URL ===
   Converts relative URLs to absolute URLs.
   Filters out fragments and special URL schemes. *)
(Normalize URL: NormalizeUrl Handler) {
    (* Extract event data *)
    <Extract> the <event-data> from the <event: data>.
    <Extract> the <raw-url> from the <event-data: raw>.
    <Extract> the <source-url> from the <event-data: source>.
    <Extract> the <base-domain> from the <event-data: base>.

    (* Match against regex patterns to classify URL type.
       Only the first matching case executes. *)
    match <raw-url> {
        (* Absolute URLs (http:// or https://) - use as-is *)
        case /^https?:\/\// {
            <Emit> a <FilterUrl: event> with {
                url: <raw-url>,
                base: <base-domain>
            }.
        }

        (* Just "/" alone - the root, use base domain *)
        case /^\/$/ {
            <Emit> a <FilterUrl: event> with {
                url: <base-domain>,
                base: <base-domain>
            }.
        }

        (* Root-relative URLs (/path) - prepend base domain *)
        case /^\// {
            (* String interpolation builds the absolute URL *)
            <Create> the <absolute-url> with "${<base-domain>}${<raw-url>}".
            <Emit> a <FilterUrl: event> with {
                url: <absolute-url>,
                base: <base-domain>
            }.
        }

        (* Skip fragments and special schemes.
           These are not crawlable pages.
           No emit means they're filtered out silently. *)
        case /^(#|mailto:|javascript:|tel:|data:)/ {
            (* Do nothing - skip these URLs *)
        }

        (* Note: Path-relative URLs (../sibling) are not handled.
           They fall through with no emit and are skipped. *)
    }

    <Return> an <OK: status> for the <normalization>.
}

(* === Handler 3: Filter URL ===
   Keeps only URLs that belong to the same domain. *)
(Filter URL: FilterUrl Handler) {
    (* Extract event data *)
    <Extract> the <event-data> from the <event: data>.
    <Extract> the <url> from the <event-data: url>.
    <Extract> the <base-domain> from the <event-data: base>.

    (* Only process URLs that contain the base domain.
       The 'when' guard makes the action conditional.
       If the condition is false, nothing happens. *)
    <Log> "Queuing: ${<url>}" to the <console> when <url> contains <base-domain>.
    <Emit> a <QueueUrl: event> with {
        url: <url>,
        base: <base-domain>
    } when <url> contains <base-domain>.

    <Return> an <OK: status> for the <filter>.
}

(* === Handler 4: Queue URL ===
   Final deduplication check before emitting CrawlPage. *)
(Queue URL: QueueUrl Handler) {
    (* Extract event data *)
    <Extract> the <event-data> from the <event: data>.
    <Extract> the <url> from the <event-data: url>.
    <Extract> the <base-domain> from the <event-data: base>.

    (* Check if already crawled.
       This is the same pattern used in the crawl handler.
       We check twice to handle race conditions in parallel execution. *)
    <Retrieve> the <crawled-urls> from the <crawled-repository>.
    <Create> the <single-url-list> with [<url>].
    <Compute> the <uncrawled-urls: difference> from <single-url-list> with <crawled-urls>.
    <Compute> the <uncrawled-count: count> from <uncrawled-urls>.

    (* Only emit CrawlPage if the URL hasn't been crawled.
       The 'when' guard with numeric comparison. *)
    <Log> "Queued: ${<url>}" to the <console> when <uncrawled-count> > 0.
    <Emit> a <CrawlPage: event> with {
        url: <url>,
        base: <base-domain>
    } when <uncrawled-count> > 0.

    <Return> an <OK: status> for the <queue>.
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
    <Extract> the <event-data> from the <event: data>.
    <Extract> the <url> from the <event-data: url>.
    <Extract> the <title> from the <event-data: title>.
    <Extract> the <content> from the <event-data: content>.

    (* Generate a hash of the URL for the filename.
       Hashes are unique and filesystem-safe.
       The actual URL is preserved in the file content. *)
    <Compute> the <url-hash: hash> from the <url>.

    (* Build the file path with string interpolation *)
    <Create> the <file-path> with "./output/${<url-hash>}.md".

    <Log> "Saving: ${<url>} to ${<file-path>}" to the <console>.

    (* Format the Markdown file with metadata.
       \n creates newlines.
       The file will have:
       - Title as H1
       - Source URL for reference
       - Separator
       - Actual content *)
    <Create> the <file-content> with "# ${<title>}\n\n**Source:** ${<url>}\n\n---\n\n${<content>}".

    (* Write the content to the file.
       The 'file:' specifier indicates the target is a file path. *)
    <Write> the <file-content> to the <file: file-path>.

    <Return> an <OK: status> for the <save>.
}
```

---

## A.5 Summary Statistics

| File | Lines | Handlers | Purpose |
|------|-------|----------|---------|
| main.aro | 36 | 2 | Application lifecycle |
| crawler.aro | 54 | 1 | Core crawling logic |
| links.aro | 93 | 4 | Link processing pipeline |
| storage.aro | 28 | 1 | File storage |
| **Total** | **211** | **8** | **Complete web crawler** |

---

## A.6 Event Types Summary

| Event | Emitted By | Handled By | Data |
|-------|------------|------------|------|
| CrawlPage | Application-Start, QueueUrl | Crawl Page | url, base |
| SavePage | Crawl Page | Save Page | url, title, content, base |
| ExtractLinks | Crawl Page | Extract Links | url, html, base |
| NormalizeUrl | Extract Links | Normalize URL | raw, source, base |
| FilterUrl | Normalize URL | Filter URL | url, base |
| QueueUrl | Filter URL | Queue URL | url, base |
