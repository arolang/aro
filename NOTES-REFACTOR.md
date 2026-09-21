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

## #738 — done

Five parts, all in `Sources/AROParser/`:

1. `enum SortOrder: String` replaces `ByClause.order: String?`. Raw values are the
   same two words, so `_by_order_` still binds "ascending"/"descending".
   Parser builds it with `SortOrder(rawValue: word)` — same two-word acceptance.
   Consumers: `FeatureSetExecutor.swift` (+`.rawValue`, ONE line — contended Core/*)
   and `AROCompiler/LLVMC/ModifierBinder.swift` (+`.rawValue`, one line).
2. `enum Qualifier` (absent / literal / chain / generic / path) classified once in
   both `QualifiedNoun` inits; `specifiers` now reads it. Classification order is
   the same as the old scan. `isQualifierChain` / `qualifierChain` deliberately left
   reading the raw annotation, because a quoted literal containing `|` answers true
   there today and folding them would change that — commented in place.
3. `RangeLoop` is a struct; `@unchecked Sendable` dropped (all stored props are
   `let` of Sendable types).
4. `ASTPrinter` moved to `Sources/AROParser/ASTPrinter.swift`. The 22
   `(try? x.accept(printer)) ?? ""` became `printer.render(x)`, one `fileprivate
   render` that documents why the failure branch is unreachable. AST.swift now has
   zero `try?`.
5. `displayVerb` added as a `Statement` requirement; every conformer declares the
   exact string `String(describing:)`-minus-"Statement" produced before
   (Pipeline/Publish/Require/When/Match/ForEachLoop/RangeLoop/Error/WhileLoop/Break,
   and `action.verb` for AROStatement). `AROGraphDiff.verb(of:)` is now one line.

After: AROParserTests 819/120, AROuntimeTests 1830/281, AROCompilerTests 6/2,
AROCLITests 354/52, AROLSPTests 76/19 — all identical to baseline, no test edited.

## #737 — partially done (two of three bullets)

Done:
1. `parseHyphenatedKey(startingWith:)` — one loop, called from both
   `parseObjectField` (literal form) and `parseMapEntry` (expression form).
2. `parseArrayLiteral` overload pair renamed: `parseArrayLiteralValue() -> LiteralValue`
   and `parseArrayLiteralExpression() -> ArrayLiteralExpression`. Both call sites
   verified to have resolved by return-type context before the rename and now name
   the one they meant.

NOT done — the flattened feature-set header (third bullet). Reasons, both hard:
 - `Parser.splitUserActionHeader` is pinned by `Tests/AROParserTests/UserActionTests.swift`
   ("Header Decomposition" suite), which feeds it the *flat* string
   (`"Action takes<number:Integer>"`) and asserts the tuple. Removing the flat path
   means deleting those tests, i.e. modifying tests to accommodate a refactor.
 - The two "further consumers" the issue names re-parse `FeatureSet.businessActivity`,
   a `String`. Making the header structural means changing that stored property's
   contract, and its guard consumers are `StateGuardSet.parse` call sites in
   `Sources/ARORuntime/Core/ExecutionEngine.swift` — the tree MR !593 is open against.
A half-measure (structural parse for the well-formed shape, string fallback otherwise)
was considered and rejected: it adds a branch without removing either re-parse.

After: AROParserTests 819/120, AROuntimeTests 1830/281, AROCLITests 354/52 — unchanged.

## #739 — partially done

Done — the descriptor half, in `Sources/AROCompiler/LLVMC/LLVMCodeGenerator.swift`
(CONTENDED FILE; edit confined to the `generatePublishStatement` /
`generateRequireStatement` region, post-change lines 1369-1379 (new `plainNoun`
helper), 1401-1410 (publish) and 1463-1471 (require); pre-change lines removed:
1390-1438 and 1491-1538):
 - both statements open-coded the result and object descriptor structs field by
   field although `DescriptorBuilder` exists; they now call it with a synthetic
   `QualifiedNoun` (`plainNoun`).
Also, in `Sources/AROCLI/PluginCompiler.swift`: the `try? compileProcess.run()` that
ignored launch failure and then called `waitUntilExit()`/`terminationStatus` on an
unlaunched Process (which raises) now skips the file on a launch failure.

EVIDENCE the emitted code is equivalent — `aro build --emit-llvm` on a purpose-built
app exercising both statements, before vs after, diffed:
```
353c353 <   store i32 0, ptr %22   >   store i32 1, ptr %22
473c473 <   store i32 0, ptr %54   >   store i32 1, ptr %54
```
787 lines of IR, two lines differ: the object descriptor's preposition tag.
The old inline code stored 0 (its comment said "from (0)"); `DescriptorBuilder`
stores `LLVMTypeMapper.prepositionValue(.from)` = 1. `ActionBridge.intToPreposition`
maps 0 -> nil -> `?? .from` and 1 -> `.from`, so the decoded `ObjectDescriptor` is
the same either way. Runtime output identical before and after.

Examples built and run end to end (`swift build --product ARORuntime` then
`swift build --product aro`, two invocations):
 - `Examples/Conditionals` — compiled output matches `expected.txt`.
 - `Examples/Iteration` — compiled output matches `expected.txt` (only the
   `[OK] demo` vs `demo` prefix, which is how compiled and interpreted always differ).
 - plus the scratch Publish/Require app, interpreted and compiled.
Pre-existing and NOT caused by this change: `Require the <X> from the <environment>.`
fails in a compiled binary ("Undefined variable: 'environment'"). Verified identical
on the unmodified baseline.

NOT done:
 - "stream and array for-each duplicate ~150 lines" — `generateForEachLoop` (835-1070)
   and `generateStreamForEachLoop` (1071-1190). Merging them is a large restructure of
   the contended file, against the "keep the edit small" instruction.
 - The `PluginCompiler` per-language split (`SwiftObjectLocator`, `RustStaticLib`,
   `CObjectCompiler`). 370 lines of build orchestration whose Rust/C/Python paths I
   cannot exercise end to end here.
 - The hard-coded `/usr/bin/clang`: routing it through the shared tool resolver would
   change WHICH compiler runs (Homebrew LLVM vs the Xcode shim). That is a behaviour
   change, not a refactor.
STALE in the issue: the line numbers `1193-1260` / `1290-1360` no longer point at
descriptor construction; `generateAROStatement` already uses `DescriptorBuilder`
(line 566). Only Publish and Require still open-coded it.

After: AROuntimeTests 1830/281, AROCLITests 354/52, AROCompilerTests 6/2 — unchanged.

## #732 — partially done (three of five bullets)

Done:
2. `findSourceFiles(in:)` was byte-identical in CheckCommand and CompileCommand.
   Now `Sources/AROCLI/Helpers/SourceFiles.find(in:)`; three call sites.
3. Contract discovery: `CheckCommand.reportBodyPolicies` hand-rolled the
   `["openapi.yaml","openapi.yml","openapi.json"]` list — replaced with
   `OpenAPILoader.findContract(in:)` (provably the same: same names, same order,
   first-existing). `AROLSP/RouteBodyLimits` keeps its own per-name loop, because
   it deliberately falls through to a sibling spelling when one fails to PARSE;
   it now reads the names from the new `OpenAPILoader.contractFilenames`.
5. All seven `Foundation.exit(1)` in CheckCommand are `throw ExitCode.failure`.
   All seven sit in `throws` functions and nothing catches between them and
   ArgumentParser, so the exit status is the same 1 — but `defer` now runs.
   Smoke-tested: ok app 0, missing path 1, --syntax ok 0, --syntax bad 1,
   --recursive 0.

NOT done:
1. `ApplicationCompiler.compile(appConfig)` across six commands — the largest
   item, spanning Run/Build/Test/Debug/Compile/Check. Each of the six prints a
   differently worded report and exits differently; folding them needs a decision
   about which wording survives, which is a behaviour change by definition.
4. `extractRunCommandFlags` / DebugCommand's hand-rolled flag re-parsing. Making
   these table-driven changes argument handling with no test covering the current
   acceptance, so a regression would be invisible here.
Also left: `RunCommand` printing errors to stdout while deciding ANSI colour from
whether *stderr* is a TTY. That is a real bug, but fixing it changes what appears on
which stream — a behaviour change, and it deserves its own issue.

After: AROCLITests 354/52, AROLSPTests 76/19, AROuntimeTests 1830/281 — unchanged.
