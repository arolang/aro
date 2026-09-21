# NOTES-REFACTOR.md

Handoff log for the `refactor/standalone` branch (worktree `agent-a86f8bc9f0cad5828`).
Issues: #732, #733, #735, #737, #738, #739 (label `refactoring` only).

## Setup

- Branched: `git fetch origin && git checkout -b refactor/standalone origin/main`
  -> base commit `0f5625de Merge branch 'fix/842-solaro-review' into 'main'`.
- Remotes: push to `origin` only (GitLab). Never `public`.

## Issue summaries (read from glab)

- **#732** CLI repeats compile-and-report loop six times; `findSourceFiles` duplicated
  in CheckCommand/CompileCommand; contract discovery three ways; `extractRunCommandFlags`
  / DebugCommand re-implement declared flags; `Foundation.exit(1)` bypasses ArgumentParser.
- **#733** Tool discovery implemented seven times (Linker.swift mostly, CompilationStrategy,
  PluginCompiler). NOTE: Linker.swift and CompilationStrategy.swift are OFF LIMITS per the
  coordination rules.
- **#735** Five Levenshtein implementations; `isPositionInSpan` copied into six LSP files.
  Fix: one `EditDistance.levenshtein` + one `SourceSpan.contains(_:)` in AROParser.
- **#737** Parser: duplicated hyphenated-key loop, `parseArrayLiteral` overloaded on
  return type only, feature-set header flattened to a string and re-parsed.
- **#738** AST: `ByClause.order: String?`, `QualifiedNoun.specifiers` string scanning,
  `RangeLoop` a class, `ASTPrinter` inside AST.swift with 22 `try?`, `GraphDiff.verb(of:)`
  uses `String(describing: type(of:))`.
- **#739** Code generator: stream/array for-each duplicate descriptor construction instead
  of using `DescriptorBuilder`; `PluginCompiler.compile` is a 370-line function.
  NOTE: `Sources/AROCompiler/LLVMC/LLVMCodeGenerator.swift` is contended - keep edits tiny
  and record line ranges.

## Baseline test counts (origin/main, before any change)

| suite | tests | suites |
|---|---|---|
| AROParserTests | 819 | 120 |
| AROuntimeTests | 1830 | 281 |
| AROLSPTests | 76 | 19 |
| AROCLITests | 354 | 52 |
| AROCompilerTests | 6 | 2 |

`swift build` clean at base.

## #735 — done

Added `Sources/AROParser/EditDistance.swift` (`EditDistance.levenshtein`) and
`SourceSpan.contains(_:)` in `Sources/AROParser/SourceLocation.swift`.
Deleted five private edit-distance copies (UserActionRegistry, ComputeQualifierCatalog,
CodeActionHandler, ActionError, TransitionContractValidator) and six private
`isPositionInSpan` copies (AROLanguageServer, Hover/Rename/References/Definition/CodeAction
handlers); call sites rewritten to `span.contains(position)`.
Verified the LSP full-matrix variant and the four two-row variants compute the same value.
Note: `Sources/ARORuntime/Actions/ActionError.swift` is in the contended `Actions/*` tree —
the edit there is one call-site line plus the deletion of a private helper.
The issue *title* also mentions "diagnostics that are filtered by message text"; the issue
*body* does not describe that anywhere, so it was not actioned. Recorded as stale.

After: AROParserTests 819/120, AROLSPTests 76/19, AROuntimeTests 1830/281 — all pass, no test edited.
