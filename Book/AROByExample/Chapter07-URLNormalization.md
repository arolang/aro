# Chapter 7: URL Normalization

*"A link that says '/about' means different things on different websites."*

---

## What We Will Learn

- Why URL normalization is necessary
- Pattern matching with `match` and regex
- Splitting strings with the `<Split>` action and regex delimiters
- String interpolation for building URLs
- Stripping URL fragments and trailing slashes for deduplication
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

Absolute URLs are already complete, but they still need cleaning. Consider these two URLs:

- `https://example.com/page#section`
- `https://example.com/page`

From a crawler's perspective, these point to the same page. The `#section` fragment is a client-side anchor -- the server returns identical content for both. If we do not strip fragments, our deduplication logic will treat them as different pages and crawl the same content twice.

Similarly, `https://example.com/page/` and `https://example.com/page` are typically the same resource. Trailing slashes create duplicate entries in our visited set.

```aro
(Normalize URL: NormalizeUrl Handler) {
    <Extract> the <event-data> from the <event: data>.
    <Extract> the <raw-url> from the <event-data: raw>.
    <Extract> the <source-url> from the <event-data: source>.
    <Extract> the <base-domain> from the <event-data: base>.

    (* Determine URL type and normalize *)
    match <raw-url> {
        case /^https?:\/\// {
            (* Already absolute URL - strip fragment and trailing slash *)
            <Split> the <frag-parts> from the <raw-url> by /#/.
            <Extract> the <no-fragment: first> from the <frag-parts>.
            <Split> the <slash-parts> from the <no-fragment> by /\/+$/.
            <Extract> the <clean-url: first> from the <slash-parts>.
            <Emit> a <FilterUrl: event> with { url: <clean-url>, base: <base-domain> }.
        }
    }

    <Return> an <OK: status> for the <normalization>.
}
```

If the URL starts with `http://` or `https://`, we clean it before emitting to the filter stage. The cleaning happens in two steps:

1. **Strip fragments:** Split on `#` and take the first part. `https://example.com/page#section` becomes `https://example.com/page`.
2. **Strip trailing slashes:** Split on a trailing `/` pattern and take the first part. `https://example.com/page/` becomes `https://example.com/page`.

---

## 7.6 The Split Action

The cleaning logic above introduces a new action: `<Split>`. It splits a string into a list using a regex delimiter:

```aro
<Split> the <parts> from the <string> by /regex/.
```

The result is a list of substrings. You can then use `<Extract>` with the `first` specifier to get the first element:

```aro
<Split> the <parts> from the <url> by /#/.
<Extract> the <before-hash: first> from the <parts>.
```

Given `"https://example.com/page#section"`, the split on `/#/` produces `["https://example.com/page", "section"]`. Extracting the first element gives us `"https://example.com/page"` -- the URL without its fragment.

For trailing slash removal, we split on the pattern `/\/+$/`, which matches one or more slashes at the end of the string:

```aro
<Split> the <parts> from the <url> by /\/+$/.
<Extract> the <clean: first> from the <parts>.
```

Given `"https://example.com/page/"`, the split produces `["https://example.com/page"]`. If there is no trailing slash, the split produces the original string as a single-element list, so the logic works in both cases.

---

## 7.7 Handling Root-Relative URLs

Root-relative URLs like `/about` need the base domain prepended. After joining, we apply the same fragment and trailing slash cleaning as absolute URLs:

```aro
    match <raw-url> {
        case /^https?:\/\// {
            (* Already absolute URL - strip fragment and trailing slash *)
            <Split> the <frag-parts> from the <raw-url> by /#/.
            <Extract> the <no-fragment: first> from the <frag-parts>.
            <Split> the <slash-parts> from the <no-fragment> by /\/+$/.
            <Extract> the <clean-url: first> from the <slash-parts>.
            <Emit> a <FilterUrl: event> with { url: <clean-url>, base: <base-domain> }.
        }
        case /^\/$/ {
            (* Just "/" means root - use base domain as-is (no trailing slash) *)
            <Emit> a <FilterUrl: event> with { url: <base-domain>, base: <base-domain> }.
        }
        case /^\// {
            (* Root-relative URL: prepend base domain, strip fragment and trailing slash *)
            <Create> the <joined-url> with "${<base-domain>}${<raw-url>}".
            <Split> the <frag-parts> from the <joined-url> by /#/.
            <Extract> the <no-fragment: first> from the <frag-parts>.
            <Split> the <slash-parts> from the <no-fragment> by /\/+$/.
            <Extract> the <clean-url: first> from the <slash-parts>.
            <Emit> a <FilterUrl: event> with { url: <clean-url>, base: <base-domain> }.
        }
    }
```

Note the three cases:

- `/^\/$` — Exactly "/" (just the root). The base domain already has no trailing slash, so we emit it directly.
- `/^\//` — Starts with "/" (like "/about" or "/about#team"). After joining with the base domain, we clean fragments and trailing slashes.
- The absolute URL case now also includes the cleaning steps.

The order matters: more specific patterns first.

String interpolation combines base and path: `"${<base-domain>}${<raw-url>}"` produces `"https://example.com/about"`. A URL like `/about/#team` would become `"https://example.com/about/#team"`, then after cleaning: `"https://example.com/about"`.

