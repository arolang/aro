# Wiki Corrections

**Status: applied.** All ten corrections below are in the wiki as of wiki
commit `c01c1ed`, *docs: correct the pages that disagree with the code
(GitLab #835)* — fourteen pages edited, three added. This file is kept
because it is the evidence: for each page, what it said, what is true, and
where in `Sources/` that was checked.

The wiki is a separate git repository, so the edits could not travel in the
same merge request as the code they describe. The GitHub copy
(`https://github.com/arolang/aro.wiki.git`) mirrors the GitLab wiki and needs
whatever sync produced its *sync from GitLab wiki* commits re-run to catch up.

The three *new* pages were added from their repository originals, under the
`Reference-` naming the wiki already uses, and linked from `_Sidebar.md`:

- `WIKI_CLI_REFERENCE.md` -> **Reference-CLI**
- `WIKI_ENVIRONMENT_VARIABLES.md` -> **Reference-Environment-Variables**
- `WIKI_CONFIGURATION_KEYS.md` -> **Reference-Configuration-Keys**

Tracked as GitLab #835.

## What changed against this document while applying it

Two of the ten read differently once the code was checked, and the wiki says
what the code does rather than what this file predicted:

- **Correction 3 (`Transform ... with`)** is neither "a modified copy" nor
  "the `with` clause is ignored". `TransformAction.validPrepositions` is
  `[.from, .into, .to]` — there is no `with` clause to ignore, and the
  statement is rejected. What Transform does is a type conversion chosen by
  its *result* qualifier (`string`, `int`, `double`, `bool`, `json`; anything
  else is identity), or a template render when the object is
  `<template: path>`. Every page that showed a patch form now shows `Merge`.
- **Correction 6 (HTTP client)** is not "both, per platform". `RequestAction`
  uses `URLSessionHTTPClient` on macOS *and* Linux (through
  `FoundationNetworking` there), deliberately — the comment in the code says
  the NIO client can block on a semaphore under a compiled binary's
  sync-to-async bridging. `AROHTTPClient` (AsyncHTTPClient/NIO) serves
  outbound OpenAPI callbacks. Windows has no client at all (#681).

One correction was declined as wrong: **correction 7** asked to delete
Language-Tour's claim that `Compute` with no qualifier returns its input
unchanged. That claim is true — `resolveOperationName` falls back to
`identity`. What is a check-time error is an *unknown* qualifier, which is a
different sentence; the page now distinguishes the two.

## Still open, and deliberately not touched

- Guide-Actions' HTTP status table still says an unrecognised name "falls
  through to 200 OK". `HTTPStatusCatalog` is the single source now and a
  misspelling is a check warning (GitLab #830). Outside these ten.
- Installation's Windows native-compilation section contradicts the README's
  Platform Support table, where `aro build` is unsupported on Windows
  (GitLab #613).
- `Transform the <users: List> from ...` in Guide-Variables and
  Guide-The-Basics: `List` is not a conversion, so those are identity. They
  read as type hints in prose rather than as a `with` clause, so correction 3
  does not reach them.
- Issue links pointing at `git.ausdertechnik.de` remain on several pages that
  predate this pass; readers cannot reach that host.

---

## 1. Publish scope — Guide-Actions is wrong

**Guide-Actions** says a published variable "can be accessed from any feature
set" and calls the registry global and persistent.

**True**: two conditions gate it, both enforced in
`Core/ExecutionEngine.swift:1517`.

1. The reader's **business activity** must equal the publisher's (an empty
   activity on either side passes — that is how framework lookups work).
2. The symbol lives only as long as the **publishing execution**.
   `evict(executionId:)` drops it when that feature set returns, on the success,
   default and error paths alike (`Core/FeatureSetExecutor.swift:212`).
   `Application-Start` is the exception: its publications last for the process.

A reader in a different activity gets a named error:

```
Variable 'user-config' is not accessible from 'Ready Handler':
it was published in 'Order Service'
```

Language-Tour, Guide-Feature-Sets and Guide-User-Defined-Actions already say
this. Replace the Guide-Actions paragraph with the two conditions and the error
text; `Examples/Scoping` is the worked example.

## 2. A `Retrieve` that matches nothing does not throw

**Guide-Variables** says "Retrieve throws automatically if no record matches",
and Guide-Type-System implies it.

**True**: it binds an **empty list** (`ExtractAction.swift:860`). With a `where`
clause matching exactly one row it binds that record rather than a one-element
list (`:848`), so the shape depends on the match count: 0 → `[]`, 1 → the
record, n → a list. The only throw on that path is an unknown repository
(`:865`).

Guide-Error-Handling, Guide-Repositories and Guide-Control-Flow are right.

**CLAUDE.md has the same error** in its "Happy Case" paragraph, which implies a
missing row produces `Can not retrieve the user …`. It does not — it produces an
empty list, and the error text applies to a repository that does not exist.
Worth a separate fix in the repository.

## 3. `Transform … with` — say which it is

**Guide-Variables**, **Guide-Actions** and **Reference-Actions** show
`Transform` producing a modified copy from its `with` clause;
**Language-Tour** and **Guide-Feature-Sets** say the `with` clause is ignored.

Both cannot stand. Check `TransformAction` before editing, then make all five
pages say the same sentence. If `with` is ignored, that is a code bug and needs
an issue, not a documentation change — do not quietly document the weaker
behaviour.

## 4. `Request` response shape

**Reference-Actions** documents `result.statusCode`, `result.headers`,
`result.isSuccess`. **Guide-HTTP-Client** and **Language-Tour** document a
`body` / `status` / `headers` envelope and describe the error the other
spelling produces.

The two guides are the ones that describe an error message, which means they
were written against the runtime. Correct Reference-Actions to the envelope and
keep the error note — it is the most useful sentence on the page.

## 5. `Store`'s role is RESPONSE

The Reference tables say RESPONSE; the Guide-Actions heading and the
Action-Developer-Guide role table say EXPORT.

**True**: `StoreAction` declares `.response`, and so do `Log`, `Send` and
`Write`. They read as exports and are not, which is a real unresolved question
(GitLab #480) and not a typo — roles drive data-flow analysis, so changing one
changes behaviour. ARO-0004 §2.4 records the dispute; the wiki should say
"RESPONSE (see ARO-0004 §2.4)" rather than pick a side.

`aro actions` prints the live table and is the thing to cite.

## 6. HTTP client backend — both, per platform

**Guide-HTTP-Client** says URLSession; CLAUDE.md says AsyncHTTPClient. Both are
true on their own platform. Say so, and add that Windows has no HTTP client at
all ([#681](https://github.com/arolang/aro/issues/681)).

## 7. `Compute` with no qualifier

Three pages, three answers. **Language-Tour** says it returns the input
unchanged; **Guide-Computations** says the operation name becomes the variable
name; **Guide-Actions** shows `Compute the <total> for the <items>` as though
`total` were an operation.

**True**: the qualifier slot selects the operation and the namespace is
**closed** (ARO-0019 §3.3, GitLab #486). An unknown qualifier is an error
naming the closest match — it no longer returns the input unchanged, which is
the behaviour Language-Tour describes. `<total>` is not an operation, so the
Guide-Actions example is rejected. Guide-Computations is right: with the
qualifier-as-name form the base is the variable and the qualifier is the
operation.

## 8. `.html` templates escape

**Guide-Computations** says "the template engine does not escape for you".

**True**: a template whose path ends `.html` or `.htm` escapes what it prints;
`.tpl`, `.txt` and `.md` do not (`TemplateEscaping.forTemplate`, GitLab #476).
Both output forms follow the same rule — `Print <x> to the <template>.` and the
`{{ <x> }}` shorthand — and each opts out its own way: `<template: raw>` for
Print, the `| raw` filter for the shorthand. Escaping runs after the filters, so
`{{ <body> | markdown | raw }}` is how a markup-emitting filter stays markup.

Do not hand-escape into an escaping template, or the reader sees `&amp;lt;`.

## 9. Two APIs that do not exist

**Guide-Computations** documents a `ComputationService` protocol. There is no
such type in `Sources/`. Delete the section, or replace it with the plugin
qualifier mechanism (`QualifierRegistry`, `handle.qualifier`), which is how a
project actually adds a computation.

The same page names a lowercase `plugins/` directory. That directory is real but
is the *legacy* loader, not the documented one — see GitLab #848; `Plugins/`
with a `plugin.yaml` is what `aro add` and `aro new plugin` produce.

## 10. Prerequisites

- **Installation** says macOS 13.0+. `Package.swift` declares `.macOS(.v15)`.
- **Getting-Started** says "macOS or Linux" while Installation covers Windows.
  Windows is supported with the caveats in the README's Platform Support table;
  link that table rather than repeating it.
- **Home** says the wiki "covers ARO 1.0". The current tag is 0.12.x.
- Homebrew: the tap is `arolang/aro`. `brew install arolang/tap/aro` names a
  tap that does not exist — the release pipeline pushes the formula to
  `github.com/arolang/homebrew-aro`.

```bash
brew tap arolang/aro
brew install aro
```

---

## While applying these

Reader-facing links should point at `https://github.com/arolang/aro`.
`git.ausdertechnik.de` is the development remote and readers cannot reach it.
In-repository citations of an issue keep the `GitLab #<number>` spelling.
