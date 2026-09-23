# GuardsAndDefaults

Four things ARO could not say, and now can (GitLab #830).

Each was a documented gap: the books carried a paragraph explaining how to work
around it. A workaround in a book is a measurement — it says the language could
not express the thing, and somebody had to explain the detour.

## 1. A default for an absent value

```aro
Extract the <port> from the <env: ARO_DEMO_PORT> default "8080".
```

An unset environment variable bound `""`, silently, with no way to say what it
should be instead. Every reader then wrote `when <x> == ""`, which is the
condition in the wrong place and once per reader.

Only an **unset** variable takes the default. `ARO_DEMO_PORT=` sets it to the
empty string, and that is a value somebody wrote — it wins. This is the same
rule the `default` operator follows for `false`, `0` and `""` (GitLab #547);
defaulting on falsiness is a footgun ARO declines.

The clause works for `<parameter: NAME>` too, where an absent parameter would
otherwise fail the statement.

## 2. Affix and membership guards

```aro
Compute the <path> from "/api/users".
Create the <blocked> with ["/admin"].
Create the <files> with [{ name: "main.aro" }].
Log "routed to the API" to the <console> when <path> starts with "/api".
Log "path is allowed" to the <console> when <path> not in <blocked>.
Filter the <sources> from the <files> where <name> ends with ".aro".
```

`where` had `in` and `not in`; `when` had only `in`. Neither had `starts with`
or `ends with`, so a prefix test was written as `matches "^/api"` — a regex,
which quietly accepts more than it looks like it does the moment the prefix
contains a `.` or a `?`. `starts with` is literal.

`starts` and `ends` are **not** reserved words. Only a following `with`, in
operator position, makes them an operator, so `<starts>` and `<ends>` remain
names you can use.

## 3. A guarded Publish

```aro
Compute the <score> from 90.
Publish as <headline-score> <score> when <score> > 50.
```

Publishing is an effect like any other, and it was the one effect that could not
say "only if". A false guard leaves the name **unpublished** — not published
with a placeholder — so a reader fails the way an absent binding always fails.

## 4. Two copies in one feature set

<!-- aro-check: skip — a two-statement fragment; the whole program is main.aro -->
```aro
Copy the <backup-a: "demo-a.txt"> to the <destination: "demo-a.bak">.
Copy the <backup-b: "demo-b.txt"> to the <destination: "demo-b.bak">.
```

The result slot is a binding whose name the author picks. It used to have to be
the literal word `file` or `directory`, so a second `Copy` in one feature set
rebound `file` and was an immutability error — with the taught workaround being
to split the two copies across feature sets. The old spelling still works; it is
now simply the case where the chosen name happens to be `file`.

## Also fixed, though not visible here

`Return a <TooManyRequests: status>` answered **200**. So did `Unprocessable`,
`MethodNotAllowed` and `Unavailable` — and so did `NotFoudn`, because the name
was never looked up: two hard-coded switches mapped a handful of names and fell
through to 200. Both now read one catalog, and a name within a typo's distance
of a real one is a check-time warning. A deliberate domain status
(`<PendingVerification: status>`, ARO-0002 §7) is still a 200 and still silent.

## Usage

```bash
aro run ./Examples/GuardsAndDefaults
aro build ./Examples/GuardsAndDefaults && ./Examples/GuardsAndDefaults/GuardsAndDefaults
```

Both modes print the same thing; the example cleans up the files it writes.

## Related

- [ARO-0001: Language Fundamentals](../../Proposals/ARO-0001-language-fundamentals.md) — operators
- [ARO-0018: Data Pipelines](../../Proposals/ARO-0018-query-language.md) — where clauses
- [ARO-0036: File Operations](../../Proposals/ARO-0036-file-operations.md) — Copy, Move
- [GitLab #830](https://github.com/arolang/aro/issues/830) — the full list of fifteen gaps
