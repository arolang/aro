# NOTES-836 — Book truth pass (GitLab #836)

Branch: `docs/836-book-truth-pass` (off `main` @ d15b1250)
Worktree: `.claude/worktrees/agent-a7c89874e6e0c6602`
Scope: `Book/` only (+ book build scripts). No Proposals/, Sources/, README.md,
Website/, wiki, Examples/ changes — bugs found there get filed as issues.

Release tag at start: `git describe --tags --abbrev=0` -> `0.12.1`

## Plan (groups = commits)
1. Five fixed things still described as open.
2. Internal disagreements (UDA visibility, `not` precedence, role tables, action count, compiled HTTP).
3. One shared install snippet; github.com URL only; one Homebrew spelling.
4. Version/date stamping from the release tag in the build scripts.
5. Construction Studies grammar appendix.

## Log

### Verification round 1 (2026-09-20)

**#552 framework-variable clearing — FIXED in code, issue claim CORRECT.**
`Sources/AROParser/FrameworkVariables.swift:59` defines `transientKeys` (21 names).
`Sources/ARORuntime/Core/FeatureSetExecutor.swift:566-571` (interpreted) and
`Sources/AROCompiler/LLVMC/LLVMCodeGenerator.swift:581-586` (compiled) both iterate it;
`LLVMCodeGenerator.swift:2076` pre-registers them. `FrameworkVariableParityTests` guards it.
Book mentions to fix: TheConstructionStudies Chapter05:460, Chapter06:131, Chapter11:75, Chapter12:78.

**`$unary` serializer/evaluator gap — FIXED in code, issue claim CORRECT (path in issue slightly off).**
Actual file is `Sources/ARORuntime/Bridge/RuntimeExecutionBridge.swift:783-810` (issue said
`Sources/AROCompiler/Bridge/...`, which does not exist). `$unary` with `not` and `-` handled,
and the `$`-prefix dispatch at :646/:670 catches any expression node generically.
Book mentions to fix: TheConstructionStudies Chapter08:398, Chapter11:200.

**REPL `:help` — FIXED in code, issue claim CORRECT.**
`Sources/AROCLI/REPL/BuiltinCommands.swift:60` reads `Example: Set the <x> to 42.` (bare verb).

**OSO stabs — Glossary is the stale one.**
`Book/TheDebuggingGuide/AppendixB-Glossary.md:35` says "Currently missing for ARO-compiled `.o`
files (chapter 8.4)"; Chapter08:64-80 says the chain works and is asserted by
`Tests/IntegrationTestsRunner/test-dwarf-debug-info.sh` in CI. Glossary loses.

**Per-line breakpoints — Chapter01:53 is the stale one.**
It says native binaries get "function-level DWARF ... but not per-line breakpoints yet";
Chapter08:80 asserts a resolving `breakpoint set --file --line` covered by CI.

**"No compiled-only bug class" — Chapter08:101.**
Contradicted by TheConstructionStudies Chapter11 (parity chapter). Needs softening.

**Homebrew spelling — the real tap is `arolang/aro`.**
`.github/workflows/build.yml` clones `https://github.com/arolang/homebrew-aro.git` to update the
formula, i.e. tap `arolang/aro`. `brew install arolang/tap/aro` would resolve to
`arolang/homebrew-tap`, which does not exist. Canonical snippet:
`brew tap arolang/aro` + `brew install aro` (matches CI release notes and Website/src/download.html).
Wrong spelling in Book: AROByExample/Chapter02-ProjectSetup.md:23, SolaroTheAroPlatform:281.

**ausdertechnik in Book/ at start: 13 hits** across 6 files (TheLanguageGuide Ch34/36/44/47,
TheDebuggingGuide Ch02, SolaroTheAroPlatform).

### Verification round 2 — group 2 & 5

**Action count: 71 built-in actions.** `aro actions` (installed 0.12.0) reports 71.
Counting `*Action.self` entries across `Sources/ARORuntime/Actions/Modules/*.swift` at HEAD gives
72 unique types, but `ParseLinkHeaderAction` declares `verbs: Set<String> = []` — it is a delegate
of `ParseAction`, not a user-facing action. So 71 either way. Short Studies says 61.

**HTTP in compiled binaries works.** `Sources/ARORuntime/Bridge/HTTPServerBridge.swift` drives the
real `AROHTTPServer` over the C ABI; `Examples/HTTPServer/test.hint` and
`Examples/UserService/test.hint` both carry `mode: both`, so CI runs them interpreted *and* built.
Short Studies:294 is out of date.

