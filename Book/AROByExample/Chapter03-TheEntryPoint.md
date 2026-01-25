# Chapter 3: The Entry Point

*"Every application needs somewhere to begin."*

---

## What We Will Learn

- The `Application-Start` feature set
- Reading environment variables
- Creating directories at runtime
- Initializing application state
- Keeping the application alive for events
- The complete `main.aro` file

---

## 3.1 The Application-Start Feature Set

Every ARO application needs exactly one `Application-Start` feature set. This is where execution begins when you run `aro run .`.

The basic structure is:

```aro
(Application-Start: Application Name) {
    (* Initialization statements *)
    <Return> an <OK: status> for the <startup>.
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
    <Log> "Starting Web Crawler..." to the <console>.
    <Return> an <OK: status> for the <startup>.
}
```

This logs a startup message and exits. Run it with `aro run .` to verify it works.

**Step 2: Read the environment variable**

```aro
(Application-Start: Web Crawler) {
    <Log> "Starting Web Crawler..." to the <console>.

    (* Read starting URL from environment *)
    <Extract> the <start-url> from the <env: CRAWL_URL>.
    <Log> "Starting URL: ${<start-url>}" to the <console>.

    <Return> an <OK: status> for the <startup>.
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
    <Log> "Starting Web Crawler..." to the <console>.

    <Extract> the <start-url> from the <env: CRAWL_URL>.
    <Log> "Starting URL: ${<start-url>}" to the <console>.

    (* Create output directory *)
    <Create> the <output-path> with "./output".
    <Make> the <output-dir> to the <directory: output-path>.
    <Log> "Output directory created" to the <console>.

    <Return> an <OK: status> for the <startup>.
}
```

`<Create>` makes a new value—here, a string path. `<Make>` creates a directory at that path. The `<directory: ...>` specifier tells ARO what kind of thing we are making.

**Step 4: Initialize the crawled URLs set**

```aro
(Application-Start: Web Crawler) {
    <Log> "Starting Web Crawler..." to the <console>.

    <Extract> the <start-url> from the <env: CRAWL_URL>.
    <Log> "Starting URL: ${<start-url>}" to the <console>.

    <Create> the <output-path> with "./output".
    <Make> the <output-dir> to the <directory: output-path>.
    <Log> "Output directory created" to the <console>.

    (* Initialize empty crawled URLs set *)
    <Create> the <crawled-urls> with [].
    <Store> the <crawled-urls> into the <crawled-repository>.

    <Return> an <OK: status> for the <startup>.
}
```

We create an empty list `[]` and store it in a **repository**. Repositories are named storage locations that persist across feature set executions. We will use `crawled-repository` to track which URLs we have already visited.

**Step 5: Emit the first crawl event**

```aro
(Application-Start: Web Crawler) {
    <Log> "Starting Web Crawler..." to the <console>.

    <Extract> the <start-url> from the <env: CRAWL_URL>.
    <Log> "Starting URL: ${<start-url>}" to the <console>.

    <Create> the <output-path> with "./output".
    <Make> the <output-dir> to the <directory: output-path>.
    <Log> "Output directory created" to the <console>.

    <Create> the <crawled-urls> with [].
    <Store> the <crawled-urls> into the <crawled-repository>.

    (* Start crawling *)
    <Emit> a <CrawlPage: event> with { url: <start-url>, base: <start-url> }.

    <Return> an <OK: status> for the <startup>.
}
```

`<Emit>` sends an event to the event bus. The event type is `CrawlPage`, and it carries data: the URL to crawl and the base domain for filtering. Event data uses object syntax: `{ key: <value>, ... }`.

**Step 6: Keep the application alive**

```aro
(Application-Start: Web Crawler) {
    <Log> "Starting Web Crawler..." to the <console>.

    <Extract> the <start-url> from the <env: CRAWL_URL>.
    <Log> "Starting URL: ${<start-url>}" to the <console>.

    <Create> the <output-path> with "./output".
    <Make> the <output-dir> to the <directory: output-path>.
    <Log> "Output directory created" to the <console>.

    <Create> the <crawled-urls> with [].
    <Store> the <crawled-urls> into the <crawled-repository>.

    <Emit> a <CrawlPage: event> with { url: <start-url>, base: <start-url> }.

    (* Keep application alive to process events *)
    <Keepalive> the <application> for the <events>.

    <Return> an <OK: status> for the <startup>.
}
```

Without `<Keepalive>`, the application would emit the event and immediately exit. `<Keepalive>` blocks execution, allowing the event loop to process events. The application continues until you press Ctrl+C or all events are processed.

---

## 3.4 Adding a Shutdown Handler

Optionally, we can add a handler that runs when the application shuts down:

```aro
(Application-End: Success) {
    <Log> "Web Crawler completed!" to the <console>.
    <Return> an <OK: status> for the <shutdown>.
}
```

This runs when the application exits normally (not on crashes).

---

## 3.5 The Complete main.aro

Here is the complete entry point file:

```aro
(* ============================================================
   ARO Web Crawler - Application Entry Point

   Reads CRAWL_URL from environment and starts the crawl process.
   ============================================================ *)

(Application-Start: Web Crawler) {
    <Log> "Starting Web Crawler..." to the <console>.

    (* Read starting URL from environment *)
    <Extract> the <start-url> from the <env: CRAWL_URL>.

    <Log> "Starting URL: ${<start-url>}" to the <console>.

    (* Create output directory *)
    <Create> the <output-path> with "./output".
    <Make> the <output-dir> to the <directory: output-path>.
    <Log> "Output directory created" to the <console>.

    (* Initialize empty crawled URLs set *)
    <Create> the <crawled-urls> with [].
    <Store> the <crawled-urls> into the <crawled-repository>.

    (* Start crawling *)
    <Emit> a <CrawlPage: event> with { url: <start-url>, base: <start-url> }.

    (* Keep application alive to process events *)
    <Keepalive> the <application> for the <events>.

    <Return> an <OK: status> for the <startup>.
}

(Application-End: Success) {
    <Log> "Web Crawler completed!" to the <console>.
    <Return> an <OK: status> for the <shutdown>.
}
```

---

## 3.6 What ARO Does Well Here

**Clean Lifecycle.** Application-Start and Application-End clearly mark the application boundaries. The lifecycle is explicit and easy to understand.

**Simple State Initialization.** Creating a repository takes two lines. No database setup, no connection strings. Repositories are in-memory by default, which is perfect for our use case.

**Event Emission.** The `<Emit>` syntax is clean and the event data structure is readable. We can see exactly what data flows to the next handler.

---

## 3.7 What Could Be Better

**No Command-Line Arguments.** Reading from environment variables works, but sometimes you want `./crawler https://example.com`. ARO has no built-in argument parsing.

**No Default Values.** If `CRAWL_URL` is not set, the application fails. We cannot specify a fallback value in the Extract action.

---

## Chapter Recap

- `Application-Start` is the entry point; exactly one must exist
- `<Extract> ... from the <env: VAR>` reads environment variables
- `<Create>` makes values; `<Make>` creates filesystem objects
- `<Store>` persists data to named repositories
- `<Emit>` sends events to trigger other feature sets
- `<Keepalive>` keeps the application running for event processing
- `Application-End: Success` handles graceful shutdown

---

*Next: Chapter 4 - Event-Driven Architecture*
