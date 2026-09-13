# Chapter 9: Storing Results

*"A crawler that does not save is just a network benchmark."*

---

## What We Will Learn

- Handling the `SavePage` event
- Computing hash values for filenames
- Building file content with multi-line strings
- Writing files with `<Write>`
- The complete storage handler

---

## 9.1 The SavePage Handler

The `SavePage` handler receives crawled content and saves it to disk. It is triggered by the crawl handler after fetching and converting a page.

The handler must:

1. Generate a unique filename from the URL
2. Format the content with metadata
3. Write to the output directory

---

## 9.2 The Architectural Decision

**Our Choice:** Use URL hashes for filenames.

**Alternative Considered:** We could slugify the URL path (e.g., `/docs/api` becomes `docs-api.md`). This creates readable filenames but has problems: path collisions, special characters, and length limits. Hashes are guaranteed unique and safe for all filesystems.

**Why This Approach:** Hash-based filenames are simple and reliable. The URL is included in the file content, so you can always find the source. For a crawler that might save thousands of pages, uniqueness matters more than readability.

---

## 9.3 Creating the Storage Handler

Create `storage.aro`:

```aro
(* ============================================================
   ARO Web Crawler - File Storage

   Saves crawled pages as Markdown files to the output directory
   with filenames derived from the URL hash.
   ============================================================ *)

(Save Page: SavePage Handler) {
    (* Extract from event data structure *)
    Extract the <url> from the <event: url>.
    Extract the <title> from the <event: title>.
    Extract the <content> from the <event: content>.

    Return an <OK: status> for the <save>.
}
```

The event carries three fields, accessible directly as `<event: field>`:

- `url` — The page URL (for metadata)
- `title` — The page title (from HTML)
- `content` — The Markdown content

---

## 9.4 Computing the Hash

Add the hash computation:

```aro
(Save Page: SavePage Handler) {
    Extract the <url> from the <event: url>.
    Extract the <title> from the <event: title>.
    Extract the <content> from the <event: content>.

    (* Use URL hash as filename *)
    Compute the <url-hash: hash> from the <url>.
    Create the <file-path> with "./output/${<url-hash>}.md".

    Log "Saving: ${<url>} to ${<file-path>}" to the <console>.

    Return an <OK: status> for the <save>.
}
```

The `Compute ... hash` operation generates a SHA-256 digest of the URL string, rendered as 64 hexadecimal characters. (`sha256` is an alias for the same operation, if you prefer the explicit name.) We then build the file path using string interpolation.

---

## 9.5 Formatting the Content

We want each file to include metadata about the source:

```aro
    (* Previous code... *)

    (* Format markdown file with frontmatter *)
    Create the <file-content> with "# ${<title>}\n\n**Source:** ${<url>}\n\n---\n\n${<content>}".
```

This creates Markdown like:

```markdown
# Page Title

**Source:** https://example.com/page

---

Actual page content here...
```

The `\n` creates newlines. Multiple `\n\n` creates blank lines for Markdown spacing.

---

## 9.6 Writing the File

Finally, write the content:

```aro
    (* Previous code... *)

    (* Write content to file *)
    Write the <file-content> to the <file: file-path>.

    Return an <OK: status> for the <save>.
}
```

The `<Write>` action writes a string to a file. The `<file: ...>` specifier indicates the target is a file at the given path.

---

## 9.7 The Complete storage.aro

```aro
(* ============================================================
   ARO Web Crawler - File Storage

   Saves crawled pages as Markdown files to the output directory
   with filenames derived from the URL hash.
   ============================================================ *)

(Save Page: SavePage Handler) {
    (* Extract from event data structure *)
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

## 9.8 Output Examples

After running the crawler, your output directory might contain:

```
output/
├── 2733da759eed786d5aceffe088a9dd10699d92cd75b6149e423cc3a35a031642.md
├── 6821b9d32a493617aa39555bd4be1979a7c36e085416eb031a5a0db3744ad950.md
├── 32a28882cd1a78ea9b8f7c463350d402cb55f602b6ff5115a9fa3db3ae8a0122.md
└── ...
```

Those names are long because the digest is a full SHA-256. If you want something shorter, chain `take` onto the qualifier with `|` rather than reaching for a weaker hash:

```aro
Compute the <url-hash: hash|take> from the <url> with 12.
(* 037ab55168fe *)
```

Each file contains:

```markdown
# Getting Started with ARO

**Source:** https://example.com/docs/getting-started

---

## Introduction

ARO is a domain-specific language for expressing business logic...
```

The hash filename is not human-readable, but the content preserves the source URL for reference.

---

## 9.9 What ARO Does Well Here

**Simple File I/O.** `<Write>` takes content and a path. No file handles, no streams, no close calls. One action, one line.

**Built-in Hashing.** The `hash` computation is built into the language. No imports, no libraries.

**String Building.** Multi-line strings with `\n` and interpolation make content formatting straightforward.

---

## 9.10 What Could Be Better

**Metadata Is Read-Only.** `Stat the <info> for the <file: path>.` reads back size, permissions, and timestamps, but nothing writes them. Every file `<Write>` creates gets the process default; you cannot mark a file executable or backdate it from ARO.

**Limited Path Operations.** Joining paths with string concatenation works, but a proper path API would be safer.

`<Write>` overwrites, which is what we want for a page snapshot. When you want the other behaviour — a crawl log, an audit trail — reach for `<Append>` rather than reading, concatenating, and writing back. Note the shape carefully: the content goes in the `with` clause and the result name must be *fresh*, because `<Append>` binds its own result there.

```aro
Append the <log-entry> to the <file: "./output/crawl.log"> with "crawled ${<url>}\n".
```

The form you would expect — putting the content in the result slot, `Append the <log-line> to the <file: …>.` — is rejected by the immutability rule, since `<log-line>` is already bound (GitLab #580).

---

## Chapter Recap

- `Compute ... hash` generates a hash from a string
- Hash-based filenames ensure uniqueness across all URLs
- `<Create>` with `\n` builds multi-line content
- `<Write>` saves content to a file path
- Each saved file includes the source URL as metadata

---

*Next: Chapter 10 - Parallel Processing*
