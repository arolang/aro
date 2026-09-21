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

## #728 — Configure is its own action
- New `Actions/BuiltIn/ConfigureAction.swift`: `ConfigurableSetting` + `ConfigurableSettings.all`
  (http-server `max-body`/`max-request-body`/`maxBody`; repository `ttl`, `maxSize`) and
  `ConfigureAction` (role own, verbs ["configure"], same prepositions as Update).
- `UpdateAction` moved out of ComputeAction.swift (2646 → 2317 lines) into its own file, verbs now
  ["update","modify","change","set"]. It still reaches the settings table, so
  `Update the <cache-repository: ttl> with 60.` behaves exactly as before.
- Shared `EntityUpdate.apply` holds the generic dictionary path both use.
- The `NeedsAsyncExecution` round trip is gone from the common path: `execute` decides which path
  applies before running the sync body (the sync body still exists and is what the compiled
  runtime calls, and still throws `NeedsAsyncExecution` for the repository paths so
  `ActionRunner.executeSynchronouslyIfSupported` falls through as it always did).
- `FeatureSetExecutor` no longer compares a verb string: `if ConfigureAction.handles(verb)`.
- Removed `"configure": "update"` from `ActionRunner.verbMappings`. **This was mandatory**: the
  compiled runtime's synchronous action table is keyed by canonical verb, so leaving the mapping
  would have sent Configure statements to UpdateAction in compiled binaries only. Neither verb is
  in `deferrableVerbs` or `forceAtSiteVerbs`, so deferral is unaffected. One consequence worth
  naming: an `ActionMiddleware` registered for "update" no longer also sees Configure statements.

**`aro actions` diff (intended, exactly this and nothing else):**
```
> Configure  own  for, from, into, to, w  configure
< Update  own  ... change, configure, modify, set, update
> Update  own  ... change, modify, set, update
< 71 built-in actions  →  > 72 built-in actions
```
`Scripts/generate-action-reference.py` regenerated ARO-0004 §11 (72 → 73 rows as the script counts);
`--check` passes.

**One test changed, and I want it flagged:** `ActionRoleConsistencyTests.testActionCount` asserts the
built-in action count (71 → 72). It is a bookkeeping constant whose own comment says "If an action
is added, both this number and the table need updating". No other test was touched, and 1840 tests
pass.

Verified: `swift build` clean; `swift test --filter AROuntimeTests` → **1840 passed**; targeted
`UpdateIntoRepositorySession` (7) and `ConfigureRebindHint` (7) suites pass. Ran
Examples/ConfigurableTimeout, and a probe covering all four paths (repository ttl, http-server
max-body, ad-hoc `<validation: timeout>`, unset setting reading null, `Update the <order: status>`,
`Set`): interpreted output correct. Also `aro build` of that probe and ran the binary — the compiled
binary reports "Property 'retries' not found" where the interpreter answers null, which is a
PRE-EXISTING divergence: `markConfigured` is only ever called by the interpreter's executor
(no call anywhere in Bridge/), so compiled mode never had ARO-0035 §3.2's optional-read behaviour.

## #729 — ResponseActions.swift split
1470 lines → nine files, one per action, each carrying its own supporting types:
ReturnAction 268, ThrowAction 33, SendAction 111 (+MessagingService, SendResult, MessageSentEvent),
LogAction 248 (+LoggingService, LogLevel, LogResult), StoreAction 281 (+StoreResult,
DataStoredEvent), WriteAction 273 (+URLWriteResult, WriteResult), PublishAction 54
(+VariablePublishedEvent), NotifyAction 119 (+NotificationService, NotifyResult,
NotificationSentEvent), EmitAction 144 (+DomainEvent, EmitResult). Every type kept `public`;
no declaration edited except LogAction's two stream loops.
Note: the issue lists Append and Broadcast; neither is in this file (nor is `AppendAction` a
separate type here) — stale issue text.
`LogAction.drainStream(_:emit:)` + `line(for:context:)` + `write(_:)` replace the two copied
drain loops.
Doc references updated: Book SourceMap table row, ARO-0050 and ARO-0051 file lists, and two
comments in AROCLI/REPL that named the old file.

Verified: `swift build` clean; `swift test --filter AROuntimeTests` → **1840 passed**;
check-proposals passes. Examples: HelloWorld (Log), StoreFileDemo (Store), DataPipeline.

## #731 — RuntimeContext: one magic-name list, three loops
- `magicNames` (one `static let Set`) + `resolveMagic(_:) -> MagicResolution`. The enum exists
  because two of the old branches were not "return a value": `<contract>` may legitimately resolve
  to nil (and must NOT fall through to the variable store), while `<http-server>` with no contract
  loaded MUST fall through — which is why it is `.notMagic` there. `resolveAnyRaw` and
  `resolveAnyAsync` only ask `magicNames.contains`, exactly as their `||` chains did.
- `isConfigured` and `templateEscaping` now go through a new iterative `firstInChain(_:)`;
  `schemaRegistry` has its own loop because a non-RuntimeContext parent has to answer for itself.
  All three were recursive; `isConfigured` is on `ExtractAction`'s miss path, i.e. reached at
  recursion depth — the case `ancestorHolding` documents as SIGBUS at ~1300 frames.

Verified: `swift build` clean; `swift test --filter AROuntimeTests` → **1840 passed**.
Examples: RecursiveActions (deep parent chains: 10!, sum 1..10000, mutual), TemplateEngine
(templateEscaping inheritance), DateTimeDemo (`<now>`), MetricsDemo (`<metrics>`).
