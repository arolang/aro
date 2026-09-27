# Chapter 12: Putting It Together

*"The whole is greater than the sum of its parts."*

---

## What We Will Learn

- The complete application flow
- How all the pieces connect
- Running the crawler
- Understanding the output
- Troubleshooting common issues

---

## 12.1 The Complete Picture

We have built five files with nine feature sets:

| File | Feature Set | Triggered By | Emits |
|------|-------------|--------------|-------|
| `openapi.yaml` | — | — | Event schemas for typed extraction |
| `main.aro` | Application-Start | Application launch | QueueUrl |
| `main.aro` | Application-End: Success | Graceful shutdown | — |
| `crawler.aro` | Crawl Page | CrawlPage | SavePage, ExtractLinks |
| `links.aro` | Extract Links | ExtractLinks | NormalizeUrl |
| `links.aro` | Normalize URL | NormalizeUrl | FilterUrl |
| `links.aro` | Filter URL | FilterUrl | QueueUrl |
| `links.aro` | Queue URL | QueueUrl | — (stores only) |
| `links.aro` | Trigger Crawl | `crawled-repository` change | CrawlPage |
| `storage.aro` | Save Page | SavePage | — |

The last two rows are the pattern from Chapter 8: `Queue URL` stores and stops, and the repository observer `Trigger Crawl` is what turns a genuinely-new entry into a `CrawlPage` event. Store *or* emit, never both.

---

## 12.2 The Data Flow

When you run the crawler with a URL, here is what happens:

```
1. Application-Start
   ├── Reads CRAWL_URL from environment
   ├── Creates output directory
   ├── Emits QueueUrl with starting URL
   └── Emit blocks until the entire event chain completes

2. QueueUrl Handler (per URL)
   └── Stores { id: hash(url), url, base } in crawled-repository
       (a URL already present is a no-op — the id deduplicates)

2b. Trigger Crawl (crawled-repository Observer)
   └── Fires only for genuinely new entries, and emits CrawlPage

3. CrawlPage Handler
   ├── Fetches page via HTTP
   ├── Parses HTML to Markdown
   ├── Emits SavePage
   └── Emits ExtractLinks

4. SavePage Handler
   ├── Computes URL hash
   ├── Formats content with metadata
   └── Writes file to output/

5. ExtractLinks Handler
   ├── Parses HTML for links
   └── Emits NormalizeUrl for each link (parallel)

6. NormalizeUrl Handler (per link)
   ├── Classifies URL type
   ├── Converts to absolute URL
   └── Emits FilterUrl (or skips)

7. FilterUrl Handler (per URL)
   └── Emits QueueUrl if URL matches base domain

8. Loop continues until no new URLs
```

The process is self-sustaining. Each crawled page discovers new pages, which discover more pages, until the entire site is crawled.

---

## 12.3 Running the Crawler

Make sure you have all five files, plus the output directory:

```
web-crawler/
├── openapi.yaml
├── main.aro
├── crawler.aro
├── links.aro
├── storage.aro
└── output/
```

Run the crawler:

```bash
CRAWL_URL="https://example.com" aro run .
```

Replace `https://example.com` with your target site. For testing, use a small site or a local server.

---

## 12.4 Sample Output

Running against a small site produces something like this — every line tagged with the feature set that wrote it:

```
Starting Web Crawler...
Starting URL: https://example.com
Output directory created
Queued: https://example.com
Crawling: https://example.com
Saving: https://example.com to ./output/2733da75...642.md
Queued: https://example.com/about
Queued: https://example.com/docs
Crawling: https://example.com/about
Crawling: https://example.com/docs
...
Web Crawler completed!
+-------------------+-------+---------+--------+---------+
                  | Feature Set       | Count | Success | Failed | Avg(ms) |
                  ...
[OK] startup
```

Two pages being crawled back to back in the log does not mean they were fetched in sequence — that is `parallel for each` at work, and the interleaving changes run to run.

The crawler continues until all discovered pages are processed and then terminates automatically.

---

## 12.5 Checking the Output

After running, check the output directory:

```bash
ls output/
```

