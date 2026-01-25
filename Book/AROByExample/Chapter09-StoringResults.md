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
    <Extract> the <event-data> from the <event: data>.
    <Extract> the <url> from the <event-data: url>.
    <Extract> the <title> from the <event-data: title>.
    <Extract> the <content> from the <event-data: content>.

    <Return> an <OK: status> for the <save>.
}
```

The event carries:

- `url` — The page URL (for metadata)
- `title` — The page title (from HTML)
- `content` — The Markdown content

---

## 9.4 Computing the Hash

Add the hash computation:

```aro
(Save Page: SavePage Handler) {
    <Extract> the <event-data> from the <event: data>.
    <Extract> the <url> from the <event-data: url>.
    <Extract> the <title> from the <event-data: title>.
    <Extract> the <content> from the <event-data: content>.

    (* Use URL hash as filename *)
    <Compute> the <url-hash: hash> from the <url>.
    <Create> the <file-path> with "./output/${<url-hash>}.md".

    <Log> "Saving: ${<url>} to ${<file-path>}" to the <console>.

    <Return> an <OK: status> for the <save>.
}
```

The `<Compute> ... hash` operation generates a hash from the URL string. We then build the file path using string interpolation.

---

## 9.5 Formatting the Content

We want each file to include metadata about the source:

```aro
    (* Previous code... *)

    (* Format markdown file with frontmatter *)
    <Create> the <file-content> with "# ${<title>}\n\n**Source:** ${<url>}\n\n---\n\n${<content>}".
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
    <Write> the <file-content> to the <file: file-path>.

    <Return> an <OK: status> for the <save>.
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
    <Extract> the <event-data> from the <event: data>.
    <Extract> the <url> from the <event-data: url>.
    <Extract> the <title> from the <event-data: title>.
    <Extract> the <content> from the <event-data: content>.

    (* Use URL hash as filename *)
    <Compute> the <url-hash: hash> from the <url>.
    <Create> the <file-path> with "./output/${<url-hash>}.md".

    <Log> "Saving: ${<url>} to ${<file-path>}" to the <console>.

    (* Format markdown file with frontmatter *)
    <Create> the <file-content> with "# ${<title>}\n\n**Source:** ${<url>}\n\n---\n\n${<content>}".

    (* Write content to file *)
    <Write> the <file-content> to the <file: file-path>.

    <Return> an <OK: status> for the <save>.
}
```

---

## 9.8 Output Examples

After running the crawler, your output directory might contain:

```
output/
├── 5d41402a.md
├── 7b52009b.md
├── 2c624232.md
└── ...
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

**No File Metadata.** We cannot set file permissions, timestamps, or other metadata. The file is written with default settings.

**No Append Mode.** `<Write>` always overwrites. If we wanted to append to a log file, we would need a different approach.

**Limited Path Operations.** Joining paths with string concatenation works, but a proper path API would be safer.

---

## Chapter Recap

- `<Compute> ... hash` generates a hash from a string
- Hash-based filenames ensure uniqueness across all URLs
- `<Create>` with `\n` builds multi-line content
- `<Write>` saves content to a file path
- Each saved file includes the source URL as metadata

---

*Next: Chapter 10 - Parallel Processing*
