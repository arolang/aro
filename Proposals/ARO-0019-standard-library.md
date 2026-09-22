# ARO-0019: Standard Library

* Proposal: ARO-0019
* Author: ARO Language Team
* Status: **Implemented**
* Requires: ARO-0001, ARO-0006

## Abstract

This proposal defines the ARO Standard Library, providing common types and utilities available in all ARO programs. ARO uses dynamic typing with type inference from literal values.

## Motivation

A standard library provides:

1. **Consistency**: Common patterns across projects
2. **Productivity**: Ready-to-use utilities
3. **Quality**: Well-tested implementations
4. **Portability**: Works across platforms

---

## 1. Primitive Types

ARO has **four** primitive types — Integer, Float, String, Boolean — and types
are inferred from literal values. `DataType` (`AROParser/SymbolTable.swift:77`)
declares exactly those four, plus `List`, `Map` and `schema(String)` for types
that come from the OpenAPI contract. ARO-0003 has always said four.

§1.5 below describes DateTime, and it is worth reading, but it is **not a fifth
primitive**: a timestamp is a String that the date qualifiers and the `<now>`
system object understand. There is no `DateTime` you can annotate, no `DateTime`
in the type checker, and a value that looks like a date is a String everywhere
except inside the operations in §5. This section said "five primitive types"
until GitLab #831.

### 1.1 Integer

Whole numbers without decimals.

```aro
(Calculate Total: Math Example) {
    Create the <quantity> with 42.
    Create the <price> with 100.
    Compute the <total> from <quantity> * <price>.
    Return an <OK: status> with <total>.
}
```

### 1.2 Float

Decimal numbers for precision calculations.

```aro
(Calculate Tax: Financial Example) {
    Create the <subtotal> with 99.99.
    Create the <tax-rate> with 0.08.
    Compute the <tax> from <subtotal> * <tax-rate>.
    Return an <OK: status> with <tax>.
}
```

### 1.3 String

Text values enclosed in double quotes.

```aro
(Greet User: String Example) {
    Create the <greeting> with "Hello, World!".
    Create the <name> with "Alice".
    Log <greeting> to the <console>.
    Return an <OK: status> with <name>.
}
```

### 1.4 Boolean

Logical true/false values.

```aro
(Check Status: Boolean Example) {
    Create the <is-active> with true.
    Create the <is-verified> with false.
    Validate the <user: status> with <is-active>.
    Return an <OK: status> for the <validation>.
}
```

### 1.5 DateTime

Date and time values for temporal operations.

```aro
(Log Event: DateTime Example) {
    Create the <timestamp> with now.
    Create the <event-name> with "UserLogin".
    Log <timestamp> to the <console>.
    Return an <OK: status> for the <event>.
}
```

---

## 2. Collections

### 2.1 List

Ordered collections of values.

```aro
(Process Users: List Example) {
    Retrieve the <users> from the <user-repository>.
    Filter the <active-users> from the <users> where status = "active".
    Map the <names> from the <active-users> with name.
    Return an <OK: status> with <names>.
}
```

### 2.2 Map (Dictionary)

Key-value associations.

```aro
(Build Response: Map Example) {
    Extract the <user-id> from the <request: id>.
    Retrieve the <user> from the <user-repository> where id = <user-id>.
    Return an <OK: status> with <user>.
}
```

---

## 3. String Operations

Strings support common operations through actions.

```aro
(Process Text: String Operations) {
    Extract the <name> from the <request: name>.
    Transform the <upper-name> from the <name> with uppercase.
    Validate the <name: format> with pattern "^[A-Za-z]+$".
    Return an <OK: status> with <upper-name>.
}
```

### 3.1 Encoding and Escaping

ARO's primary use case is contract-first HTTP APIs, which means untrusted text
routinely flows from a request into HTML, a URL, or a JSON body. These
computations make that safe. They follow the same qualifier shape as
`uppercase`/`lowercase`, so there is no new syntax.