---

## 7.8 Skipping Special URLs

Fragments and special schemes should not be crawled:

```aro
    match <raw-url> {
        case /^https?:\/\// {
            (* Already absolute URL - strip fragment and trailing slash *)
            <Split> the <frag-parts> from the <raw-url> by /#/.
            <Extract> the <no-fragment: first> from the <frag-parts>.
            <Split> the <slash-parts> from the <no-fragment> by /\/+$/.
            <Extract> the <clean-url: first> from the <slash-parts>.
            <Emit> a <FilterUrl: event> with { url: <clean-url>, base: <base-domain> }.
        }
        case /^\/$/ {
            (* Just "/" means root - use base domain as-is (no trailing slash) *)
            <Emit> a <FilterUrl: event> with { url: <base-domain>, base: <base-domain> }.
        }
        case /^\// {
            (* Root-relative URL: prepend base domain, strip fragment and trailing slash *)
            <Create> the <joined-url> with "${<base-domain>}${<raw-url>}".
            <Split> the <frag-parts> from the <joined-url> by /#/.
            <Extract> the <no-fragment: first> from the <frag-parts>.
            <Split> the <slash-parts> from the <no-fragment> by /\/+$/.
            <Extract> the <clean-url: first> from the <slash-parts>.
            <Emit> a <FilterUrl: event> with { url: <clean-url>, base: <base-domain> }.
        }
        case /^(#|mailto:|javascript:|tel:|data:)/ {
            (* Skip fragments and special URLs *)
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

## 7.9 The Complete Handler

```aro
(Normalize URL: NormalizeUrl Handler) {
    <Extract> the <event-data> from the <event: data>.
    <Extract> the <raw-url> from the <event-data: raw>.
    <Extract> the <source-url> from the <event-data: source>.
    <Extract> the <base-domain> from the <event-data: base>.

    match <raw-url> {
        case /^https?:\/\// {
            (* Already absolute URL - strip fragment and trailing slash *)
            <Split> the <frag-parts> from the <raw-url> by /#/.
            <Extract> the <no-fragment: first> from the <frag-parts>.
            <Split> the <slash-parts> from the <no-fragment> by /\/+$/.
            <Extract> the <clean-url: first> from the <slash-parts>.
            <Emit> a <FilterUrl: event> with { url: <clean-url>, base: <base-domain> }.
        }
        case /^\/$/ {
            (* Just "/" means root - use base domain as-is (no trailing slash) *)
            <Emit> a <FilterUrl: event> with { url: <base-domain>, base: <base-domain> }.
        }
        case /^\// {
            (* Root-relative URL: prepend base domain, strip fragment and trailing slash *)
            <Create> the <joined-url> with "${<base-domain>}${<raw-url>}".
            <Split> the <frag-parts> from the <joined-url> by /#/.
            <Extract> the <no-fragment: first> from the <frag-parts>.
            <Split> the <slash-parts> from the <no-fragment> by /\/+$/.
            <Extract> the <clean-url: first> from the <slash-parts>.
            <Emit> a <FilterUrl: event> with { url: <clean-url>, base: <base-domain> }.
        }
        case /^(#|mailto:|javascript:|tel:|data:)/ {
            (* Skip fragments and special URLs *)
        }
    }

    <Return> an <OK: status> for the <normalization>.
}
```

---

## 7.10 What About Path-Relative URLs?

You may have noticed we do not handle path-relative URLs like `../sibling` or `page.html`. These are more complex to resolve correctly (they depend on the current path, not just the domain).

For simplicity, our crawler skips them. They fall through the `match` without emitting an event. In a production crawler, you would add another case with proper path resolution.

---

## 7.11 What ARO Does Well Here

**Powerful Pattern Matching.** Regex cases make URL classification clean and readable. Each case handles one type.

**String Splitting with Regex.** The `<Split>` action with regex delimiters handles fragment stripping and trailing slash removal cleanly. Splitting on `/#/` and `/\/+$/` is concise and expressive.

**String Interpolation.** Building URLs with `"${<base>}${<path>}"` is intuitive. No string concatenation operators.

**Silent Filtering.** Unwanted URLs disappear by simply not emitting events. No explicit filter or discard action needed.

---

## 7.12 What Could Be Better

**No URL Utilities.** ARO has no built-in URL parsing. We handle fragment stripping and trailing slashes with `<Split>`, but a proper URL type with methods like `resolve()`, `stripFragment()`, and `normalize()` would consolidate what currently takes four lines into one.

**Limited Regex Features.** The regex syntax is basic. Advanced features like named groups are not available.

---

## Chapter Recap

- URLs come in many forms: absolute, root-relative, path-relative, fragments, special schemes
- `match` with regex patterns classifies URLs cleanly
- `<Split>` with regex delimiters breaks strings into lists -- useful for stripping URL fragments and trailing slashes
- `<Extract> first` retrieves the first element from a list produced by `<Split>`
- Fragment stripping (`#section`) and trailing slash removal prevent duplicate crawling of the same page
- String interpolation `"${<var>}"` builds absolute URLs from base domain and path
- Non-web URLs are filtered by not emitting events
- We skip path-relative URLs for simplicity

---

*Next: Chapter 8 - URL Filtering*
