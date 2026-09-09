# Chapter 3: The Entry Point

*"Every application needs somewhere to begin."*

---

## What We Will Learn

- The `Application-Start` feature set
- Reading environment variables
- Creating directories at runtime
- Emitting events to start processing
- The `Application-End` shutdown handler
- The complete `main.aro` file

---

## 3.1 The Application-Start Feature Set

Every ARO application needs exactly one `Application-Start` feature set. This is where execution begins when you run `aro run .`.

The basic structure is:

```aro
(Application-Start: Application Name) {
    (* Initialization statements *)
    Return an <OK: status> for the <startup>.
}
```

The name after `Application-Start:` is your application's identifier. It appears in logs and error messages.

---

## 3.2 The Architectural Decision

**Our Choice:** Read the starting URL from an environment variable.

**Alternative Considered:** We could read the URL from a configuration file, or accept it as a command-line argument. ARO supports the latter directly — `Extract the <url> from the <parameter: url>.` picks up `aro run . --url https://example.com` (ARO-0047). Environment variables still win for a crawler that runs in containers, where passing `CRAWL_URL=https://example.com` is natural and needs no change to the invocation.

**Why This Approach:** Environment variables require no parsing logic. The `<Extract>` action retrieves them directly. This keeps our entry point focused on initialization rather than argument handling.

There is one trap, and it is worth knowing now: **an unset environment variable is not an error.** `<env: NAME>` binds the empty string when the variable is missing, exactly like a shell would. `<parameter: name>` is the opposite — it fails loudly if the flag was not passed. We come back to this in section 3.7.

---

## 3.3 Building the Entry Point

Let us build `main.aro` step by step.

**Step 1: Start with logging**

```aro
(Application-Start: Web Crawler) {
    Log "Starting Web Crawler..." to the <console>.
    Return an <OK: status> for the <startup>.
}
```

This logs a startup message and exits. Run it with `aro run .` to verify it works.

**Step 2: Read the environment variable**

```aro
(Application-Start: Web Crawler) {
    Log "Starting Web Crawler..." to the <console>.

    (* Read starting URL from environment *)
    Extract the <start-url> from the <env: CRAWL_URL>.
    Log "Starting URL: ${<start-url>}" to the <console>.

    Return an <OK: status> for the <startup>.
}
```

The `<Extract>` action with `<env: VARIABLE_NAME>` reads from environment variables. The result is bound to `start-url`.

Notice the string interpolation: `"${<start-url>}"` embeds the variable's value in the string. Variables are always wrapped in angle brackets, even inside strings.

Run it:

```bash
CRAWL_URL="https://example.com" aro run .
```

You should see both log messages, with the URL in the second one.

**Step 3: Create the output directory**

```aro
(Application-Start: Web Crawler) {
    Log "Starting Web Crawler..." to the <console>.

    Extract the <start-url> from the <env: CRAWL_URL>.
    Log "Starting URL: ${<start-url>}" to the <console>.

    (* Create output directory *)
    Create the <output-path> with "./output".
    Make the <output-dir> to the <directory: output-path>.
    Log "Output directory created" to the <console>.

    Return an <OK: status> for the <startup>.
}
```

`<Create>` makes a new value—here, a string path. `<Make>` creates a directory at that path. The `<directory: ...>` specifier tells ARO what kind of thing we are making.

**Step 4: Emit the first crawl event**

```aro
(Application-Start: Web Crawler) {
    Log "Starting Web Crawler..." to the <console>.

    Extract the <start-url> from the <env: CRAWL_URL>.
    Log "Starting URL: ${<start-url>}" to the <console>.

    Create the <output-path> with "./output".
    Make the <output-dir> to the <directory: output-path>.
    Log "Output directory created" to the <console>.

    (* Queue initial URL for crawling *)
    Emit a <QueueUrl: event> with { url: <start-url>, base: <start-url> }.

    Return an <OK: status> for the <startup>.
}
```

`<Emit>` sends an event to the event bus. The event type is `QueueUrl`, and it carries data: the URL to crawl and the base domain for filtering. Event data uses object syntax: `{ key: <value>, ... }`.

Why `QueueUrl` instead of `CrawlPage`? We want every URL -- including the very first one -- to go through the same deduplication logic. The `QueueUrl` handler checks whether a URL has already been visited before triggering `CrawlPage`. This way, the entry point does not need to know about deduplication at all.

Notice that we do not need a `<Keepalive>` action here. The `<Emit>` action blocks until the entire event chain completes. When `QueueUrl` triggers `CrawlPage`, which in turn discovers more URLs and emits more `QueueUrl` events, the original `<Emit>` waits for all of them to finish. This makes `<Keepalive>` unnecessary for batch applications. It is only needed for servers or daemons that wait for external events.

---

## 3.4 Adding a Shutdown Handler

Optionally, we can add a handler that runs when the application shuts down:

```aro
(Application-End: Success) {
    Log "🥁 Web Crawler completed!" to the <console>.
    Log the <metrics: table> to the <console>.
    Return an <OK: status> for the <shutdown>.
}
```

`Application-End: Success` runs automatically when `Application-Start` completes normally. The `<metrics: table>` line prints a summary table of execution statistics—how many times each feature set ran, total time, and so on. This is a built-in capability that requires no setup. For our crawler, this means it fires after the `<Emit>` finishes and all crawled pages have been processed. There is no need to send a signal or press Ctrl+C -- the application shuts down on its own once the work is done.

---

## 3.5 The Complete main.aro

Here is the complete entry point file:

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

## 3.6 What ARO Does Well Here

**Clean Lifecycle.** Application-Start and Application-End clearly mark the application boundaries. `Application-End` triggers automatically when `Application-Start` completes, so the lifecycle is self-contained with no manual shutdown logic required.

**Blocking Emit.** The `<Emit>` action blocks until the entire event chain finishes. This means a batch application naturally exits when its work is done, without needing explicit keepalive or shutdown coordination.

**Event Emission.** The `<Emit>` syntax is clean and the event data structure is readable. We can see exactly what data flows to the next handler.

---

## 3.7 What Could Be Better

**Missing Environment Variables Fail Silently.** This is the sharp one. If `CRAWL_URL` is not set, `<start-url>` binds the empty string and the crawler cheerfully tries to fetch nothing:

```bash
$ aro run .
Starting Web Crawler...
Starting URL:
Output directory created
[OK] startup
```

No error, no exit code, no output files. If you want the application to stop, take the URL from a flag instead — `<parameter: …>` raises `Cannot extract the url from the parameter: url.` when the flag is absent:

```aro
Extract the <start-url> from the <parameter: url>.
```

```bash
$ aro run . --url https://example.com
```

**No Default Values in Extract.** Neither form lets you write a fallback into the `<Extract>` statement itself. What you can do is branch on the empty string that `<env: …>` leaves behind:

```aro
Extract the <configured-url> from the <env: CRAWL_URL>.
Log "no CRAWL_URL set - nothing to crawl" to the <console> when <configured-url> == "".
Emit a <QueueUrl: event> with { url: <configured-url> } when not (<configured-url> == "").
```

**No Positional Arguments.** `--url https://example.com` works; bare `./crawler https://example.com` does not. Every parameter needs a flag name.

---

## Chapter Recap

- `Application-Start` is the entry point; exactly one must exist
- `Extract ... from the <env: VAR>` reads environment variables
- `<Create>` makes values; `<Make>` creates filesystem objects
- `<Emit>` sends events to trigger other feature sets and blocks until the chain completes
- `Application-End: Success` runs automatically when `Application-Start` completes normally

---

*Next: Chapter 4 - Event-Driven Architecture*
