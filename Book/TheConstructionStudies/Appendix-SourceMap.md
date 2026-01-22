# Appendix: Source Map

This appendix provides a quick reference to key source files in the ARO implementation.

---

## Parser Package (`Sources/AROParser/`)

| File | Lines | Description |
|------|-------|-------------|
| `Lexer.swift` | ~700 | Tokenization, string interpolation, regex detection |
| `Token.swift` | ~200 | Token types, articles, prepositions |
| `Parser.swift` | ~1700 | Recursive descent + Pratt parsing |
| `AST.swift` | ~1300 | AST node definitions, visitor pattern |
| `SemanticAnalyzer.swift` | ~800 | Symbol tables, data flow analysis |
| `SymbolTable.swift` | ~200 | Symbol storage, visibility levels |
| `Compiler.swift` | ~150 | Pipeline orchestration |
| `DiagnosticEngine.swift` | ~100 | Error collection and reporting |

### Key Entry Points

**Parsing a source file**:
```swift
let lexer = Lexer(source: sourceCode)
let tokens = lexer.tokenize()
let parser = Parser(tokens: tokens)
let program = try parser.parse()
```

**Semantic analysis**:
```swift
let analyzer = SemanticAnalyzer()
let analyzed = try analyzer.analyze(program)
```

---

## Runtime Package (`Sources/ARORuntime/`)

### Core (`Core/`)

| File | Lines | Description |
|------|-------|-------------|
| `ExecutionEngine.swift` | ~850 | Program execution, handler registration |
| `FeatureSetExecutor.swift` | ~600 | Statement execution, control flow |
| `RuntimeContext.swift` | ~300 | Variable binding, service access |
| `Runtime.swift` | ~150 | Top-level runtime container |

### Actions (`Actions/`)

| File | Lines | Description |
|------|-------|-------------|
| `ActionRegistry.swift` | ~100 | Verb → implementation mapping |
| `ActionImplementation.swift` | ~80 | Action protocol definition |
| `ActionRunner.swift` | ~200 | Unified execution (sync/async) |
| `BuiltIn/ExtractAction.swift` | ~150 | Data extraction |
| `BuiltIn/ComputeAction.swift` | ~300 | Computations (length, hash, arithmetic) |
| `BuiltIn/ReturnAction.swift` | ~100 | Response generation |
| `BuiltIn/StoreAction.swift` | ~200 | Repository storage |
| `BuiltIn/EmitAction.swift` | ~100 | Event emission |
| *(46 more actions)* | | |

### Events (`Events/`)

| File | Lines | Description |
|------|-------|-------------|
| `EventBus.swift` | ~290 | Pub-sub routing, in-flight tracking |
| `EventTypes.swift` | ~320 | RuntimeEvent implementations |
| `StateGuard.swift` | ~130 | Event filtering by entity state |

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
| `LLVMCodeGeneratorV2.swift` | Main code generator using LLVM C API |
| `LLVMCodeGenContext.swift` | Module, builder, and type caches |
| `LLVMTypeMapper.swift` | Descriptor struct type definitions |
| `LLVMExternalDeclEmitter.swift` | Runtime function declarations |

### LLVMCodeGeneratorV2 Key Methods

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
| `main.swift` | ~50 | Entry point |
| `Commands/RunCommand.swift` | ~150 | `aro run` - interpreter execution |
| `Commands/BuildCommand.swift` | ~200 | `aro build` - native compilation |
| `Commands/CheckCommand.swift` | ~80 | `aro check` - syntax validation |
| `Commands/CompileCommand.swift` | ~100 | `aro compile` - IR only |

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
5. **Explore compilation**: `LLVMC/LLVMCodeGeneratorV2.swift`
6. **Understand bridge**: `Bridge/RuntimeBridge.swift`, `Bridge/ActionBridge.swift`

---

## Finding Specific Functionality

| If you want to understand... | Look at... |
|------------------------------|------------|
| How tokens are classified | `Lexer.swift:classifyIdentifier()` |
| How expressions are parsed | `Parser.swift:parseExpression()` |
| How actions are registered | `ActionRegistry.swift` (actor) |
| How events are dispatched | `EventBus.swift:publishAndTrack()` |
| How LLVM IR is generated | `LLVMC/LLVMCodeGeneratorV2.swift` |
| How descriptor types are defined | `LLVMC/LLVMTypeMapper.swift` |
| How C calls Swift | `Bridge/ActionBridge.swift:executeAction()` |
| How pointers are managed | `Bridge/RuntimeBridge.swift:AROCRuntimeHandle` |

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
