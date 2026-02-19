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
Extract the <url> from the <event-data: url>.
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
| count | Count items in list | `Compute the <count: count> from <list>.` |
| hash | Compute hash value | `Compute the <hash: hash> from <url>.` |
| union | Combine two lists (set union) | `Compute the <all: union> from <a> with <b>.` |
| difference | Items in first but not second | `Compute the <new: difference> from <a> with <b>.` |

---

### HTTP

| Action | Syntax | Description |
|--------|--------|-------------|
| Request | `Request the <result> from the <url>.` | HTTP GET request |

**Example:**
```aro
Request the <html> from the <url>.
```

---

### HTML Parsing

| Action | Syntax | Description |
|--------|--------|-------------|
| ParseHtml | `ParseHtml the <result: specifier> from the <html>.` | Parse HTML content |

**Specifiers:**

| Specifier | Returns | Example |
|-----------|---------|---------|
| markdown | Object with title and markdown | `ParseHtml the <result: markdown> from <html>.` |
| links | List of href values | `ParseHtml the <links: links> from <html>.` |
| title | Page title string | `ParseHtml the <title: title> from <html>.` |

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
Split the <parts> from the <url> by /\/+$/.
Extract the <clean: first> from the <parts>.
```

---

### File System

| Action | Syntax | Description |
|--------|--------|-------------|
| Make | `Make the <result> to the <directory: path>.` | Create a directory |
| Write | `Write the <content> to the <file: path>.` | Write content to a file |

**Examples:**
```aro
Make the <output-dir> to the <directory: output-path>.
Write the <file-content> to the <file: file-path>.
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
Action ... when <condition>.
```

**Condition Types:**

| Type | Syntax | Example |
|------|--------|---------|
| Contains | `<a> contains <b>` | `when <url> contains <domain>` |
| Greater than | `<a> > <b>` | `when <count> > 0` |
| Equals | `<a> = <b>` | `when <status> = "active"` |

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
    (* statements - run concurrently *)
}
```

---

## B.4 String Interpolation

Variables can be embedded in strings:

```aro
"Text with ${<variable>} embedded"
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
    Extract the <result> from the <source: field>.

    (* Creation *)
    Create the <result> with <value>.

    (* Computation *)
    Compute the <result: operation> from <input>.

    (* HTTP *)
    Request the <result> from the <url>.

    (* HTML parsing *)
    ParseHtml the <result: specifier> from the <html>.

    (* String splitting *)
    Split the <parts> from the <string> by /regex/.

    (* File I/O *)
    Make the <dir> to the <directory: path>.
    Write the <content> to the <file: path>.

    (* Repository *)
    Store the <value> into the <repo>.
    Retrieve the <value> from the <repo>.

    (* Events *)
    Emit a <Event: event> with { key: <value> }.

    (* Logging *)
    Log "message ${<var>}" to the <console>.

    (* Conditional *)
    Action ... when <condition>.

    (* Control flow *)
    match <value> {
        case /pattern/ { ... }
    }

    for each <item> in <list> { ... }
    parallel for each <item> in <list> { ... }

    (* Return *)
    Return an <OK: status> for the <context>.
}
```