You should see Markdown files, one per page, named for the SHA-256 of the URL:

```
2733da759eed786d5aceffe088a9dd10699d92cd75b6149e423cc3a35a031642.md
32a28882cd1a78ea9b8f7c463350d402cb55f602b6ff5115a9fa3db3ae8a0122.md
6821b9d32a493617aa39555bd4be1979a7c36e085416eb031a5a0db3744ad950.md
...
```

View a file:

```bash
cat output/2733da759eed786d5aceffe088a9dd10699d92cd75b6149e423cc3a35a031642.md
```

```markdown
# Welcome to Example Site

**Source:** https://example.com

---

Welcome to our documentation...
```

---

## 12.6 Troubleshooting

**Problem: it runs, prints `[OK] startup`, and does nothing**

Almost always a missing `CRAWL_URL`. An unset environment variable is not an error in ARO — `<start-url>` binds the empty string and the crawl chain fizzles out silently. Look for the giveaway in the second log line:

```
Starting URL:
```

Nothing after the colon means nothing to crawl. Set the variable:

```bash
CRAWL_URL="https://example.com" aro run .
```

Section 3.7 shows how to make this loud instead of quiet, by taking the URL from `<parameter: url>` rather than `<env: …>`.

**Problem: No output files created**

Check that:
- The output directory exists
- You have write permissions
- The target site returned valid HTML

**Problem: Crawler runs forever**

Some sites have infinite pages (search results with pagination, date archives, etc.). Press Ctrl+C to stop. For production use, add depth limits or page limits.

**Problem: "Connection refused" or similar errors**

The target site may be:
- Down or unreachable
- Blocking automated requests
- Using HTTPS with certificate issues

Try a different site or check your network connection.

---

## 12.7 The Complete Code

Here are all four `.aro` files for reference:

**main.aro** (30 lines)
```aro
(Application-Start: Web Crawler) {
    Log "Starting Web Crawler..." to the <console>.
    Extract the <start-url> from the <env: CRAWL_URL>.
    Log "Starting URL: ${<start-url>}" to the <console>.
    Create the <output-path> with "./output".
    Make the <output-dir> to the <directory: output-path>.
    Log "Output directory created" to the <console>.
    Emit a <QueueUrl: event> with { url: <start-url>, base: <start-url> }.
    Return an <OK: status> for the <startup>.
}

(Application-End: Success) {
    Log "🥁 Web Crawler completed!" to the <console>.
    Log the <metrics: table> to the <console>.
    Return an <OK: status> for the <shutdown>.
}
```

**crawler.aro** (30 lines) — See Chapter 5

**links.aro** (99 lines) — See Chapter 8

**storage.aro** (27 lines) — See Chapter 9

Total: **186 lines** of ARO code, comments and blank lines included, for a complete, concurrent web crawler (plus the 126-line `openapi.yaml` schema file).

---

## 12.8 What ARO Does Well Here

**Compositional Design.** Each handler is small and focused. Together, they form a sophisticated application. The event-driven architecture makes composition natural.

**Minimal Boilerplate.** 186 lines does a lot: HTTP requests, HTML parsing, parallel processing, file I/O, and deduplication. No imports, no configuration files, no build setup.

**Readable Flow.** You can trace the flow by reading the code. Events connect the pieces explicitly. There is no hidden control flow.

---

## 12.9 What Could Be Better

**No Centralized Error Handling.** If something fails, that handler fails silently. A production crawler would need better error tracking.

**No Progress Reporting.** There is no way to know how many pages remain or how far along the crawl is.

**No Configuration.** Everything except the starting URL is hardcoded: output path, concurrency, filtering rules. `<parameter: …>` (Chapter 3) and `Configure the <http-client: timeout> with 10.` would let a user change those without editing the source.

---

## Chapter Recap

- Five files (four `.aro` plus `openapi.yaml`), nine feature sets
- Events create a self-sustaining crawl loop
- Each handler has a single responsibility
- Running is simple: set CRAWL_URL and run
- Output is Markdown files with source metadata
- The architecture is extensible and maintainable

---

*Next: Chapter 13 - Docker Deployment*
