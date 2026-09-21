# What ARO Is Missing

A working list of gaps, compiled 2026-09-20 from a full read of the 67 proposals, the 45-page
wiki, the twelve books, all 110 examples (checked and run), the Swift sources, the CI
configuration and the training pipeline. Every entry is something a user can hit today.

This file is not a language comparison. It is the inventory that the GitLab issues #598–#836
were filed from; each section names the issues that track it.

Priority order for truth, when this file and something else disagree:
`Proposals/` > `Sources/` > wiki and `OVERVIEW.md` > `Website/` > `Book/`.

---

## 1. Missing language features

These are absences the documentation itself works around. #830 tracks the set.

| Gap | What people write instead |
|---|---|
| No default value on `Extract` | an unset `<env: NAME>` binds `""` silently, then `when <x> == ""` |
| No positional CLI arguments | flags only; `./crawler https://example.com` cannot work |
| Regex capture groups are unreadable | named groups compile, nothing exposes them; four `Split` statements replace one match |
| No URL utilities | resolve, strip-fragment and normalise are rebuilt from `Split` and `++` |
| `when` lacks `starts with`, `ends with`, `in`, `not in` | the `where` grammar has them; the two condition grammars have diverged |
| `ParseHtml` cannot read attributes | `text` returns element text only, so `img[src]` is unreachable |
| File metadata is read-only | no chmod, no touch, no path API |
| No application-wide concurrency limit | `with <concurrency: N>` bounds one loop; handlers woken by emits escape it |
| Repository persistence is all-or-nothing | a permission bit; no checkpoint, no transaction |
| No subset or symmetric difference | only `intersect`, `difference`, `union` |
| No imports or namespaces | two files cannot both define `Save Page`; a project can depend only on plugins |
| Timezone conversion | specified in ARO-0041, not implemented; `<now>` is UTC and `<now: timezone>` answers GMT |
| `Delete … where` takes one predicate | and its result has no readable fields |
| `Copy` / `Move` bind a fixed result name | two in one feature set is an immutability error |
| `Publish` takes no `when` guard | |
| No 405, 422, 429 or 503 status names | an unrecognised name silently maps to 200, with no check-time warning |
| Ranges (`1..10`) | specified in ARO-0089, not implemented (GitLab #546) |
| Type narrowing and match exhaustiveness | specified in ARO-0071, still proposed |
| Window functions | specified in ARO-0018 §6, not implemented |
| `<today>`, `<yesterday>`, `<tomorrow>` | specified in ARO-0041 §5, not resolved by the runtime |
| XML parsing | ARO-0011 is titled "HTML/XML" and specifies only HTML |
| PUT/DELETE through `<url>` | ARO-0052 §9 lists them as future |
| WebSocket binary frames, subprotocols, per-path handlers | ARO-0048 §9 |
| Arrow-key `Select`, widgets, mouse events | ARO-0083 §11 |
| NDJSON/CSV record streaming of request bodies | ARO-0090 §11 — `for each` over a body yields byte chunks |
| Streaming a body into a plugin | passing one to a plugin action materialises it |

**Also unspecified:** `aro ask` — a shipped subcommand with model downloads, `.context` session
files and shell-execution approval — has no proposal. ARO-0084 covers the superseded `aro lm`.
See #833.

---

## 2. Platform parity

`aro run`, `aro check`, `aro compile`, `aro test` and the REPL work on all three platforms.
Almost everything else is macOS and Linux. Tracked by #203 and #679–#701.

| Capability | macOS | Linux | Windows |
|---|---|---|---|
| `aro build` | yes | yes | **compiled out entirely** (#613) |
| HTTP client, `Probe`, `Stream`, `Subscribe` | yes | yes | **six `unsupportedPlatform` throws** (#681) |
| Socket client (`Connect`) | yes | yes | **missing** (#681) |
| HTTP server | SwiftNIO | SwiftNIO | FlyingFox: no body streaming, no WebSocket |
| Git actions (ARO-0080) | yes | yes | **whole module compiled out** (#683) |
| `Exec` / `Shell` / `Run` | yes | yes | **hard-codes `/bin/sh` and `/usr/bin/env`** (#682) |
| `aro lsp`, `aro mcp`, `aro ask`, `aro kernel` | yes | yes | **not registered as subcommands** (#701) |
| File monitor | FSEvents | inotify | 1 s polling |
| Terminal UI | full | full | Windows Terminal only; **hidden prompt echoes the password** (#699) |
| `.store` writability | opt-in via `chmod o+w` | same | **inverted — every store is writable** (#684) |
| Shutdown signals | POSIX | POSIX | **POSIX handlers installed unguarded; SIGTERM never arrives** (#685) |
| Metrics | real | real | **all zeros, not absence** (#700) |
| Solaro | yes | no | no |
| CI | build only, no `swift test` (#687) | full | **`if: false`** (#686) |

The README's Platform Support table — which `CLAUDE.md` and ARO-0090 both name as the source of
truth — was deleted on 2026-09-02 (#680). The version restored here is stricter than the one that
was lost: the old table claimed a working HTTP client on Windows.

---

## 3. Execution-mode parity

`aro run` and `aro build` are supposed to agree. These are the places they do not.

| Difference | Detail | Issue |
|---|---|---|
| `when { … }` blocks | pass `aro check`, abort `aro build` with "not supported in compiled mode" | #655 |
| `Touch`, `Mkdir`, `Rename` | in the catalog, no bridge export — a raw linker error | #679 |
| `is empty` / `is not empty` | serialised as `$unknown`; the guard never performs the test | #652 |
| Interpolated expressions | `"${<a> + <b>}"` prints the literal `${...}` | #653 |
| `Compare … against` | the right operand is never bound | #663 |
| Errors in a range loop | swallowed; the loop continues with side effects | #654 |
| `Return` in a streamed `for each` | does not end the feature set | #665 |
| Arithmetic errors | `exit(1)` instead of a catchable ARO error (GitLab #472) | #692 |
| Error message shape | the binary leaks Swift type names and drops the feature/statement frame | #692 |
| File events | `MODIFIED` where the interpreter says `CREATED` / `DELETED` | #693 |
| Socket connect/disconnect events | not published from the native bridge (ARO-0072) | #693 |
| `Wait` verb | Keepalive interpreted, Listen compiled | #634 |
| `Log` prefix | `[Feature Set]` interpreted, nothing compiled | #814 |
| Chunked request bodies | the native server frames by Content-Length only | #692 |
| Concurrency gating | a global 4 × CPU gate and 2 in-flight iterations per parallel loop | — |
| Python plugins | a fresh interpreter per call interpreted, an embedded one compiled | #815 |
| Tests | `aro test` never exercises the compiled path, so none of the above is caught | #694 |

---

## 4. Notebook and REPL parity

`aro repl`, `aro repl --json`, `aro kernel` and the Solaro notebook share one engine, so these
apply to all four. Tracked by #688–#691.

- Socket, WebSocket, File and KeyPress handlers are accepted and never dispatched, silently.
- `Publish` cannot see a variable bound in an earlier cell, although every other statement can.
- `Prompt`, `Select` and `Ask` throw "missing service" behind a pipe; the native kernel binds a
  stdin channel and never uses it.
- The session is not project-aware: no `openapi.yaml`, no `.store` seeds, no project `Plugins/`,
  no `templates/`. A notebook opened inside a project cannot exercise that project.
- Interrupting kills and replaces the kernel; all session state is lost.
- `:export` produces code that will not run — no `Application-Start`, no `Return`.

---

## 5. Static and standalone binaries

The subject of MR !450 and issues #598–#627. Summarised per platform:

| | Application binary | The `aro` toolchain |
|---|---|---|
| **macOS** | libgit2 now static but unpackaged; three build-machine rpaths embedded; `--dynamic` undefined; Python plugins break the contract; the Swift runtime is not and cannot be static | libLLVM, libzmq and libgit2 dylibs plus a CI-runner rpath |
| **Linux glibc** | Foundation can be linked statically today (the branch says otherwise); `--static` silently degrades; the `--dynamic` bundle list is stale; static libgit2 trades one dependency for OpenSSL | the same four dylibs; no arm64 build at all |
| **Linux musl** | needs a musl-built runtime archive, musl plugins and a musl triple — none exist; route dispatch uses `dlsym`, which a static binary has no table for | not attempted |
| **Windows** | `aro build` does not exist; the `/MT` choice would mix two CRTs with the `/MD` Swift DLLs | Swift DLLs plus the VC redistributable; no release asset |

The gates do not test the claims: no macOS or Windows job runs the dependency checker, the Linux
job runs the binary inside an image that has every Swift library installed, and nothing inspects
`LC_RPATH`.

---

## 6. Tooling

| Gap | Issue |
|---|---|
| `aro test` cannot test a compiled binary | #694 |
| No formatter — the LSP's `formatStatement` is unreachable dead code | #677 |
| No linter beyond `aro check`, whose warnings are ~90 % false on the examples | #823 |
| No doc comments and no `aro doc` | — |
| No coverage tool, no profiler, no benchmark harness | — |
| No package registry; `aro add` takes a Git URL, there is no index | — |
| No watch mode, no hot reload | — |
| No online playground | — |
| MCP exposes 8 of ~18 CLI capabilities — no `test`, no `diff --graph`, no plugin management | #696 |
| Editor grammars are hand-maintained and miss 64 verbs including all of Git | #695 |
| The debugger has no causal backtrace; `s`, `n` and `f` all do the same thing | — |
| DAP has no `evaluate`, no conditional breakpoints, no detach-without-quit | — |
| The recording format has no version field | — |

---

## 7. Solaro

Tracked by #742–#778 and the existing #228, #234, #269, #288, #445, #446, #448, #531.

**Wrong, not just missing:** live pulses, error borders *and* breakpoints are keyed by bare line
number with no file, so in any multi-file project the canvas lights the wrong file and the
debugger stops where nothing was marked (#742, #743). Menu actions — including Delete File and
Revert — are broadcast to every open window (#744).

**Missing IDE basics:** no ⌘R for Run, no one-click `aro build`, no find-references (the one
navigation an event-driven language most needs), no rename preview, no template picker.

**Missing ARO-specific views:** the live feature-graph exists as a static drawing and as a run,
but never as both at once — the data is already in `DebuggerState`. No store-file inspector, no
request replay, no plugin scaffolding, no `.ipynb` export, and per-cell execution counts are
persisted but never rendered.

**Not started:** accessibility (two labels in 51 900 lines; the canvas is invisible to VoiceOver),
localisation, Linux and Windows builds.

---

## 8. The model and its pipeline

Tracked by #779–#813. The product goal is turning natural language into valid ARO.

- **The benchmark is gone.** All 4 000 evaluation prompts were folded back into training, so the
  75.5 % gate figure and the 67 % evaluation measure prompts the model has paraphrased answers
  for (#785).
- **The main task is absent.** Zero `full_application` rows; 14 multi-file rows; no `aro test`
  pairs; the templated CRUD set is the only NL→application data (#797).
- **`aro check` is the only oracle.** `aro run` is budgeted to single digits and `aro test` is
  never used, so the corpus proves parseability rather than behaviour (#798).
- **The corpus contradicts the language.** The action catalog is stale, ~150 statements use
  invented verbs, and 36 % of the corpus is unvalidated commit-message pairs (#779, #780, #781).
- **The loop makes it worse.** The iterative stage's best round is round 0, and it fuses each
  round's adapter into the next round's base.
- **The final model is fine-tuned on 17 conversations** for roughly 140 epochs (#790).
- **User failures never come back.** `aro ask` writes repair logs into the user's project; the
  training stage reads only the ARO repository root (#800).

---

## 9. Consistency debt

Not features, but they cost the same to hit.

- Twenty cross-proposal contradictions on roles, prepositions, `where` spelling, indexing
  direction, `Emit` blocking, published visibility and more (#831).
- Renumbered proposals citing the numbers they used to have, which CI cannot catch because it only
  checks that the number resolves (#832).
- Four proposals describing an API that never shipped (#833).
- Specification examples that `aro check` rejects — invented verbs, `if … then`, method-call
  syntax, undefined status names (#834).
- Ten wiki contradictions and ten Solaro-book divergences (#835, #778).
- Books describing as open five bugs that are fixed (#836).
- Six verb-classification tables and ten catalog pairs kept in sync by hand, four of which have
  already drifted into user-visible bugs (#722, #740).

---

## How to use this file

Add a row when you find a gap; link the issue; delete the row when the issue closes. If a gap is
big enough to need a design, it wants a proposal in `Proposals/` rather than a row here. Take the
next free number by looking, not from this file — `Scripts/check-proposals.py` will tell you if you
picked one that is taken.
