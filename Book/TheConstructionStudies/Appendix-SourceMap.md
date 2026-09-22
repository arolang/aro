# Appendix: Source Map

This appendix provides a quick reference to key source files in the ARO implementation.

---

## Parser Package (`Sources/AROParser/`)

| File | Lines | Description |
|------|-------|-------------|
| `Parser.swift` | ~2,670 | Recursive descent + Pratt parsing; three dispatch tables |
| `AST.swift` | ~2,205 | AST node definitions, three visitor protocols, `ASTPrinter` |
| `DataFlowAnalyzer.swift` | ~1,140 | Per-statement inputs/outputs/effects, dependency verification |
| `Lexer.swift` | ~930 | Tokenization, string interpolation, regex detection, hex/binary/raw literals |
| `BodyMaterialization.swift` | ~535 | Which routes need their request body as a value (ARO-0090) |
| `FeatureGraphDiff.swift` | ~445 | Feature-set graph diffing for `aro diff` |
| `SymbolTable.swift` | ~437 | Symbol storage, visibility levels, DataType enum |
| `FeatureGraph.swift` | ~423 | The wiring graph between feature sets |
| `GraphDiff.swift` | ~396 | Graph comparison primitives |
| `SemanticAnalyzer.swift` | ~368 | Conducts the passes; owns their order |
| `Token.swift` | ~363 | Token types, articles, prepositions |
| `Errors.swift` | ~355 | LexerError, ParserError, SemanticError, Diagnostic, DiagnosticCollector |
| `CollectionOpValidator.swift` | ~284 | Collection statements that parse clean and then no-op (GitLab #465) |
| `EventChainAnalyzer.swift` | ~274 | Circular event chain detection |
| `UserActionAnalyzer.swift` | ~268 | `Application.<Name>` registry, call sites, unavoidable recursion (ARO-0081) |
| `CodeQualityValidator.swift` | ~252 | Legal-but-wrong statement shapes |
| `ComputeQualifierCatalog.swift` | ~215 | The closed set of Compute qualifiers, checkable without the runtime |
| `Compiler.swift` | ~209 | Pipeline orchestration |
| `PrepositionCatalog.swift` | ~206 | Which prepositions each verb accepts |
| `EventAnalyzer.swift` | ~188 | Orphaned emission detection |
| `UserActionRegistry.swift` | ~108 | The user-action table built before per-feature-set analysis |
| `SystemObjectCatalog.swift` | ~82 | `<console>`, `<git>`, `<http-server>`, … |
| `SourceLocation.swift` | ~80 | SourceLocation, SourceSpan, Locatable protocol |
| `TypeInferencer.swift` | ~77 | Type inference helpers |
| `ActionCatalog.swift` | ~68 | Verb → role, for check-time validation |
| `Exports.swift` | ~67 | Public API re-exports |
| `DurationUnitCatalog.swift` | ~67 | `s` / `ms` / `m` for Sleep and Schedule |
| `Parser/TokenStream.swift` | ~58 | Token stream protocol |

### Key Entry Points

**Parsing a source file**:
```swift
// Strict: throws ParserError.recovered carrying every diagnostic.
let program = try Parser.parse(sourceCode)

// Recovering: errors land in the collector; you decide whether to proceed.
let diagnostics = DiagnosticCollector()
let program = try Parser.parse(sourceCode, diagnostics: diagnostics)
```

**Semantic analysis**:
```swift
let analyzer = SemanticAnalyzer()
let analyzed = analyzer.analyze(program)
```

---

## Runtime Package (`Sources/ARORuntime/`)

### Core (`Core/`)

| File | Lines | Description |
|------|-------|-------------|
| `FeatureSetExecutor.swift` | ~2,030 | Statement execution, control flow, per-statement scopes, deferral force points |
| `RuntimeContext.swift` | ~1,790 | The concrete context; framework variables; lazy streams (ARO-0051) |
| `ExecutionEngine.swift` | ~1,640 | Program execution, ten handler-registration passes (actor) |
| `ExpressionEvaluator.swift` | ~754 | Interpreter-side expression semantics |
| `ExecutionContext.swift` | ~627 | The protocol — a composition of nine narrower ones |
| `TypedValue.swift` | ~212 | Type-preserving value wrapper |
| `BoundedSet.swift` | ~127 | Bounded set for deduplication |
| `RuntimeContainer.swift` | ~96 | DI container for infrastructure services |
| `RuntimeConfig.swift` | — | `ARO_STREAM_PREFETCH`, `ARO_MAX_CALL_DEPTH`, and friends |
| `VerbSets.swift` | ~57 | Eleven canonical verb sets |
| `CallDepthBudget.swift` | — | Recursion ceiling with a named call chain (ARO-0081 §9) |
| `OutputContext.swift` | ~23 | Output mode (.human, .machine, .developer) |

### Actions (`Actions/`)

Built-ins are registered by **module**, not one at a time. `Modules/` holds eleven
arrays of action types — Request, Own, Response, Server, Socket, File,
DataPipeline, Test, Terminal, System, and (off Windows) Git — and
`ActionRegistry.createBuiltInActions()` calls each once.

| File | Lines | Description |
|------|-------|-------------|
| `ActionRegistry.swift` | ~489 | Verb → implementation mapping (lock-guarded class) |
| `ActionRunner.swift` | ~640 | Unified execution, verb canonicalization, ActionDriverChannel |
| `ActionError.swift` | ~345 | Action error types |
| `ActionProtocol.swift` | ~309 | ActionImplementation protocol, ActionRole enum, ActionModule |
| `ActionDescriptors.swift` | ~168 | ResultDescriptor, ObjectDescriptor |
| `Modules/*.swift` | — | The eleven module arrays |
| `BuiltIn/ComputeAction.swift` | ~2,596 | Compute, Validate, Compare, Create, Update, Sort, Merge, Delete, Transform |
| `BuiltIn/ReturnAction.swift` | ~268 | Return |
| `BuiltIn/ThrowAction.swift` | ~33 | Throw |
| `BuiltIn/SendAction.swift` | ~111 | Send, MessagingService, MessageSentEvent |
| `BuiltIn/LogAction.swift` | ~248 | Log, LoggingService, LogLevel |
| `BuiltIn/StoreAction.swift` | ~281 | Store, DataStoredEvent |
| `BuiltIn/WriteAction.swift` | ~273 | Write, URLWriteResult |
| `BuiltIn/PublishAction.swift` | ~54 | Publish, VariablePublishedEvent |
| `BuiltIn/NotifyAction.swift` | ~119 | Notify, NotificationSentEvent |
| `BuiltIn/EmitAction.swift` | ~144 | Emit, DomainEvent |
| `BuiltIn/ServerActions.swift` | ~1,283 | Start, Stop, Listen, Keepalive, Connect, Broadcast, Close |
| `BuiltIn/ExtractAction.swift` | ~1,083 | Data extraction, typed extraction (ARO-0046), Retrieve, Receive, Read |
| `BuiltIn/QueryActions.swift` | ~878 | Map, Reduce, Filter, Group |
| `BuiltIn/ParseAction.swift` | ~841 | HTML/XML, Link headers, format dispatch |
| `BuiltIn/FileActions.swift` | ~690 | List (+ `LazyDirectoryList` pull iterator, issue #198), Stat, Exists, Make, Copy, Move, Append |
| `BuiltIn/StreamAction.swift` | ~544 | Stream/Subscribe for files, SSE, WebSocket |
| `BuiltIn/ExecAction.swift` | ~500 | System command execution |
| `BuiltIn/TestActions.swift` | ~382 | Given, When, Then, Assert |
| `BuiltIn/GitActions.swift` | ~361 | Status, Stage, Commit, Push, Pull, Clone, Checkout, Tag (ARO-0080) |
| `BuiltIn/TerminalActions.swift` | ~340 | Prompt, Select, Clear, Show, Render, Repaint |
| `BuiltIn/AcceptAction.swift` | ~260 | State transitions |
| `BuiltIn/RequestAction.swift` | ~251 | HTTP requests |
| `BuiltIn/WhereConditionEvaluator.swift` | ~233 | `where` clauses at runtime |
| `BuiltIn/ProbeAction.swift` | ~137 | Reachability checks |
| `BuiltIn/CallAction.swift` | ~135 | External service calls |
| `BuiltIn/ScheduleAction.swift` | ~123 | Delayed/recurring tasks |
| `BuiltIn/SleepAction.swift` | ~116 | Execution delay (never deferred — the delay *is* the effect) |
| `BuiltIn/SplitAction.swift` | ~91 | String splitting by regex |
| `BuiltIn/JoinAction.swift` | ~73 | Collection joining |
| **Total** | | **71 built-in actions, ~130 verbs** (`aro actions`) |

### Events (`Events/`)

| File | Lines | Description |
|------|-------|-------------|
| `EventBus.swift` | ~805 | Pub-sub routing, in-flight tracking, flush continuations |
| `EventTypes.swift` | ~401 | RuntimeEvent implementations |
| `StateGuard.swift` | ~129 | Event filtering by entity state |

### Streaming (`Streaming/`)

| File | Lines | Description |
|------|-------|-------------|
| `AROStream.swift` | ~494 | The stream type itself |
| `CSVStreamParser.swift` | ~411 | Incremental CSV |
| `SpillableHashMap.swift` | ~287 | Memory-bounded hash map with disk spill |
| `StreamTee.swift` | ~258 | Fan-out for multi-consumer streams |
| `JSONStreamParser.swift` | ~257 | Incremental JSON/JSONL parsing |
| `PipelineOptimizer.swift` | ~244 | Aggregation fusion, stream teeing |
| `StreamingValue.swift` | ~243 | The lazy value wrapper `isLazy()` detects |
| `ExternalSort.swift` | ~230 | Spill-to-disk sorting for large datasets |
| `StreamPrefetch.swift` | ~191 | Producer run-ahead (`ARO_STREAM_PREFETCH`) |
| `BackpressureMonitor.swift` | ~170 | Bounded-channel pressure |
| `RingBuffer.swift` | ~155 | The bounded channel |
| `BodyFolds.swift` | ~113 | `sha256` / `length` / `lines` over a body, a chunk at a time (ARO-0090) |

### Bridge (`Bridge/`) — the C ABI surface

There is no `AROCRuntime` module and no `RuntimeBridge.swift`. The C surface was
folded into `ARORuntime` (now a static library exporting `@_cdecl` symbols) and
split by concern: **248 `@_cdecl` functions**, 241 of them here.

| File | Lines | `@_cdecl` | Description |
|------|-------|-----------|-------------|
| `RuntimeExecutionBridge.swift` | ~2,118 | 37 | Feature-set entry, variable ops, `evaluateExpressionJSON` |
| `ServiceBridge.swift` | ~2,045 | 20 | `NativeHTTPServer`, static-plugin registration, file/socket services |
| `ActionBridge.swift` | ~1,055 | 68 | Action `@_cdecl` wrappers |
| `RuntimeCoreBridge.swift` | ~699 | 13 | `AROCRuntimeHandle`, `AROCContextHandle`, `AROCValue`, lifecycle |
| `RuntimeEventRecordingBridge.swift` | ~642 | 6 | `aro_runtime_register_*`, `aro_register_*`, event recording |
| `FileWatcherBridge.swift` | ~598 | 16 | File monitoring |
| `SocketBridge.swift` | ~592 | 26 | TCP sockets |
| `FileSystemBridge.swift` | ~571 | 18 | File I/O |
| `AROFuture.swift` | ~355 | 5 | Futures + `ActionTaskExecutor` (ARO-0088) |
| `HTTPClientBridge.swift` | ~289 | 18 | Outbound HTTP |
| `HTTPServerBridge.swift` | ~170 | 10 | Server control |
| `RuntimeResponseFormatting.swift` | ~117 | 4 | Response rendering |
| `LazyActionPolicy.swift` | ~107 | 0 | Which verbs may defer |
| `DeepCallStack.swift` | ~91 | 0 | Deep recursion without blowing the C stack |

---

## Compiler Package (`Sources/AROCompiler/`)

Eleven files, ~7,100 lines. Everything except `Linker.swift` is under `LLVMC/`.

| File | Lines | Description |
|------|-------|-------------|
| `LLVMC/LLVMCodeGenerator.swift` | ~2,285 | Main code generator, using the LLVM C API |
| `Linker.swift` | ~2,075 | `LLVMEmitter`, `PluginSymbolRenamer`, `PythonLibraryFinder`, platform linking |
| `LLVMC/LLVMExternalDeclEmitter.swift` | ~720 | Runtime function declarations |
| `LLVMC/ConstantFolder.swift` | ~388 | Folds constant expressions before serialization |
| `LLVMC/LLVMDebugInfoEmitter.swift` | ~336 | DWARF, via the `AROCDebugInfo` C shim |
| `LLVMC/ModifierBinder.swift` | ~334 | Framework-variable binds for a statement's clauses |
| `LLVMC/LLVMCodeGenContext.swift` | ~252 | Module, builder, and type/string caches |
| `LLVMC/ExpressionSerializer.swift` | ~248 | Expression AST → JSON for runtime evaluation |
| `LLVMC/LLVMTypeMapper.swift` | ~190 | Descriptor struct type definitions |
| `LLVMC/LLVMErrorReporter.swift` | ~150 | Code-generator diagnostics |
| `LLVMC/DescriptorBuilder.swift` | ~126 | Builds descriptor structs per statement |

### LLVMCodeGenerator Key Methods

| Method | Purpose |
|--------|---------|
| `generate(_:)` | Main entry point; ends by serializing `module.description` to `.ll` |
| `generateFeatureSet(_:)` | Feature set → LLVM function, with `normal_return` / `error_exit` |
| `generateAROStatement(_:index:errorBlock:)` | Statement → descriptors + call, plus `when`-guard blocks |
| `generateMatchStatement(_:…)` | Linear chain of comparisons, not a `switch` |
| `generateForEachLoop(_:…)` | Runtime dispatch between an array path and a streaming one |
| `generateStreamForEachLoop(_:…)` | Outlines the loop body into its own LLVM function |
| `generateRangeLoop` / `generateWhileLoop` / `generateBreakStatement` | ARO-0002 / ARO-0072 loops |
| `generateMainFunction()` | Entry point, handler registration, plugin registration |

---

## CLI Package (`Sources/AROCLI/`)

| File | Lines | Description |
|------|-------|-------------|
| `ARO.swift` | ~137 | Entry point, ArgumentParser root command |
| `Commands/CheckCommand.swift` | ~641 | `aro check` — validation + `aro check plugins` |
| `Commands/BuildCommand.swift` | ~471 | `aro build` — native compilation |
| `Commands/RunCommand.swift` | ~427 | `aro run` — interpreter execution |
| `Commands/CompileCommand.swift` | ~231 | `aro compile` — IR only; also hosts `ASTPrinter` |
| `Commands/TestCommand.swift` | ~197 | `aro test` — colocated tests |
| `Commands/ActionsCommand.swift` | — | `aro actions`, `aro actions --qualifiers` |
| `Commands/DiffCommand.swift`, `GraphDiffHTMLReport.swift` | — | `aro diff --graph` |
| `Commands/ReplCommand.swift`, `KernelCommand.swift` | — | `aro repl`, `aro repl --json`, `aro kernel` (ARO-0091) |
| `Commands/DebugCommand.swift`, `DebugReplayRunner.swift`, `CLIDebugFrontend.swift` | — | `aro debug` |
| `Commands/LSPCommand.swift`, `MCPCommand.swift`, `UICommand.swift` | — | `aro lsp`, `aro mcp`, `aro ui` |
| `Commands/AddCommand.swift`, `RemoveCommand.swift`, `PluginsCommand.swift`, `NewCommand.swift` | — | Package management (ARO-0045) |
| `REPL/REPLSession.swift` | — | REPL session state; TTY-gated `TerminalService` |

---

## File Dependencies

```
                 ┌─────────────────┐
                 │   AROCLI        │
                 └────────┬────────┘
                          │
         ┌────────────────┼────────────────┐
         │                │                │
         ▼                ▼                ▼
┌─────────────┐   ┌─────────────┐   ┌─────────────┐
│ AROParser   │   │ ARORuntime  │   │ AROCompiler │
└──────┬──────┘   └──────┬──────┘   └──────┬──────┘
       │                 │                 │
       │                 │                 │
       └────────────┬────┴─────────────────┘
                    │
                    ▼
            ┌─────────────┐
            │ Foundation  │
            └─────────────┘
```

---

## Build-Time Dependencies

| Package | Used By | Purpose |
|---------|---------|---------|
| `swift-argument-parser` | AROCLI | Command-line parsing |
| `swift-nio` | ARORuntime | HTTP server (interpreter mode) |
| `FlyingFox` | ARORuntime | HTTP server (Windows) |
| `async-http-client` | ARORuntime | HTTP client |
| `Swifty-LLVM` (branch `main`) | AROCompiler | Typed IR construction |
| LLVM 20 | AROCompiler | IR → object compilation; enforced by linker flags, not the manifest |
| `AROCDebugInfo` (in-repo C target) | AROCompiler | `llvm-c/DebugInfo.h`, which Swifty-LLVM does not expose |
| `Clibgit2` | ARORuntime | Native Git (ARO-0080) |

---

## Reading Order for Understanding

1. **Start with syntax**: `Token.swift`, `Lexer.swift`
2. **Understand AST**: `AST.swift`, `Parser.swift`
3. **See execution**: `FeatureSetExecutor.swift`, `ActionImplementation.swift`
4. **Study events**: `EventBus.swift`, `EventTypes.swift`
5. **Explore compilation**: `LLVMC/LLVMCodeGenerator.swift`
6. **Understand bridge**: `Bridge/RuntimeCoreBridge.swift`, `Bridge/ActionBridge.swift`, `Bridge/AROFuture.swift`

---

## Finding Specific Functionality

| If you want to understand... | Look at... |
|------------------------------|------------|
| How tokens are classified | `Lexer.swift:scanIdentifierOrKeyword()` + the `reservedWords` table |
| How expressions are parsed | `Parser.swift:parseExpression()` |
| How actions are registered | `Actions/Modules/*.swift` → `ActionRegistry.createBuiltInActions()` |
| How verbs are canonicalized | `ActionRunner.swift:verbMappings` |
| How events are dispatched | `EventBus.swift:publishAndTrack()` |
| How typed extraction works | `ExtractAction.swift` + `SchemaRegistry` (ARO-0046) |
| How LLVM IR is generated | `LLVMC/LLVMCodeGenerator.swift`; the text comes from `module.description` |
| Which statements defer, and why | `Bridge/LazyActionPolicy.swift`, `Bridge/AROFuture.swift` (ARO-0088) |
| Which routes need their body as a value | `AROParser/BodyMaterialization.swift` (ARO-0090) |
| How a compiled binary serves HTTP | `Bridge/ServiceBridge.swift:NativeHTTPServer` |
| How descriptor types are defined | `LLVMC/LLVMTypeMapper.swift` |
| How C calls Swift | `Bridge/ActionBridge.swift:executeAction()` |
| How pointers are managed | `Bridge/RuntimeCoreBridge.swift:AROCRuntimeHandle` |
| How streaming works | `Streaming/JSONStreamParser.swift`, `RuntimeContext:isLazy()` |
| How recursive directory listing streams without buffering | `FileSystem/FileSystemService.swift:listStream()` (pull-based `AsyncThrowingStream(unfolding:)` + `LazyDirectoryList`, issue #198) |
| How `Read` opts out of format-aware parsing | `FileSystem/FileFormat.swift:isRawQualifier(_:)` / `fromQualifier(_:)` + `ExtractAction.swift` (issue #197) |
| How the REPL exposes real terminal capabilities | `AROCLI/REPL/REPLSession.swift:init()` — TTY-gated `TerminalService` registration (issue #172) |
| How aggregations are fused | `Streaming/PipelineOptimizer.swift` |
| How plugins are loaded | `Plugins/UnifiedPluginLoader.swift`, `Plugins/NativePluginHost.swift` |
| How templates work | `Templates/TemplateParser.swift`, `Templates/TemplateService.swift` |
| How terminal UI works | `Terminal/ShadowBuffer.swift`, `Terminal/ANSIRenderer.swift` |

---

## Test Files

| Directory | Contents |
|-----------|----------|
| `Tests/AROParserTests/` | Lexer, parser, AST tests |
| `Tests/AROuntimeTests/` | Action, context, event tests (the missing `R` is in the directory name) |
| `Tests/AROCompilerTests/` | IR generation tests |
| `Tests/AROCLITests/` | End-to-end CLI behaviour |
| `Tests/AROLSPTests/`, `AROAskTests/`, `AROPackageManagerTests/`, `SOLAROTests/` | Per-tool suites |
| `Tests/IntegrationTestsRunner/` | The Perl harness: `run-tests.pl`, `lib/AROTest/` |
| `Examples/` | 109 example applications, 102 with a `test.hint` |

---

## Documentation Files

| File | Purpose |
|------|---------|
| `CLAUDE.md` | Build commands, architecture overview |
| `README.md` | Project introduction |
| `OVERVIEW.md` | Developer documentation |
| `Proposals/*.md` | Language specifications |
| `Book/TheLanguageGuide/` | User documentation |
| `Book/TheConstructionStudies/` | This book |

---

*End of The Construction Studies*
