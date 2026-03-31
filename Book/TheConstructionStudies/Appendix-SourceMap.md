# Appendix: Source Map

This appendix provides a quick reference to key source files in the ARO implementation.

---

## Parser Package (`Sources/AROParser/`)

| File | Lines | Description |
|------|-------|-------------|
| `Lexer.swift` | ~960 | Tokenization, string interpolation, regex detection, hex/binary/raw/triple-quoted literals |
| `Token.swift` | ~200 | Token types, articles, prepositions |
| `Parser.swift` | ~2000 | Recursive descent + Pratt parsing, 9 statement types |
| `Parser/TokenStream.swift` | ~100 | Token stream protocol and error recovery |
| `AST.swift` | ~1600 | AST node definitions, visitor pattern |
| `SemanticAnalyzer.swift` | ~800 | Symbol tables, data flow analysis |
| `EventChainAnalyzer.swift` | ~200 | Circular event chain and orphan detection |
| `SymbolTable.swift` | ~200 | Symbol storage, visibility levels, DataType enum |
| `SourceLocation.swift` | ~100 | SourceLocation, SourceSpan, Locatable protocol |
| `Errors.swift` | ~200 | LexerError, ParserError, SemanticError, Diagnostic, DiagnosticCollector |
| `Compiler.swift` | ~150 | Pipeline orchestration |
| `Exports.swift` | — | Public API re-exports |

### Key Entry Points

