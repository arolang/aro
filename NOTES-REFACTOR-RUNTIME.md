# NOTES — refactor/runtime-structure (GitLab #725–#729, #731)

Worktree: `.claude/worktrees/agent-a6638d0701ab7b70b`
Branch: `refactor/runtime-structure`, branched from `main` @ `0f5625de`.

## Ground rules I'm holding myself to
- A refactor that changes behaviour is a bug. No test may be modified.
- `swift test --filter AROuntimeTests` (1828 tests) green before and after each commit.
- One commit per issue, six commits, one MR.

## Issue summaries (read from glab)
- **#725** ExecutionEngine.swift: ten near-identical `register*Handlers` methods; `<key:value>`
  guard parsing hand-rolled three times although `StateGuardSet.parse` exists.
- **#726** FeatureSetExecutor.swift 2116 lines = statement executor + `Runtime` lifecycle +
  `RuntimeSignalHandler`. Split into three files, extract `StatementModifiers`.
- **#727** Engine special-cases event named `CrawlPage` (`:41-43`, `:424-431`), 100k-entry FIFO
  of seen URLs. Must find what depends on it before touching.
- **#728** `UpdateAction` (ComputeAction.swift:1657-1984) is four actions in one; `Configure`
  recognised by verb string in FeatureSetExecutor.swift:880-882.
- **#729** ResponseActions.swift: nine actions + three event types, 1470 lines → one file per
  action + shared `drainStream`.
- **#731** RuntimeContext: magic-name list copied 3×; 3 recursive parent walks to make iterative.

## Baseline
(filled in below as I go)

## Baseline (main @ 0f5625de)
- `swift build` clean (pre-existing SOLARO warnings only), 385s.
- `swift test --filter AROuntimeTests` → **1830 tests in 281 suites passed** (issue text said 1828).
- `aro actions` captured to scratchpad `actions-before.txt` (79 lines);
  `Scripts/generate-action-reference.py --check` → "Action reference is up to date: 72 actions."

## #725 — ExecutionEngine handler registration
What I did (no behaviour change intended):
- `ExecutionEngine.swift` 1656 → 242 lines. Handler wiring moved verbatim-then-deduped into
  `Core/ExecutionEngine+EventHandlers.swift`; `GlobalSymbolStorage`/`PublishedSymbol`/
  `DependencyResolution` into `Core/GlobalSymbolStorage.swift`; the DI `ServiceRegistry` actor into
  `Core/DependencyServiceRegistry.swift` (NOT `ServiceRegistry.swift` — SwiftPM rejects a duplicate
  file name, `Services/ServiceRegistry.swift` already exists).
- New `Core/EventHandlerDependencies.swift`: `HandlerDependencies` (the four values each
  subscription used to copy into `captured*` locals) with `makeExecutor`, `makeContext`,
  `runReportingErrors` and `run` (the old `static executeHandler`, body preserved including its
  two AROLogger lines); `ActivityGuard.split/bracketContents/keyValue` replaces the three
  hand-rolled `<key:value>` parsers.
- The five `execute*Static` binding helpers became `private extension HandlerDependencies`
  methods (`runDomainEventHandler`, `runRepositoryObserver`, `runKeyPressHandler`,
  `runStateTransitionHandler`, `runStateObserver`) — bodies unchanged.
- `executeSocketHandler` / `executeFileEventHandler` / `executeNotificationEventHandler` now share
  `executeInChildContext(_:baseContext:prepare:)`; each keeps its own binding, and the
  notification one keeps its `when` evaluation in the same position. Their unused
  `program:` parameter was dropped.
- Access levels: `eventBus` and `visitedUrls` went from `private` to internal, and one internal
  `handlerDependencies` + one internal `registerEventHandlers` entry point were added. Nothing
  public changed.
- Deliberately NOT done, because the issue's own "Fix" text asks for behaviour changes and the
  brief forbids them: the missing socket/websocket name fallback, and unifying the four different
  guard-truthiness rules.