**Action roles — ground truth is `ActionRoleCatalog` (GitLab #585), surfaced by `aro actions`.**
request/own/response/export/server. Store, Log, Send, Broadcast, Write, Notify, Append, Render,
Repaint are `response`. Export is exactly Emit, GitCommit, Publish, Push, Schedule, Tag.
Server is Close, Connect, Copy, Listen, Make, Move, Start, Stop, WaitForEvents.
- Construction Studies §1 role table (Chapter01:102-108) is CORRECT against the catalog.
- Figure 1.2 caption (Chapter01:189) wrongly lists Broadcast under `server`.
- Figure 1.2 SVG (Chapter01:179) wrongly labels the EXPORT arrow "Publish, Store, Emit" (Store is
  `response`).
- NOTE: CLAUDE.md's own "Action Semantic Roles" section also disagrees with the catalog (it puts
  Store, Log, Send under EXPORT). CLAUDE.md is out of scope for this issue -> file an issue.

**`not` precedence — ground truth from `Sources/AROParser/Parser.swift:2357-2373`:**
or(1) < and(2) < not(3, prefix) < equality(4) < comparison(5) < default(6) < term(7) < factor(8)
< unary `-`(9) < postfix `.`/`[]`(10). Python-style: `not <a> == <b>` is `not (<a> == <b>)`.
Empirically confirmed: `Compute the <a> from not 3 >= 5.` prints `true` (i.e. `not (3 >= 5)`).
- Construction Studies Chapter03:137-146 — right order, but omits `default` and so numbers
  levels 6-9 one lower than the parser does.
- Construction Studies AppendixB-Grammar:314-326 — WRONG. Claims `not` is level 2, binding
  tighter than comparison, with an explicit worked example that inverts the real grouping.
- Language Guide Chapter09:235-246 — right order, omits `default`.
- Short Studies:81-89 — merges equality and comparison, omits `default`, and the surrounding
  prose mentions "function call", which ARO does not have (postfix is `.` and `[]`).

**User-defined action visibility is application-wide.** `SemanticAnalyzer.swift:320-332` merges the
local registry with the application-wide one and only falls back to `.file` scope when a single
file is analysed alone; `UserActionAnalyzer.buildRegistry` reports duplicates because "user-defined
action names are unique application-wide" (GitLab #587).
- The Essential Primer:444 says the opposite — wrong, must be rewritten.
- AROForDataEngineers §8.1 (line 750-758) is correct; its Appendix B (line 932-933) repeats the
  wrong advice.

**Grammar appendix — probed each construct with the installed `aro check`:**
- `import ../shared` -> PASSES. Real production (`Parser.swift:110,145`, ARO-0007).
  *The issue's claim that `import` is not in the language is STALE.*
- `<host: "127.0.0.1">` -> PASSES. `host` is in `SystemObjectCatalog.names` and
  `ServerActions.swift:963` special-cases it. *The issue's claim is STALE.*
- `api UserAPI { ... }` -> `error: Expected '(', but got identifier(api)`. NOT in the language.
- `Start the <http-server> on port 8080.` -> `error: Expected '.', but got int(8080)`.
  NOT in the language.
- Reserved words `if`/`then`/`else`/`type`/`enum`/`protocol`/`guard`/`defer` ARE in
  `Lexer.swift:46-77` `reservedWords` as real keyword tokens; they simply have no grammar
  production. *The issue's claim that they are "not in the language" is STALE* — but the appendix
  should say they are reserved and unused rather than implying they are usable.

### Group 1 edits done (commit 1)
- CS Chapter05:460, Chapter06:131, Chapter11 §"Source of Divergence 2", Chapter12:78 —
  rewritten to describe `FrameworkVariables.transientKeys` + `FrameworkVariableParityTests`
  as the present state. Chapter 11's section renamed from "The List That Did Not Get Shared"
  to "The Framework-Variable List".
- CS Chapter08 (when-guard section) and Chapter11 (when-guard serialisation) — `$unary` is
  decoded; added the `$`-prefix dispatch rule. Kept the one honest open item (no shared schema,
  no round-trip test).
- InteractiveDialog Chapter01 and Chapter02 — the `:help` warnings replaced with the present
  (`BuiltinCommands.swift:60` writes the bare verb).
- DebuggingGuide Chapter01 §1.4 — per-line breakpoints resolve; reframed around what compiled
  mode actually lacks (bindings, debugger breakpoint kinds, record/replay).
