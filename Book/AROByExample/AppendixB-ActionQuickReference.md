# Appendix B: Action Quick Reference

This appendix provides a quick reference for all actions used in the web crawler.

---

## B.1 Actions by Category

### Data Extraction

| Action | Syntax | Description |
|--------|--------|-------------|
| Extract | `Extract the <result> from the <source: field>.` | Extract a value from an object or specifier |

**Examples:**
```aro
Extract the <url> from the <event: url>.
Extract the <start-url> from the <env: CRAWL_URL>.
Extract the <title> from the <markdown-result: title>.
```

---

### Data Creation

| Action | Syntax | Description |
|--------|--------|-------------|
| Create | `Create the <result> with <value>.` | Create a new value |

**Examples:**
```aro
Create the <output-path> with "./output".
Create the <absolute-url> with "${<base>}${<path>}".
```

---

### Computation

| Action | Syntax | Description |
|--------|--------|-------------|
| Compute | `Compute the <result: operation> from <input>.` | Perform a calculation |
| Compute | `Compute the <result: operation> from <a> with <b>.` | Perform a binary operation |

**Operations:**

| Operation | Description | Example |
|-----------|-------------|---------|
| length | String or list length | `Compute the <len: length> from <text>.` |
| count | Count items in list (alias of length) | `Compute the <count: count> from <list>.` |
| hash / sha256 | SHA-256 digest, 64 hex characters | `Compute the <hash: hash> from <url>.` |
| take / clip | First N characters or elements | `Compute the <short: hash\|take> from <url> with 12.` |
| sum | Total of a numeric collection | `Compute the <total: sum> from <amounts>.` |
| lines | Split text into a list of lines | `Compute the <ls: lines> from <content>.` |
| union | Combine two lists (set union) | `Compute the <all: union> from <a> with <b>.` |
| difference | Items in first but not second | `Compute the <new: difference> from <a> with <b>.` |
| intersect | Items present in both | `Compute the <both: intersect> from <a> with <b>.` |

Two rules about this slot are worth memorising:

- **The qualifier namespace is closed.** An unrecognised name is an error at check time, not a silent pass-through. `aro actions --qualifiers` prints the live set.
- **Some things that look like qualifiers are actions.** Sorting is `Sort the <s> for the <x>.`; reversing is `Reverse the <r> for the <x>.`; first and last are `Extract the <f: first> from the <x>.`. `Compute the <s: sort>` is rejected, and the error names the action you wanted.

Qualifiers chain with `|`, left to right: `hash|take` hashes and then truncates.

---

### HTTP

| Action | Syntax | Description |
|--------|--------|-------------|
| Request | `Request the <response> from the <url>.` | HTTP GET request (returns response object) |

**Example:**
```aro
Request the <response> from the <url>.
Extract the <body> from the <response: body>.
```

The response object contains `body` (parsed content), `status` (HTTP status code), and `headers` (response headers).

---

### HTML Parsing

| Action | Syntax | Description |
|--------|--------|-------------|
| ParseHtml | `ParseHtml the <result: specifier> from the <html>.` | Parse HTML content |

**Specifiers** — these five and no others; anything else is a runtime error:

| Specifier | Returns | Example |
|-----------|---------|---------|
| markdown | Object with `title` and `markdown` | `ParseHtml the <result: markdown> from <html>.` |
| links | List of href values | `ParseHtml the <links: links> from <html>.` |
| page | Object with `title`, `markdown` and `links`, from one parse | `ParseHtml the <page: page> from <html>.` |
| text | Text of every element matching a CSS selector | `ParseHtml the <headings: text> from <html> with "h1, h2".` |
| content | Object with `title` and flattened `content` text | `ParseHtml the <c: content> from <html>.` |

There is no `title` specifier. Take the `title` field off a `markdown` or `page` result instead.

---

### Data Grouping

| Action | Syntax | Description |
|--------|--------|-------------|
| Group | `Group the <result> from the <collection> by "field".` | Partition a collection by field value |