| Qualifier | Purpose | Example |
|-----------|---------|---------|
| `html-escape` | Escape `& < > " '` for HTML output | `Compute the <safe: html-escape> from <input>.` |
| `url-encode` | Percent-encode a query-string value | `Compute the <enc: url-encode> from <query>.` |
| `url-decode` | Reverse `url-encode` | `Compute the <dec: url-decode> from <raw>.` |
| `url-resolve` | Resolve a relative URL against a base (§3.1a) | `Compute the <abs: url-resolve> from <href> with { base: <page> }.` |
| `url-defragment` | The URL without its `#fragment` (§3.1a) | `Compute the <clean: url-defragment> from <link>.` |
| `url-normalize` | One spelling of one address (§3.1a) | `Compute the <n: url-normalize> from <link>.` |
| `url-parts` | scheme, host, port, path, query, fragment (§3.1a) | `Compute the <p: url-parts> from <link>.` |
| `base64-encode` | Standard Base64 | `Compute the <b64: base64-encode> from <creds>.` |
| `base64-decode` | Reverse `base64-encode` | `Compute the <raw: base64-decode> from <b64>.` |
| `base64url-encode` | URL-safe Base64 (RFC 4648 §5) — JWTs, URL payloads | `Compute the <tok: base64url-encode> from <payload>.` |
| `base64url-decode` | Reverse `base64url-encode` | `Compute the <raw: base64url-decode> from <tok>.` |
| `json-escape` | Escape for a JSON string literal | `Compute the <esc: json-escape> from <text>.` |
| `trim` | Strip leading/trailing whitespace | `Compute the <clean: trim> from <field>.` |
| `replace` | Substring replacement | `Compute the <out: replace> from <text> with { find: "-", replace: "_" }.` |

**Why `replace` differs**: it needs two arguments, which a single qualifier
cannot carry, so it takes them from the `with` clause. `find` must be non-empty.

**Scope of `url-encode`**: it encodes for a single query *value*, so the RFC 3986
sub-delimiters (`&`, `=`, `+`, …) and `/` are all escaped. It is not for
encoding a whole path or URL, where those characters are structural.

**Decoding failures**: `url-decode` passes malformed input through unchanged,
following the happy-case philosophy. `base64-decode` and `base64url-decode`
raise a runtime error, because there is no meaningful pass-through for input
that is not valid Base64 UTF-8.

### 3.1a URLs

