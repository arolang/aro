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

**Alternative Considered:** We could read the URL from a configuration file, or accept it as a command-line argument. Environment variables are simpler and work well with Docker and CI/CD systems. For a crawler that runs in containers, passing `CRAWL_URL=https://example.com` is natural.

**Why This Approach:** Environment variables require no parsing logic. The `<Extract>` action retrieves them directly. This keeps our entry point focused on initialization rather than argument handling.

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
    Return an <OK: status> for the <shutdown>.
}
```

`Application-End: Success` runs automatically when `Application-Start` completes normally. For our crawler, this means it fires after the `<Emit>` finishes and all crawled pages have been processed. There is no need to send a signal or press Ctrl+C -- the application shuts down on its own once the work is done.

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

**No Command-Line Arguments.** Reading from environment variables works, but sometimes you want `./crawler https://example.com`. ARO has no built-in argument parsing.

**No Default Values.** If `CRAWL_URL` is not set, the application fails. We cannot specify a fallback value in the Extract action.

---

## Chapter Recap

- `Application-Start` is the entry point; exactly one must exist
- `Extract ... from the <env: VAR>` reads environment variables
- `<Create>` makes values; `<Make>` creates filesystem objects
- `<Emit>` sends events to trigger other feature sets and blocks until the chain completes
- `Application-End: Success` runs automatically when `Application-Start` completes normally

---

*Next: Chapter 4 - Event-Driven Architecture*
