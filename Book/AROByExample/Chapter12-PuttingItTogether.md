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

We have built four files with eight handlers:

| File | Handler | Triggered By | Emits |
|------|---------|--------------|-------|
| `main.aro` | Application-Start | Application launch | QueueUrl |
| `main.aro` | Application-End: Success | Graceful shutdown | — |
| `crawler.aro` | Crawl Page | CrawlPage | SavePage, ExtractLinks |
| `links.aro` | Extract Links | ExtractLinks | NormalizeUrl |
| `links.aro` | Normalize URL | NormalizeUrl | FilterUrl |
| `links.aro` | Filter URL | FilterUrl | QueueUrl |
| `links.aro` | Queue URL | QueueUrl | CrawlPage |
| `storage.aro` | Save Page | SavePage | — |

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
   ├── Stores URL atomically in crawled-repository
   └── Emits CrawlPage if new-entry = 1 (first time seen)

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

Make sure you have all four files:

```
web-crawler/
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

Running against a documentation site might produce:

```
Starting Web Crawler...
Starting URL: https://example.com
Output directory created
Queued: https://example.com
Crawling: https://example.com
Saving: https://example.com to ./output/5d41402a.md
Queued: https://example.com/docs
Queued: https://example.com/about
Crawling: https://example.com/docs
...
[Application-End] Web Crawler completed!
```

The crawler continues until all discovered pages are processed and then terminates automatically.

---

## 12.5 Checking the Output

After running, check the output directory:

```bash
ls output/
```

You should see Markdown files:

```
5d41402a.md
7b52009b.md
2c624232.md
...
```

View a file:

```bash
cat output/5d41402a.md
```

```markdown
# Welcome to Example Site

**Source:** https://example.com

---

Welcome to our documentation...
```

---

## 12.6 Troubleshooting

**Problem: "Cannot extract start-url from env CRAWL_URL"**

The environment variable is not set. Make sure to set it:

```bash
CRAWL_URL="https://example.com" aro run .
```

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

Here are all four files for reference:

**main.aro** (13 lines)
```aro
(Application-Start: Web Crawler) {
    <Log> "Starting Web Crawler..." to the <console>.
    <Extract> the <start-url> from the <env: CRAWL_URL>.
    <Log> "Starting URL: ${<start-url>}" to the <console>.
    <Create> the <output-path> with "./output".
    <Make> the <output-dir> to the <directory: output-path>.
    <Log> "Output directory created" to the <console>.
    <Emit> a <QueueUrl: event> with { url: <start-url>, base: <start-url> }.
    <Return> an <OK: status> for the <startup>.
}

(Application-End: Success) {
    <Log> "Web Crawler completed!" to the <console>.
    <Return> an <OK: status> for the <shutdown>.
}
```

**crawler.aro** (14 lines) — See Chapter 5

**links.aro** (93 lines) — See Chapter 8

**storage.aro** (28 lines) — See Chapter 9

Total: **148 lines** of ARO code for a complete, concurrent web crawler.

---

## 12.8 What ARO Does Well Here

**Compositional Design.** Each handler is small and focused. Together, they form a sophisticated application. The event-driven architecture makes composition natural.

**Minimal Boilerplate.** 148 lines does a lot: HTTP requests, HTML parsing, parallel processing, file I/O, and deduplication. No imports, no configuration files, no build setup.

**Readable Flow.** You can trace the flow by reading the code. Events connect the pieces explicitly. There is no hidden control flow.

---

## 12.9 What Could Be Better

**No Centralized Error Handling.** If something fails, that handler fails silently. A production crawler would need better error tracking.

**No Progress Reporting.** There is no way to know how many pages remain or how far along the crawl is.

**No Configuration.** Everything is hardcoded: output path, concurrency, filtering rules. A configuration file or command-line options would add flexibility.

---

## Chapter Recap

- Four files, eight handlers, 148 lines of code
- Events create a self-sustaining crawl loop
- Each handler has a single responsibility
- Running is simple: set CRAWL_URL and run
- Output is Markdown files with source metadata
- The architecture is extensible and maintainable

---

*Next: Chapter 13 - Docker Deployment*