**Examples:**
```aro
Group the <status-groups> from the <orders> by "status".
(* Result: { "active": [...], "pending": [...] } *)

Extract the <active-orders> from the <status-groups: active>.
```

---

### String Splitting

| Action | Syntax | Description |
|--------|--------|-------------|
| Split | `Split the <result> from the <string> by /regex/.` | Split string by regex pattern |

**Examples:**
```aro
(* Split by fragment hash to strip URL fragments *)
Split the <parts> from the <url> by /#/.
Extract the <clean: first> from the <parts>.

(* Split by trailing slashes to normalize URLs *)
Split the <slash-parts> from the <url> by /\/+$/.
Extract the <trimmed: first> from the <slash-parts>.
```

---

### File System

| Action | Syntax | Description |
|--------|--------|-------------|
| Make | `Make the <result> to the <directory: path>.` | Create a directory |
| Write | `Write the <content> to the <file: path>.` | Write content to a file (overwrites) |
| Append | `Append the <result> to the <file: path> with <content>.` | Add to the end of a file |
| Read | `Read the <content> from the <file: path>.` | Read a file's contents |
| List | `List the <entries> from the <directory: path>.` | List a directory as records |
| Stat | `Stat the <info> for the <file: path>.` | Size, permissions, timestamps |

**Examples:**
```aro
Make the <output-dir> to the <directory: output-path>.
Write the <file-content> to the <file: file-path>.
Append the <log-entry> to the <file: "./crawl.log"> with "crawled ${<url>}\n".
```

