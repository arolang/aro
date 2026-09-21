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