- DebuggingGuide AppendixB-Glossary "OSO stab" — now agrees with chapter 8.4.
- DebuggingGuide Chapter08 §8.5 — the "no compiled-only bug class" claim replaced with the two
  real seams (two expression evaluators, two event-dispatch paths), pointing at CS chapter 11.
- DebuggingGuide Chapter08 §8.4 — "both were once broken" -> present-tense rationale.

### Group 2 edits done (commit 2)
- EssentialPrimer §7 — UDA visibility corrected to application-wide (+ REPL); the "Cross-file
  user-defined actions" limitation bullet in §11 deleted. Verified both by running:
  two-file app resolves `Application.DoubleValue` across files, and the same call works at the
  `aro repl` prompt (`ARO REPL v0.12.0`, returns 42).
- AROForDataEngineers Appendix B — "Unknown user-defined action" entry no longer blames
  cross-file declaration.
- `not` precedence stated one way in CS Chapter03, LanguageGuide Chapter09, ShortStudies.
  (CS AppendixB-Grammar is handled in the group-5 generator commit.)
  Added the missing `default` level to all three.
- CS Chapter01: role table extended to match `ActionRoleCatalog`; Figure 1.2's SVG EXPORT label
  fixed (Store is `response`, not `export`); the caption no longer lists Broadcast as `server`;
  added a line naming `aro actions` as the authority.
  Checked LanguageGuide/AppendixA-ActionReference.md and Book/Reference/Actions.md — both
  already agree with the catalog, no change needed.
- ShortStudies: 61 -> 71 built-in actions (with a pointer to `aro actions` so the number is not
  the thing being maintained); the "HTTP doesn't work in compiled binaries" bullet moved out of
  "things that didn't work" and replaced by the C-ABI win it turned into.

### Group 3 + 4 (install snippet, version/date stamping)
New `Book/Install.md` — the single reader-facing install snippet. github.com only; Homebrew
spelled `brew tap arolang/aro` + `brew install aro`, which is the tap the release workflow
actually maintains (github.com/arolang/homebrew-aro). Spliced into five books through an
`<!-- ARO:INCLUDE Install.md -->` / `<!-- /ARO:INCLUDE -->` marker pair with a one-line
fallback link in between, so the raw markdown still reads sensibly on the web.
Books carrying the include: TheDebuggingGuide Ch02, AROByExample Ch02, SolaroTheAroPlatform §2.2,
AROForDataEngineers §2.1, TheLanguageGuide Ch03 §3.1.

All 13 `git.ausdertechnik.de` references gone: 2 `git clone` URLs and 3 Solaro demo URLs and
1 in-repo file link rewritten to github.com; 7 GitLab issue hyperlinks in TheLanguageGuide
reduced to the plain `GitLab #NNN` spelling CLAUDE.md prescribes (readers cannot reach the host).
`grep -rn ausdertechnik Book/` -> 0.

New `Book/book-release.sh`, sourced by all ten build scripts. Derives ARO_VERSION from
`git describe --tags --abbrev=0` (leading `v` stripped) and ARO_DATE from that tag's commit date
as "%B %Y"; both overridable from the environment; falls back to `dev` + today with no tag or no
git. `aro_book_stamp` rewrites `@ARO_VERSION@` / `@ARO_DATE@` and splices Install.md.
Every build now stages its sources (into `output/staged`, or `processed/` for the Construction
Studies) so the checked-in markdown keeps its placeholders.

Verified:
- `bash Book/TheEssentialPrimer/build-pdf.sh` -> HTML + PDF, staged metadata reads
  `date: "September 2026"` / `version: "0.12.1"`.
- `bash Book/TheShortStudies/build.sh` -> HTML + PDF, header line stamped.
- `bash Book/AROForDataEngineers/build-pdf.sh` -> HTML + PDF (1.5 MB).
- Fallbacks exercised: tag -> 0.12.1/September 2026; explicit env override honoured;
  no-git -> `dev` + today's month. None of the three prints a literal placeholder.
- `bash Book/TheDebuggingGuide/build-pdf.sh` stages and splices correctly, then FAILS in
  xelatex: `The font "TeX Gyre Pagella" cannot be found`. Pre-existing and environmental —
  the font ships in TeX Live (`kpsewhich texgyrepagella-regular.otf` resolves) but is not
  registered with fontconfig on this machine, and the `mainfont`/`monofont` keys that ask for
  it by name are untouched by this branch. The same applies to every book whose metadata.yaml
  sets TeX Gyre fonts (AROByExample, AROByHallucination, TheConstructionStudies,
  TheDebuggingGuide, TheLanguageGuide, ThePluginGuide).