Note the shape of `<Append>`: the content goes in the `with` clause, and the result name must be one that is not already bound. Putting the content in the result slot — `Append the <log-line> to the <file: …>.` — trips the immutability check (GitLab #580).

`<List>` returns a record per entry, not a list of paths. Take the path off it before reading:

```aro
List the <entries> from the <directory: "./logs">.
for each <entry> in <entries> {
    Extract the <path> from the <entry: path>.
    Read the <content> from the <file: path>.
}
```

---

### Repository

| Action | Syntax | Description |
|--------|--------|-------------|
| Store | `Store the <value> into the <repository-name>.` | Save data to repository |
| Retrieve | `Retrieve the <result> from the <repository-name>.` | Load data from repository |

**Examples:**
```aro
Store the <crawled-urls> into the <crawled-repository>.
Retrieve the <crawled-urls> from the <crawled-repository>.
```

When storing plain values (not collections), `<Store>` also binds `new-entry` to the execution context:
- `new-entry = 1` — Value was newly stored
- `new-entry = 0` — Value already existed (duplicate)

This enables atomic deduplication:
```aro
Store the <url> into the <crawled-repository>.
Emit a <CrawlPage: event> with { url: <url> } when <new-entry> > 0.
```

---

### Events

| Action | Syntax | Description |
|--------|--------|-------------|
| Emit | `Emit a <EventType: event> with { ... }.` | Emit an event |

**Example:**
```aro
Emit a <CrawlPage: event> with { url: <url>, base: <domain> }.
```

---

### Logging

| Action | Syntax | Description |
|--------|--------|-------------|
| Log | `Log "message" to the <console>.` | Write to console |

**Examples:**
```aro
Log "Starting..." to the <console>.
Log "URL: ${<url>}" to the <console>.
```

---

### Application Lifecycle

| Action | Syntax | Description |
|--------|--------|-------------|
| Keepalive | `Keepalive the <application> for the <events>.` | Keep app running for external events (servers only) |
| Return | `Return an <OK: status> for the <context>.` | Return success |

**Note:** Batch applications do not need `<Keepalive>` because `<Emit>` blocks until all downstream handlers complete. Only use `<Keepalive>` for applications that must stay alive to receive external events (e.g., HTTP servers, file watchers).

---

## B.2 Conditional Execution

Actions can include `when` guards:

```aro
Emit a <CrawlPage: event> with { url: <url> } when <new-entry> > 0.
```

**Condition Types:**

| Type | Syntax | Example |
|------|--------|---------|
| Contains | `<a> contains <b>` | `when <url> contains <domain>` |
| Comparison | `<a> > <b>`, `>=`, `<`, `<=` | `when <count> > 0` |
| Equals | `<a> == <b>` (also `=`) | `when <status> == "active"` |
| Not equals | `<a> != <b>` | `when <status> != "archived"` |
| Regex | `<a> matches /pattern/` | `when <url> matches /\.pdf$/` |
| Negation | `not (<condition>)` | `when not (<url> contains <domain>)` |
| Conjunction | `<c1> and <c2>`, `or` | `when <count> > 0 and <url> contains <domain>` |

Two traps:

- **`not` negates the whole comparison.** `when not <url> contains <domain>` reads as `not (<url> contains <domain>)`; it used to parse as `(not <url>) contains <domain>` and be silently always false (GitLab #572).
- **Guards and `where` clauses differ.** `starts-with` and `ends-with` work in a `where` clause on `<Filter>`, `<Retrieve>` or `<Delete>`; in a `when` guard they are a parse error.

---

## B.3 Control Flow

### Match Expression

```aro
match <value> {
    case <pattern> {
        (* statements *)
    }
    case <pattern> {
        (* statements *)
    }
}
```

**Pattern Types:**

| Type | Syntax | Example |
|------|--------|---------|
| Literal | `case <value>` | `case 0` |
| Regex | `case /pattern/` | `case /^https?:\/\//` |

---

### Iteration

```aro
for each <item> in <list> {
    (* statements *)
}

parallel for each <item> in <list> {
    (* statements - run concurrently, up to 4 per CPU core at a time *)
}

parallel for each <item> in <list> with <concurrency: 4> {
    (* statements - at most four in flight *)
}
```

---

## B.4 String Interpolation

Variables can be embedded in strings:

```aro
Log "Text with ${<variable>} embedded" to the <console>.
```

Escape sequences:
- `\n` — Newline
- `\\` — Backslash

---

## B.5 Comments

```aro
(* This is a comment *)

(* Comments can span
   multiple lines *)
```

---

## B.6 Feature Set Structure

```aro
(Feature Name: Business Activity) {
    (* statements *)
    Return an <OK: status> for the <context>.
}
```

**Special Feature Sets:**

| Name | Purpose |
|------|---------|
| `Application-Start: Name` | Entry point |
| `Application-End: Success` | Graceful shutdown |
| `Application-End: Error` | Error shutdown |
| `Name: EventType Handler` | Event handler |

---

## B.7 Quick Syntax Summary

```aro
(* Feature set definition *)
(Feature Name: Business Activity) {

    (* Extraction *)
    Extract the <extracted> from the <source: field>.

    (* Creation *)
    Create the <created> with <value>.

    (* Computation *)
    Compute the <computed: uppercase> from <input>.

    (* HTTP *)
    Request the <response> from the <url>.

    (* HTML parsing *)
    ParseHtml the <parsed: markdown> from the <html>.

    (* Data grouping *)
    Group the <grouped> from the <collection> by "field".

    (* String splitting *)
    Split the <parts> from the <string> by /regex/.

    (* File I/O *)
    Make the <dir> to the <directory: path>.
    Write the <content> to the <file: path>.

    (* Repository *)
    Store the <value> into the <repo>.
    Retrieve the <loaded> from the <repo>.

    (* Events *)
    Emit a <Event: event> with { key: <value> }.

    (* Logging *)
    Log "message ${<var>}" to the <console>.

    (* Conditional *)
    Log "ready" to the <console> when <count> > 0.

    (* Control flow *)
    match <value> {
        case /pattern/ { Log "matched" to the <console>. }
    }

    for each <item> in <list> { Log <item> to the <console>. }
    parallel for each <item> in <list> { Log <item> to the <console>. }

    (* Return *)
    Return an <OK: status> for the <context>.
}
```