`url-encode` and `url-decode` escape *inside* a URL. Everything you do *to* a
URL — resolving a relative one, comparing two, taking it apart — had no
spelling, so the crawler chapter of *ARO by Example* built relative-URL
resolution out of `Split` statements and string concatenation, and the result
is wrong for several ordinary cases (GitLab #859).

| Qualifier | Answers |
|-----------|---------|
| `url-resolve` | a relative URL made absolute against a base |
| `url-defragment` | the URL without its `#fragment` |
| `url-normalize` | the same address, spelled one way |
| `url-parts` | `{ scheme, host, port, path, query, fragment }` |

```aro
Compute the <abs: url-resolve> from <href> with { base: <page-url> }.
Compute the <clean: url-defragment> from <link>.
Compute the <canonical: url-normalize> from <link>.
Compute the <parts: url-parts> from <link>.
```

The base may also be given bare — `with <page-url>` — since a single obvious
argument reads fine that way.

#### What concatenation gets wrong

Resolution is RFC 3986's, through Foundation's own resolver. These are the
three cases the hand-built version got wrong, and they are not exotic:

| Link | Concatenated | Resolved |
|------|--------------|----------|
| `../other/x.html` | `…/docs/guide/../other/x.html` | `…/docs/other/x.html` |
| `//cdn.example.org/lib.js` | `https://example.com//cdn.example.org/lib.js` | `https://cdn.example.org/lib.js` |
| `#section` | `…/page.html?x=1#top#section` | `…/page.html?x=1#section` |

An **absolute** input comes back unchanged, so resolving a page's links never
has to ask which kind each one is. Something that is not a URL at all is an
error rather than a pass-through: a silently wrong URL is the failure this
qualifier exists to remove.

#### What `url-normalize` does and does not touch

It lowercases the scheme and host, removes `.` and `..`, drops a port that is
the scheme's default, and gives an authority with no path a `/` — because
`https://example.com` and `https://example.com/` are the same resource and a
crawler comparing strings would disagree.

It leaves the **path's case** and the **query's order** exactly as written. A
path is case-sensitive on most servers and parameter order can carry meaning,
so changing either would change what the URL means rather than normalise it.

#### `url-defragment` is lexical

RFC 3986 reserves `#`, so a literal one must be written `%23` and the first raw
`#` is always where the fragment starts. Cutting there is exact, and it is also
the only way to avoid re-encoding a value the caller only asked to truncate.

Stripping the fragment is what makes two links to the same page compare equal:
a fragment is a pointer *into* a document, so two URLs differing only there are
the same request.

#### Absent parts are absent

`url-parts` omits a part the URL does not have, rather than including it empty
— the difference between "no port" and "port 0". `port` is a number.

### 3.2 Collections and Text

Aggregating a list, deduplicating it, or counting the lines of a file are
things every program does, and until GitLab #486 each of them was a
multi-statement idiom. That had a cost beyond verbosity: `aro ask` invented
`sum`, `avg`, `unique`, `lines`, `join`, `random` and `sha256` as qualifiers
2,652 times across the training corpus, because the names are the obvious ones
and the real spelling was three statements long. A primitive people keep
reaching for is a primitive the language is missing.

| Qualifier | Purpose | Example |
|-----------|---------|---------|
| `lines` | Split text into a list of lines | `Compute the <ls: lines> from <content>.` |
| `join` | Join a collection into a string | `Compute the <csv: join> from <items> with { separator: ", " }.` |
| `sum` | Total of a numeric collection | `Compute the <total: sum> from <amounts>.` |
| `avg` / `average` | Arithmetic mean | `Compute the <mean: avg> from <scores>.` |
| `unique` | Remove duplicates, first occurrence wins | `Compute the <tags: unique> from <all-tags>.` |
| `random` | A random element, or a random Int below a bound | `Compute the <pick: random> from <options>.` |
| `sha256` | SHA-256 digest, hex-encoded (alias of `hash`) | `Compute the <digest: sha256> from <payload>.` |

**Counting lines** is `lines` then `length`:

```aro
(Application-Start: Line Count) {
    Read the <content: raw> from "./sample.txt".
    Compute the <line-list: lines> from the <content>.
    Compute the <total-lines: length> from the <line-list>.
    Log <total-lines> to the <console>.
    Return an <OK: status> for the <run>.
}
```

`lines` does not emit a phantom empty element for the trailing newline, and it
treats `\r\n` as one terminator. Both are deliberate: the hand-rolled
`trim` → `Split` → `length` idiom this replaces answers 4 for a 3-line file if
the `trim` is forgotten, which is exactly the kind of off-by-one a primitive
should absorb rather than delegate.

**Numeric results keep their type**: `sum` of a list of integers is an integer,
so it logs as `6` rather than `6.0`. `avg` is always a Float — averaging
integers rarely yields one, and truncating silently would be worse than a
decimal point.

**Empty collections**: `sum` of nothing is `0`. `avg` and `random` of nothing
are runtime errors, because neither has a defensible answer.

### 3.2.1 Money: the `fixed` Qualifier

| Qualifier | Purpose | Example |
|-----------|---------|---------|
| `fixed` | Round to a fixed number of decimal places (2 by default) | `Compute the <total: fixed> from the <raw-total>.` |

`Compute the <total> from <qty> * <price>.` with `3` and `2.40` produces
`7.199999999999999`. Human-facing output has hidden that since GitLab #474 —
console rendering is 15 significant digits, so it prints `7.2` — but files do
not and must not: `Write` and HTTP response bodies serialize at full precision.
A gold-layer CSV built from float arithmetic therefore shipped
`99.94999999999999` in its revenue column, and the analyst who opened it had a
question. That is GitLab #517, in the language's own core demographic.

`fixed` moves the correction from the renderer to the *value*. It rounds through
the decimal spelling, so the stored `Double` is the one nearest to `99.95` — and
every downstream path then agrees about it: console, JSON, CSV, and any
arithmetic that reads it back.

```aro
Reduce the <raw-revenue> from the <rows> with sum(<line_total>).
Compute the <revenue: fixed> from the <raw-revenue>.        (* 99.95 *)
Compute the <precise: fixed> from the <rate> with { places: 4 }.
```

The place count comes from `with { places: N }` (or the bare `with N`), is 2
without one, and must be 0…15. **The result stays numeric.** Returning a
rendered string would print correctly and then quote itself into a JSON data
product, which is a different wrong answer.

Round each amount once, where it is produced, to the precision that amount
actually has. Rounding the *same* quantity twice at different precisions is how
two reports come to disagree by a penny; re-applying `fixed` after a `sum` of
already-rounded values is not that — it is the cleanup floating-point addition
still needs. Holding money in integer minor units through the pipeline and
dividing at the end remains available and is the stricter choice for ledgers.

`round`, `money`, `currency` and `precision` are not qualifiers; each redirects
to `fixed` by name at check time, because edit distance would never find it
from "money". Capitalisation decides which advice applies: `Money` written
PascalCase is ARO-0014's domain *type*, and is still redirected to the `as`
clause (`Compute the <cost> as Money from …`) rather than to `fixed`.

### 3.3 The Qualifier Namespace Is Closed

A Compute qualifier resolves to exactly one of:

1. a built-in from the table above and §3.1,
2. a registered plugin qualifier, written `handle.qualifier`,
3. a chain of the above, written `a|b`,
4. a date offset, written `-7d` / `+24h`.

Anything else is an error, and `aro check` reports it — the program never gets
as far as running. It used to return the input unchanged, which meant every
misspelled or invented qualifier produced a program that compiled, passed
`aro check`, exited `[OK]`, and printed the wrong value:

```aro
(* Before #486: logged the whole file. After: "Unknown Compute qualifier
   'linecount'", at check time. *)
Compute the <total: linecount> from the <content>.
```

The diagnostic names the qualifier and suggests the closest registered one, so
a typo is recoverable without consulting the table. `aro actions --qualifiers`
lists the live set; `--format json` emits it for tooling.

Case 2 cannot be judged without loading plugins, which `aro check` does not
do, so a namespaced name is accepted at check time and resolved at run time.
Everything else is decided statically (GitLab #465) — a green `aro check` is
only worth something if it means the qualifier exists.

A chain applies its stages left to right — `trim|uppercase` trims, then
uppercases — with each stage resolved exactly like a lone qualifier, so
built-ins and plugin qualifiers mix freely (`lines|length`,
`stats.sort|take`). The statement's `with` clause is shared by every stage
that reads one. Chains are validated stage by stage: a stage `aro check` can
judge follows the rules above and an unknown one is reported by name, with
the chain it sat in for context; a namespaced stage is deferred to run time
like any other plugin qualifier (GitLab #492). An empty stage (`trim|`) is an
error in both places — a `|` needs a qualifier on both sides. (The runtime's
stage resolution also accepts a date offset, but the written form `date|+1d`
does not parse yet — the qualifier grammar accepts an offset only as the
whole qualifier.)

Two spellings are commonly confused with a qualifier, and the diagnostic names
both. Sorting, reversing and element access are *actions*, not qualifiers:

```aro
Sort the <sorted> for the <numbers>.          (* not <sorted: sort> *)
Reverse the <flipped> for the <numbers>.      (* not <flipped: reverse> *)
Extract the <head: first> from the <numbers>. (* the qualifier goes on Extract *)
```

Sort also orders record lists by a field (ARO-0002 §Ordering, GitLab #491):
`Sort the <ranked> from the <users> by <score>.` — string form `by "score"`
and trailing `descending` both accepted; the field's values must be uniformly
numeric or uniformly strings. What Sort cannot order is an error, never a
silent pass-through.

And a result *type* is requested with `as`, never in the qualifier slot, which
selects an operation (GitLab #475):

```aro
Compute the <shipping-cost> as Money from { weight: <w>, zone: <z> }.
```

```aro
(searchProducts: Product API) {
    Extract the <q> from the <queryParameters: q>.

    (* Safe upstream call: `&` in q can no longer corrupt the query string *)
    Compute the <enc: url-encode> from <q>.
    Compute the <target> from "https://upstream.example.com/search?q=" ++ <enc>.
    Request the <results> from the <url: target>.

    (* Safe rendering: a <script> in q is inert *)
    Compute the <safe: html-escape> from <q>.
    Create the <ctx> with { query: <safe>, results: <results> }.
    Transform the <page> from the <template: results.html> with <ctx>.
    Return an <OK: status> with <page>.
}
```

---

## 4. Date and Time

DateTime operations for temporal logic.

```aro
(Schedule Event: DateTime Operations) {
    Create the <start-time> with now.
    Compute the <end-time: +1h> from the <start-time>.
    Log <start-time> to the <console>.
    Return an <OK: status> for the <schedule>.
}
```

---

## 5. Math Operations

Mathematical computations via the `<Compute>` action.

```aro
(Calculate Statistics: Math Example) {
    Retrieve the <values> from the <data-source>.
    Reduce the <sum: Integer> from the <values> with sum().
    Reduce the <average: Float> from the <values> with avg().
    Reduce the <count: Integer> from the <values> with count().
    Return an <OK: status> with <average>.
}
```

---

## 6. JSON Operations

JSON is handled automatically by the runtime for HTTP requests and responses.

```aro
(Parse Request: JSON Example) {
    Extract the <data> from the <request: body>.
    Extract the <name> from the <data: name>.
    Extract the <email> from the <data: email>.
    Create the <user> with <data>.
    Return a <Created: status> with <user>.
}
```

---

## 7. Type Summary

| Type | Literal Example | Description |
|------|-----------------|-------------|
| Integer | `42`, `-10`, `0` | Whole numbers |
| Float | `3.14`, `0.5`, `-2.7` | Decimal numbers |
| String | `"Hello"`, `"World"` | Text values |
| Boolean | `true`, `false` | Logical values |
| DateTime | `now` | Current timestamp |
| List | (from actions) | Ordered collections |
| Map | (from actions) | Key-value pairs |

---

## Implementation Notes

ARO uses dynamic typing with type inference. The Swift runtime maps ARO values to Swift types:

| ARO Type | Swift Type |
|----------|------------|
| Integer | `Int` |
| Float | `Double` |
| String | `String` |
| Boolean | `Bool` |
| DateTime | `Date` |
| List | `[any Sendable]` |
| Map | `[String: any Sendable]` |

---

## Implementation Location

Primitive types are handled throughout the runtime:

- `Sources/ARORuntime/Actions/BuiltIn/OwnActions.swift` - CreateAction, ComputeAction
- `Sources/ARORuntime/Actions/BuiltIn/QueryActions.swift` - MapAction, ReduceAction, FilterAction
- `Sources/ARORuntime/Core/ExecutionContext.swift` - Variable binding with type inference
- `Sources/AROParser/Lexer.swift` - Literal parsing (strings, numbers, booleans)

---

## Revision History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2024-01 | Initial specification |
| 1.1 | 2024-12 | Simplified to core primitives (Integer, Float, String, Boolean, DateTime), removed Result type, added ARO examples |
| 1.2 | 2026-08 | Added §3.1 Encoding and Escaping: html-escape, url-encode/decode, base64(url)-encode/decode, json-escape, trim, replace (GitLab #482) |
| 1.3 | 2026-08 | Added §3.2 Collections and Text: lines, join, sum, avg/average, unique, random, sha256; §3.3 declares the qualifier namespace closed — an unregistered qualifier is now an error instead of a silent identity (GitLab #486) |
| 1.4 | 2026-08 | §3.3: the closed namespace is enforced at check time, not only at run time; documents the action forms (Sort/Reverse/Extract) and the `as Type` spelling that are mistaken for qualifiers (GitLab #465) |
| 1.5 | 2026-09 | §3.3: chains (`a\|b`) run — stages apply left to right through the same resolution as a lone qualifier, mixing built-ins, plugin qualifiers and date offsets; check time validates chains stage by stage and an unknown or empty stage is reported by name (GitLab #492) |