NOT regenerated: the tracked build artifacts under Book/AROByHallucination/output,
Book/TheConstructionStudies/output and Book/TheShortStudies/output. They are stale with respect
to this branch; regenerating them here would be a large binary diff produced by whatever pandoc
and TeX Live this machine happens to have. Flagged in the MR instead.

### Group 5 (grammar appendix) — route taken: GENERATE the derivable tables,
### hand-correct the EBNF.

Three of the appendix's sections were tables that already exist in the parser, so they are now
generated by `Book/TheConstructionStudies/generate-grammar-appendix.py` (modelled on
`Scripts/generate-action-reference.py`, BEGIN/END markers + `--check`):
  - Precedence, from `Parser.swift`'s `Precedence` enum.
  - Prepositions, from `Token.swift`'s `Preposition` enum.
  - Reserved Words, from `Lexer.swift`'s single `reservedWords` table, grouped by its own
    comment headings.
`--check` wired into `.gitlab-ci.yml` beside the existing `action-reference` job.

The EBNF productions themselves were hand-corrected. There is no clean seam to generate them
from: ARO's grammar lives in a hand-written recursive-descent parser, and extracting a machine-
readable grammar would mean changing the parser, which is out of scope here. The appendix now
says so in its opening paragraph.

Hand corrections, each decided by probing the installed `aro check`:
  - REMOVED `api_definition` (`api X { … }`) — `error: Expected '(', but got identifier(api)`.
  - REMOVED `on_clause = "on" , "port" , number` — `error: Expected '.', but got int(8080)`.
  - REPLACED `api_reference` with `system_object_reference`, which is what the runtime actually
    has (`SystemObjectCatalog.names`); the old `host_reference` production folded into it.
  - KEPT `import_declaration` — it is a real production (`Parser.swift:110,145`, ARO-0007),
    with a comment noting applications normally need no imports.
  - KEPT the reserved words `if`/`then`/`else`/`type`/`enum`/`protocol`/`guard`/`defer` — they
    ARE in `Lexer.swift`'s table. The generated section now says plainly that a reserved word
    may have no production, and separately that HTTP status names and the `Application-Start` /
    `Handler` labels are NOT reserved (the old hand-written list claimed they were).

Where the issue was stale (also for the MR description):
  - `import` and `<host: …>` are real; the issue lists them as "not in the language".
  - The reserved words it names are genuinely reserved in the lexer; only their absence from the
    grammar is true.
  - The `$unary` file path in the issue (`Sources/AROCompiler/Bridge/RuntimeExecutionBridge.swift`)
    does not exist; the file is `Sources/ARORuntime/Bridge/RuntimeExecutionBridge.swift`.

### Verification
- `python3 Scripts/check-proposals.py` -> "Proposal check passed: 67 proposals, all IDs unique
  and all references resolve."
- `python3 Book/TheConstructionStudies/generate-grammar-appendix.py --check` -> up to date.
- `bash Book/TheInteractiveDialog/build-pdf.sh` -> HTML + PDF; staged Chapter01 reads
  `ARO REPL v0.12.1`, staged Cover reads `September 2026` / `ARO 0.12.1`.
- No new fenced ARO code blocks were added to any book, so there is nothing new to run through
  `aro check`. The five probe programs used to decide the grammar corrections were run through
  the installed `aro check` (results above) and live only in the scratchpad.

### Out-of-scope bugs found (to be filed as GitLab issues)
1. CLAUDE.md's "Action Semantic Roles" section disagrees with `ActionRoleCatalog`: it lists
   Store, Log and Send under EXPORT; the catalogue and `aro actions` put all three under
   RESPONSE, and EXPORT is exactly Emit/GitCommit/Publish/Push/Schedule/Tag.
2. The tracked build artifacts under `Book/AROByHallucination/output`,
   `Book/TheConstructionStudies/output` and `Book/TheShortStudies/output` are stale with respect
   to this branch and to the release; they should be regenerated as part of a release rather
   than checked in by hand.

### Group 6 (small): the Short Studies' version-history table stopped at 0.9.x
With the cover now stamped 0.12.1, the evolution table ending at 0.9.x was an internal
inconsistency of exactly the kind this issue is about. Added 0.10.x / 0.11.x / 0.12.x rows.
Release contents checked against the tags: ARO-0088, ARO-0090 and ARO-0091 all landed in
0.11.x (`git describe --tags --contains` on each proposal's adding commit -> 0.11.6~24^2,
0.11.6~9^2, 0.11.6~6^2); ARO-0089 and the SOLARO learning notebooks are in 0.12.x.