Verified: `swift build` clean; `swift test --filter AROuntimeTests` → **1830 passed**.
Examples run: EventExample (5 handlers fire in order), RepositoryObserver (server starts),
StateMachine (state observers fire).

## #727 — the CrawlPage special case
**What I found out before touching it** (this is the evidence the brief asked for):
- Only production use of `VisitedURLStore` was the engine's `if eventType == "CrawlPage"`.
- No example, no proposal, no runtime test depends on it. `Tests/.../BoundedSetTests.swift`
  tests `VisitedURLStore` directly (the type survives, so those tests are untouched).
- `Book/TheLanguageGuide/Chapter39-Concurrency.md` documented it as language behaviour.
  `Book/AROByExample/*` builds a crawler that dedupes **explicitly** via a repository and says
  in Chapter 5 "Notice what is *not* here: deduplication".
- The compiled runtime (`aro build`) never implemented it — interpreter and binary disagreed.
- **The documented form never triggered it.** The check reads
  `payload["data"]["url"]`, but `Emit a <CrawlPage: event> with { url: … }` *spreads* the object
  literal across the payload (EmitAction), so `payload["data"]` does not exist. Probe app
  (scratchpad `CrawlDedupe/`): three emits, two identical → handler ran 3 times, no dedup.
  A second probe (`CrawlDedupe2/`) emitting a variable *named* `data` DID dedup — i.e. the
  feature was reachable only by accidentally naming your variable `data`.

**What I did**: generalised rather than deleted. `Handler<dedupe:field>` (new `DedupeGuard` in
`Events/StateGuard.swift`), one bounded store per handler, field resolved top-level / one level
down / by dotted path. `StateGuardSet.parse` now skips the `dedupe:` component so it is not read
as a field comparison (which would match nothing). Engine-wide `visitedUrls` deleted.
Recorded in `Proposals/ARO-0007` §3.6; Book Chapter 39 section rewritten; summary table row
updated.

Behaviour change, stated plainly: an event named `CrawlPage` emitted with a variable named `data`
is no longer de-duplicated unless the handler declares `<dedupe:url>`. Everything else is
unchanged, because nothing else was ever de-duplicated.

Verified: probe `CrawlDedupe3/` — `CrawlPage Handler<dedupe:url>` runs twice for three emits
(one repeat dropped), an undeclared `VisitPage Handler` runs for both of its identical emits.
`swift test --filter AROuntimeTests` → **1840 passed** (1830 + 10 new in `DedupeGuardTests.swift`,
no existing test touched). `Scripts/check-proposals.py` passes. Examples: EventExample,
EventListener.

Noted, not fixed (pre-existing, unrelated to this change): `aro check` warns "event emitted but
no handler exists" for ANY guarded handler — `OrderUpdated Handler<status:paid>` warns the same
way on main. The GitHub wiki also documents CrawlPage dedup; it is outside this repo.

## #726 — FeatureSetExecutor.swift split
- 2116 lines → `FeatureSetExecutor.swift` 1571, `Runtime.swift` 339, `SignalHandling.swift` 73,
  `StatementModifiers.swift` 169. `Runtime` and `RuntimeSignalHandler` moved byte-for-byte
  (only a file header added); access levels untouched, everything stays `public` as before.
- `StatementModifiers.bind(_:into:evaluator:)` now holds the twelve consecutive framework-variable
  binding blocks that sat in the middle of `executeAROStatement` (literal, aggregation, where,
  by, default, matching/recursive, to, with, against, sink expression), in the same order.
- The `_literal_` switch turned out to be `convertLiteralValue` spelled out a second time —
  identical case for case — so the three private `convertLiteral*` helpers became
  `StatementModifiers.value/array/object`, and `matchesLiteral` uses the same one.
- The two lifecycle bugs the issue mentions (Application-End twice, Application-End losing
  published symbols) are filed separately and were NOT touched; the code moved as it stands.

Verified: `swift build` clean; `swift test --filter AROuntimeTests` → **1840 passed**.
Examples: DataPipeline (where/aggregation modifiers), Computations (literals, qualifiers),
ApplicationEnd (Runtime lifecycle + shutdown).
