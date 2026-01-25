# Chapter 7: URL Normalization

*"A link that says '/about' means different things on different websites."*

---

## What We Will Learn

- Why URL normalization is necessary
- Pattern matching with `match` and regex
- String interpolation for building URLs
- Handling different URL types
- Building the normalization handler

---

## 7.1 The Problem

Links in HTML come in many forms:

| Type | Example | Meaning |
|------|---------|---------|
| Absolute | `https://example.com/page` | Full URL, use as-is |
| Root-relative | `/about` | Relative to domain root |
| Path-relative | `../sibling` | Relative to current path |
| Fragment | `#section` | Same page anchor |
| Special | `mailto:user@example.com` | Not a web page |

Our crawler needs absolute URLs. We must convert relative URLs and skip non-web URLs.

---

## 7.2 The Architectural Decision

**Our Choice:** A separate handler for normalization, using pattern matching.

**Alternative Considered:** We could normalize inline in the extraction handler. However, normalization logic is complex enough to warrant its own handler. Separating it makes the code easier to test and modify.

**Why This Approach:** Pattern matching is perfect for URL classification. Each URL type has a distinct pattern. A dedicated handler keeps the extraction handler clean and makes the normalization rules explicit.

---

## 7.3 Pattern Matching with Regex

ARO's `match` expression supports regex patterns:

```aro
match <value> {
    case /^https?:\/\// {
        (* Matches http:// or https:// at start *)
    }
    case /^\// {
        (* Matches / at start *)
    }
    case /^#/ {
        (* Matches # at start *)
    }
}
```

The `/pattern/` syntax creates a regex. The pattern is matched against the value. Only the first matching case executes.

---

## 7.4 Building the Normalization Handler

Add to `links.aro`:

```aro
(Normalize URL: NormalizeUrl Handler) {
    (* Extract from event data structure *)
    <Extract> the <event-data> from the <event: data>.
    <Extract> the <raw-url> from the <event-data: raw>.
    <Extract> the <source-url> from the <event-data: source>.
    <Extract> the <base-domain> from the <event-data: base>.

    <Return> an <OK: status> for the <normalization>.
}
```

The event carries:

- `raw` — The raw href value to normalize
- `source` — The page URL (for path-relative resolution, not used here)
- `base` — The base domain (for root-relative URLs)

---

## 7.5 Handling Absolute URLs

Absolute URLs need no transformation:

```aro
(Normalize URL: NormalizeUrl Handler) {
    <Extract> the <event-data> from the <event: data>.
    <Extract> the <raw-url> from the <event-data: raw>.
    <Extract> the <source-url> from the <event-data: source>.
    <Extract> the <base-domain> from the <event-data: base>.

    (* Determine URL type and normalize *)
    match <raw-url> {
        case /^https?:\/\// {
            (* Already absolute URL *)
            <Emit> a <FilterUrl: event> with { url: <raw-url>, base: <base-domain> }.
        }
    }

    <Return> an <OK: status> for the <normalization>.
}
```

If the URL starts with `http://` or `https://`, we emit it directly to the filter stage.

---

## 7.6 Handling Root-Relative URLs

Root-relative URLs like `/about` need the base domain prepended:

```aro
    match <raw-url> {
        case /^https?:\/\// {
            <Emit> a <FilterUrl: event> with { url: <raw-url>, base: <base-domain> }.
        }
        case /^\/$/ {
            (* Just "/" means root - use base domain as-is *)
            <Emit> a <FilterUrl: event> with { url: <base-domain>, base: <base-domain> }.
        }
        case /^\// {
            (* Root-relative URL: prepend base domain *)
            <Create> the <absolute-url> with "${<base-domain>}${<raw-url>}".
            <Emit> a <FilterUrl: event> with { url: <absolute-url>, base: <base-domain> }.
        }
    }
```

Note the two cases for `/`:

- `/^\/$` — Exactly "/" (just the root)
- `/^\//` — Starts with "/" (like "/about")

The order matters: more specific patterns first.

String interpolation combines base and path: `"${<base-domain>}${<raw-url>}"` produces `"https://example.com/about"`.

---

## 7.7 Skipping Special URLs

Fragments and special schemes should not be crawled:

```aro
    match <raw-url> {
        case /^https?:\/\// {
            <Emit> a <FilterUrl: event> with { url: <raw-url>, base: <base-domain> }.
        }
        case /^\/$/ {
            <Emit> a <FilterUrl: event> with { url: <base-domain>, base: <base-domain> }.
        }
        case /^\// {
            <Create> the <absolute-url> with "${<base-domain>}${<raw-url>}".
            <Emit> a <FilterUrl: event> with { url: <absolute-url>, base: <base-domain> }.
        }
        case /^(#|mailto:|javascript:|tel:|data:)/ {
            (* Skip fragments and special URLs - do nothing *)
        }
    }
```

The last case matches:

- `#` — Fragment links (same page)
- `mailto:` — Email links
- `javascript:` — JavaScript links
- `tel:` — Phone links
- `data:` — Data URLs

For these, we do nothing—no emit, no error. They silently disappear from the pipeline.

---

## 7.8 The Complete Handler

```aro
(Normalize URL: NormalizeUrl Handler) {
    (* Extract from event data structure *)
    <Extract> the <event-data> from the <event: data>.
    <Extract> the <raw-url> from the <event-data: raw>.
    <Extract> the <source-url> from the <event-data: source>.
    <Extract> the <base-domain> from the <event-data: base>.

    (* Determine URL type and normalize *)
    match <raw-url> {
        case /^https?:\/\// {
            (* Already absolute URL *)
            <Emit> a <FilterUrl: event> with { url: <raw-url>, base: <base-domain> }.
        }
        case /^\/$/ {
            (* Just "/" means root - use base domain as-is (no trailing slash) *)
            <Emit> a <FilterUrl: event> with { url: <base-domain>, base: <base-domain> }.
        }
        case /^\// {
            (* Root-relative URL: prepend base domain *)
            <Create> the <absolute-url> with "${<base-domain>}${<raw-url>}".
            <Emit> a <FilterUrl: event> with { url: <absolute-url>, base: <base-domain> }.
        }
        case /^(#|mailto:|javascript:|tel:|data:)/ {
            (* Skip fragments and special URLs *)
        }
    }

    <Return> an <OK: status> for the <normalization>.
}
```

---

## 7.9 What About Path-Relative URLs?

You may have noticed we do not handle path-relative URLs like `../sibling` or `page.html`. These are more complex to resolve correctly (they depend on the current path, not just the domain).

For simplicity, our crawler skips them. They fall through the `match` without emitting an event. In a production crawler, you would add another case with proper path resolution.

---

## 7.10 What ARO Does Well Here

**Powerful Pattern Matching.** Regex cases make URL classification clean and readable. Each case handles one type.

**String Interpolation.** Building URLs with `"${<base>}${<path>}"` is intuitive. No string concatenation operators.

**Silent Filtering.** Unwanted URLs disappear by simply not emitting events. No explicit filter or discard action needed.

---

## 7.11 What Could Be Better

**No URL Utilities.** ARO has no built-in URL parsing. We use regex and string concatenation. A proper URL type with methods like `resolve()` would be cleaner.

**Limited Regex Features.** The regex syntax is basic. Advanced features like named groups are not available.

---

## Chapter Recap

- URLs come in many forms: absolute, root-relative, path-relative, fragments, special schemes
- `match` with regex patterns classifies URLs cleanly
- String interpolation `"${<var>}"` builds absolute URLs
- Non-web URLs are filtered by not emitting events
- We skip path-relative URLs for simplicity

---

*Next: Chapter 8 - URL Filtering*