**Parsing a source file**:
```swift
let lexer = Lexer(source: sourceCode)
let tokens = try lexer.tokenize()
let parser = Parser(tokens: tokens)
let program = try parser.parse()
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
| `ExecutionEngine.swift` | ~850 | Program execution, handler registration (actor) |
| `FeatureSetExecutor.swift` | ~600 | Statement execution, control flow, cached VerbSets (ARO-0162) |
| `ExecutionContext.swift` | ~200 | ExecutionContext protocol |
| `RuntimeContext.swift` | ~500 | RuntimeContext actor (protocol implementation) |
| `RuntimeContainer.swift` | ~100 | DI container for infrastructure services |
| `VerbSets.swift` | ~45 | Canonical verb classification (shared by interpreter and compiler) |
| `TypedValue.swift` | ~100 | Type-preserving value wrapper |
| `OutputContext.swift` | ~50 | Output mode (.human, .machine, .developer) |
| `StatementScheduler.swift` | ~100 | Statement scheduling utilities |
| `BoundedSet.swift` | ~50 | Bounded set for deduplication |
| `DependencyGraph.swift` | ~100 | Dependency graph utilities |

### Actions (`Actions/`)

| File | Lines | Description |
|------|-------|-------------|
| `ActionRegistry.swift` | ~100 | Verb → implementation mapping (actor) |
| `ActionProtocol.swift` | ~200 | ActionImplementation protocol, ActionRole enum, ActionModule |
| `ActionRunner.swift` | ~400 | Unified execution (sync/async), verb canonicalization, ActionDriverChannel |
| `ActionDescriptors.swift` | ~100 | ResultDescriptor, ObjectDescriptor |
| `ActionError.swift` | ~50 | Action error types |
| `BuiltIn/ExtractAction.swift` | ~800 | Data extraction, typed extraction (ARO-0046), Retrieve, Receive, Read |
| `BuiltIn/ComputeAction.swift` | ~1400 | Compute, Validate, Compare, Create, Update, Sort, Merge, Delete, Transform |
| `BuiltIn/ResponseActions.swift` | ~1200 | Return, Throw, Send, Log, Store, Write, Publish, Notify, Emit |
| `BuiltIn/RequestAction.swift` | ~200 | HTTP requests |
| `BuiltIn/ServerActions.swift` | ~1300 | Start, Stop, Listen, Keepalive, Connect, Broadcast, Close |
| `BuiltIn/TerminalActions.swift` | ~300 | Prompt, Select, Clear, Show, Render, Repaint |
| `BuiltIn/TestActions.swift` | ~300 | Given, When, Then, Assert |
| `BuiltIn/FileActions.swift` | ~700 | List, Stat, Exists, Make, Copy, Move, Append |
| `BuiltIn/QueryActions.swift` | ~300 | Map, Reduce, Filter |
| `BuiltIn/StreamAction.swift` | ~200 | Stream/Subscribe for files, SSE, WebSocket |
| `BuiltIn/ParseAction.swift` | ~200 | ParseHtml, ParseLinkHeader |
| `BuiltIn/CallAction.swift` | ~100 | External service calls |
| `BuiltIn/ExecAction.swift` | ~200 | System command execution |
| `BuiltIn/SplitAction.swift` | ~50 | String splitting by regex |
| `BuiltIn/JoinAction.swift` | ~50 | Collection joining |
| `BuiltIn/AcceptAction.swift` | ~50 | State transitions |
| `BuiltIn/ScheduleAction.swift` | ~50 | Delayed/recurring tasks |
| `BuiltIn/SleepAction.swift` | ~50 | Execution delay |
| **Total** | | **61 built-in actions** |

### Events (`Events/`)

| File | Lines | Description |
|------|-------|-------------|
| `EventBus.swift` | ~290 | Pub-sub routing, in-flight tracking |
| `EventTypes.swift` | ~320 | RuntimeEvent implementations |
| `StateGuard.swift` | ~130 | Event filtering by entity state |

### Streaming (`Streaming/`)

| File | Lines | Description |
|------|-------|-------------|
| `JSONStreamParser.swift` | ~250 | Incremental JSON/JSONL parsing |
| `PipelineOptimizer.swift` | ~200 | Aggregation fusion, stream teeing |
| `ExternalSort.swift` | ~300 | Spill-to-disk sorting for large datasets |
| `SpillableHashMap.swift` | ~250 | Memory-bounded hash map with disk spill |

### Bridge (`Bridge/`)

| File | Lines | Description |
|------|-------|-------------|
| `RuntimeBridge.swift` | ~1000 | Runtime lifecycle, variable ops |
| `ActionBridge.swift` | ~500 | @_cdecl action wrappers |
| `ServiceBridge.swift` | ~300 | HTTP/File/Socket C interface |

---

## Compiler Package (`Sources/AROCompiler/`)

| File | Lines | Description |
|------|-------|-------------|
| `Compiler.swift` | ~200 | High-level compilation API |
| `Linker.swift` | ~1400 | Object emission, platform linking |

### LLVM C API (`LLVMC/`)

The compiler uses Swifty-LLVM for type-safe LLVM IR generation:

| File | Description |
|------|-------------|
| `LLVMCodeGenerator.swift` | Main code generator using LLVM C API |
| `LLVMCodeGenContext.swift` | Module, builder, and type caches |
| `LLVMTypeMapper.swift` | Descriptor struct type definitions |
| `LLVMExternalDeclEmitter.swift` | Runtime function declarations |

### LLVMCodeGenerator Key Methods

| Method | Purpose |
|--------|---------|
| `generate(_:)` | Main entry point |
| `generateFeatureSet(_:)` | Feature set → LLVM function |
| `generateStatement(_:)` | Statement → descriptor + call |
| `generateForEachLoop(_:)` | Sequential iteration |
| `generateParallelForEachLoop(_:)` | Parallel with body function |
| `generateMain()` | Entry point, handler registration |

---

## CLI Package (`Sources/AROCLI/`)

| File | Lines | Description |
|------|-------|-------------|
| `ARO.swift` | ~50 | Entry point, ArgumentParser root command |
| `Commands/RunCommand.swift` | ~150 | `aro run` - interpreter execution |
| `Commands/BuildCommand.swift` | ~200 | `aro build` - native compilation |
| `Commands/CheckCommand.swift` | ~300 | `aro check` - syntax validation + `aro check plugins` compatibility |
| `Commands/CompileCommand.swift` | ~100 | `aro compile` - IR only |
| `Commands/TestCommand.swift` | ~100 | `aro test` - run colocated tests |
| `Commands/LSPCommand.swift` | ~50 | `aro lsp` - language server |
| `Commands/MCPCommand.swift` | ~50 | `aro mcp` - MCP server |
| `Commands/ReplCommand.swift` | ~50 | `aro repl` - interactive session |
| `Commands/AddCommand.swift` | ~100 | `aro add` - package management |
| `Commands/RemoveCommand.swift` | ~100 | `aro remove` - package management |
| `Commands/PluginsCommand.swift` | ~100 | `aro plugins` - plugin management |

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
| `swift-nio` | ARORuntime | HTTP server (interpreter) |
| `async-http-client` | ARORuntime | HTTP client |
| LLVM | AROCompiler | IR → object compilation |

---

## Reading Order for Understanding

1. **Start with syntax**: `Token.swift`, `Lexer.swift`
2. **Understand AST**: `AST.swift`, `Parser.swift`
3. **See execution**: `FeatureSetExecutor.swift`, `ActionImplementation.swift`
4. **Study events**: `EventBus.swift`, `EventTypes.swift`
5. **Explore compilation**: `LLVMC/LLVMCodeGenerator.swift`
6. **Understand bridge**: `Bridge/RuntimeBridge.swift`, `Bridge/ActionBridge.swift`

---

## Finding Specific Functionality

| If you want to understand... | Look at... |
|------------------------------|------------|
| How tokens are classified | `Lexer.swift:classifyIdentifier()` |
| How expressions are parsed | `Parser.swift:parseExpression()` |
| How actions are registered | `ActionRegistry.swift` (actor) |
| How verbs are canonicalized | `ActionRunner.swift:verbMappings` |
| How events are dispatched | `EventBus.swift:publishAndTrack()` |
| How typed extraction works | `ExtractAction.swift` + `SchemaRegistry` (ARO-0046) |
| How LLVM IR is generated | `LLVMC/LLVMCodeGenerator.swift` |
| How descriptor types are defined | `LLVMC/LLVMTypeMapper.swift` |
| How C calls Swift | `Bridge/ActionBridge.swift:executeAction()` |
| How pointers are managed | `Bridge/RuntimeBridge.swift:AROCRuntimeHandle` |
| How streaming works | `Streaming/JSONStreamParser.swift`, `RuntimeContext:isLazy()` |
| How aggregations are fused | `Streaming/PipelineOptimizer.swift` |
| How plugins are loaded | `Plugins/UnifiedPluginLoader.swift`, `Plugins/NativePluginHost.swift` |
| How templates work | `Templates/TemplateParser.swift`, `Templates/TemplateService.swift` |
| How terminal UI works | `Terminal/ShadowBuffer.swift`, `Terminal/ANSIRenderer.swift` |

---

## Test Files

| Directory | Contents |
|-----------|----------|
| `Tests/AROParserTests/` | Lexer, parser, AST tests |
| `Tests/ARORuntimeTests/` | Action, context, event tests |
| `Tests/AROCompilerTests/` | IR generation tests |
| `Tests/AROIntegrationTests/` | End-to-end tests |
| `Examples/` | Working example applications |

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
