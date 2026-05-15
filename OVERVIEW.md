# The ARO Programming Language

| **Website:** https://arolang.github.io/aro/<br />Reference implementation of a parser, compiler, and runtime for the **ARO** programming language. | ![ARO Logo](./Graphics/logo-small.png) |
|---------------------------------------------------------------------------------------------------------|----------------------------------------|

## Overview

ARO is a declarative language for specifying business features in a human-readable
format that can be interpreted or compiled to a native binary. Every statement
follows the same Action-Result-Object grammar:

```
Action [the] <Result> preposition [the] <Object>.
```

This document describes the implementation. For the language guide and tutorials,
see the [Wiki](https://github.com/arolang/aro/wiki) and the
[ARO Language Guide](https://github.com/arolang/aro/releases/latest/download/ARO-Language-Guide.pdf).

### Key Features

- **Event-Driven Execution**: Feature sets are triggered by events, not direct calls.
- **Application Lifecycle**: `Application-Start` (required), `Application-End: Success` and `Application-End: Error` (optional).
- **Contract-First HTTP APIs**: Routes are defined in `openapi.yaml`; handlers are named after `operationId`. No contract → no HTTP server.
- **Lazy Async Execution**: Actions return `AROFuture` handles by default; values are forced only at consumer reads, enabling implicit pipeline parallelism.
- **Built-in Services**: SwiftNIO HTTP server / AsyncHTTPClient, file I/O with FileMonitor, TCP sockets, WebSocket, SSE, terminal UI.
- **Native Git** (ARO-0080): `Retrieve`, `Stage`, `Commit`, `Push`, `Pull`, `Clone`, `Checkout`, `Tag` against a `<git>` system object via libgit2.
- **Plugin System**: Load Swift, Rust, C/C++, and Python plugins from a `Plugins/` directory. Plugins can register actions and value qualifiers.
- **Native Compilation**: `aro build` lowers to LLVM IR, links against `AROCRuntime`, and produces standalone binaries that bundle plugins.
- **Store Files** (ARO-0073): YAML-seeded, file-backed repositories whose writability is controlled by filesystem permissions.
- **Testing Framework**: BDD-style feature sets with `Given` / `When` / `Then` (`aro test`).
- **LSP Server** (ARO-0034): Diagnostics and navigation for editor integration.
- **Package Manager** (ARO-0045): `aro add` / `aro remove` for plugin packages described in `plugin.yaml`.

### Example

```aro
(* Entry point — exactly one per application *)
(Application-Start: My Service) {
    Log "Starting service..." to the <console>.
    Start the <http-server> with <contract>.
    Keepalive the <application> for the <events>.
    Return an <OK: status> for the <startup>.
}

(* Graceful shutdown — optional *)
(Application-End: Success) {
    Log "Goodbye!" to the <console>.
    Stop the <http-server> with <application>.
    Return an <OK: status> for the <shutdown>.
}

(* HTTP route handler — name matches operationId in openapi.yaml *)
(listUsers: User API) {
    Retrieve the <users> from the <user-repository>.
    Return an <OK: status> with <users>.
}

(* Domain event handler *)
(Send Welcome Email: UserCreated Handler) {
    Extract the <user> from the <event: user>.
    Send the <welcome-email> to the <user: email>.
    Return an <OK: status> for the <notification>.
}

(* Test feature set — run with: aro test *)
(add-numbers-test: Calculator Test) {
    Given the <a> with 5.
    Given the <b> with 3.
    When the <sum> from the <add-numbers>.
    Then the <sum> with 8.
}
```

## Project Structure

```
ARO-Lang/
├── Package.swift           # Swift package manifest (Swift 6.2)
├── README.md               # Project overview & install
├── OVERVIEW.md             # This file — implementation reference
├── CLAUDE.md               # Codebase guidance for AI assistants
├── Sources/
│   ├── AROParser/          # Lexer, Parser, AST, SymbolTable, SemanticAnalyzer, Compiler
│   ├── ARORuntime/         # Interpreter
│   │   ├── Actions/                # Action protocol, registry, built-in actions
│   │   ├── Application/            # ApplicationLoader, lifecycle
│   │   ├── Async/                  # AROFuture, lazy-action handles, ActionTaskExecutor
│   │   ├── Bridge/                 # Cross-module bridging types
│   │   ├── Core/                   # ExecutionEngine, FeatureSetExecutor, ExecutionContext
│   │   ├── DateTime/               # Date/time and date-range support (ARO-0041)
│   │   ├── Events/                 # EventBus, RuntimeEvent, state guards (ARO-0022)
│   │   ├── FileSystem/             # File I/O, FileMonitor, format-aware I/O (ARO-0040)
│   │   ├── Git/                    # libgit2 service, Git actions (ARO-0080)
│   │   ├── HTTP/                   # SwiftNIO server, AsyncHTTPClient, SSE
│   │   ├── Logging/                # Structured logging (ARO-0059)
│   │   ├── MCP/                    # Model Context Protocol integration
│   │   ├── Metrics/                # Runtime metrics, Prometheus export (ARO-0044)
│   │   ├── OpenAPI/                # OpenAPISpec parser, RouteRegistry
│   │   ├── Parameters/             # Command-line parameters (ARO-0047)
│   │   ├── Plugins/                # Native, Python, Swift plugin hosts; UnifiedPluginLoader
│   │   ├── Qualifiers/             # QualifierRegistry, plugin qualifier dispatch
│   │   ├── Services/               # PluginLoader and other discovery services
│   │   ├── Sockets/                # TCP server / client
│   │   ├── Store/                  # Store files, repositories (ARO-0073)
│   │   ├── Streaming/              # Lazy evaluation, Stream Tee, fusion (ARO-0051)
│   │   ├── System/                 # System object resolution
│   │   ├── SystemObjects/          # <git>, <console>, <env>, ...
│   │   ├── Templates/              # Mustache-style Render action (ARO-0050)
│   │   ├── Terminal/               # Terminal UI shadow buffer
│   │   ├── Testing/                # Given / When / Then framework
│   │   └── WebSocket/              # WebSocket server (ARO-0048)
│   ├── AROCompiler/        # Native compilation: LLVMCodeGenerator, Linker
│   ├── AROCRuntime/        # C-callable Swift runtime bridge for compiled binaries
│   ├── AROCLI/             # CLI: run, build, compile, check, test, add, remove
│   ├── AROLSP/             # Language Server Protocol implementation (ARO-0034)
│   ├── AROPackageManager/  # Plugin package management (ARO-0045)
│   ├── AROVersion/         # Version constants
│   └── Clibgit2/           # libgit2 system module for Git actions
├── Examples/               # 100+ examples organized by topic — see `ls Examples/`
├── Documentation/          # Developer guides
├── Book/                   # The ARO Language Guide (mdBook source)
├── Website/                # Public website source
├── Tests/                  # Unit and integration tests
└── Proposals/              # Language Evolution Proposals (ARO-0001 .. ARO-0081)
```

## Language Specification

The language is specified in numbered Evolution Proposals under `Proposals/`. The
numbering is sparse — proposals are added or rejected over time, so gaps are
expected. Below is the current set, grouped by theme.

### Core Language

| # | Proposal | Description |
|---|----------|-------------|
| 0001 | Language Fundamentals | Core syntax, literals, expressions, scoping |
| 0002 | Control Flow | `When` guards, `match`, iteration |
| 0003 | Type System | Types, OpenAPI integration, schemas |
| 0004 | Actions | Action roles, built-in actions, extensions |
| 0005 | Application Architecture | App structure, lifecycle, concurrency |
| 0006 | Error Philosophy | "Code is the error message" |
| 0007 | Events & Reactive | Events, state, repositories |
| 0008 | I/O Services | HTTP, files, sockets, system objects |
| 0009 | Native Compilation | LLVM, `aro build`, plugins in binaries |
| 0010 | Advanced Features | Regex, dates, exec |
| 0011 | HTML/XML Parsing | `Parse` action for documents |
| 0014 | Domain Modeling | DDD patterns, entities, aggregates |
| 0015 | Testing Framework | Colocated tests, Given / When / Then |
| 0016 | Interoperability | External services, `Call`, plugins |
| 0018 | Query Language | SQL-like queries (data pipelines) |
| 0019 | Standard Library | Primitive types, utilities |
| 0022 | State Guards | Event handler filtering with `field:value` |

### Tooling & Developer Experience

| # | Proposal | Description |
|---|----------|-------------|
| 0030 | IDE Integration | Syntax highlighting, snippets |
| 0031 | Context-Aware Formatting | Adaptive output for machine / human / developer |
| 0034 | Language Server Protocol | LSP server, diagnostics, navigation |
| 0035 | Configurable Runtime | `Configure` action for timeouts, settings |
| 0044 | Runtime Metrics | Execution counts, timing, Prometheus format |
| 0045 | Package Manager | `aro add` / `aro remove`, `plugin.yaml` |
| 0049 | REPL | Interactive read-eval-print loop |
| 0059 | Structured Logging | JSON-shaped log records |
| 0062 | Dead Code Detection | Unreachable feature-set warnings |

### Language Features

| # | Proposal | Description |
|---|----------|-------------|
| 0036 | Extended File Operations | `Exists`, `Stat`, `Make`, `Copy`, `Move` |
| 0037 | Regex Split | `Split` with regex delimiters |
| 0038 | List Element Access | `first`, `last`, `index`, range qualifiers |
| 0040 | Format-Aware I/O | Auto format detection for JSON, YAML, CSV |
| 0041 | Date/Time Ranges | Date arithmetic, ranges, recurrence |
| 0042 | Set Operations | `intersect`, `difference`, `union` |
| 0043 | Sink Syntax | Expressions in result position |
| 0046 | Typed Event Extraction | Schema-validated event data |
| 0047 | Command-Line Parameters | `Parameters` action, CLI argument parsing |
| 0048 | WebSocket | Server, real-time messaging |
| 0050 | Template Engine | Mustache-style `Render` |
| 0051 | Streaming Execution | Lazy evaluation, Stream Tee, aggregation fusion |
| 0052 | Numeric Separators / Terminal UI / Unified URL I/O | (multiple proposals reusing 0052) |
| 0056 | Numeric Literal Underscores | Readable numeric literals |
| 0060 | Raw String Literals | Verbatim string syntax |
| 0067 | Pipeline Operator / Auto Pipeline Detection | Implicit and explicit pipelines |
| 0068 | Extract within Case | Pattern-style extraction in `match` |
| 0071 | Type Narrowing | Flow-sensitive type refinement |
| 0072 | Binary Socket / File Events | Binary payload event handlers |

### Runtime & Compiler Internals

| # | Proposal | Description |
|---|----------|-------------|
| 0053 | Lexer Lookup Optimization / Terminal Shadow Buffer | (multiple proposals reusing 0053) |
| 0054 | Execution Engine Refactor | Engine restructuring |
| 0055 | Lexer Reserved Words Optimization | Faster keyword recognition |
| 0057 | Lexer Cache `peekNext` | Tokenization performance |
| 0061 | AST Visitor Pattern | Traversal abstraction |
| 0063 | Value-Type AST Nodes | Sendable AST representation |
| 0064 | Optimize Event Subscriptions | Subscription cost reduction |
| 0069 | Async Plugin Compilation | Parallel plugin builds |
| 0070 | LLVM Expression Optimization | Native codegen improvements |

### Subsystems

| # | Proposal | Description |
|---|----------|-------------|
| 0073 | Plugin SDK / Store Files | (two proposals reuse 0073: SDK and store-backed repositories) |
| 0080 | Git Actions | Native Git via libgit2 — status, log, stage, commit, push, pull, clone, checkout, tag |
| 0081 | User-Defined Actions | Define custom actions in ARO itself (proposed) |

See `Proposals/README.md` for the full index.

## Building

```bash
swift build                                # Debug build
swift build -c release                     # Release build
swift test                                 # Run unit tests
aro run ./Examples/HelloWorld              # Run an example
```

For full installation and per-platform build instructions, see [README.md](./README.md).

## Usage

### CLI Commands

```bash
aro run ./MyApp           # Run an ARO application (interpreter)
aro build ./MyApp         # Compile to native binary (LLVM IR + link)
aro compile ./MyApp       # Compile and report diagnostics
aro check ./MyApp         # Quick syntax check
aro test ./MyApp          # Run colocated test feature sets
aro add <package>         # Install a plugin package
aro remove <package>      # Uninstall a plugin package
```

### Contract-First HTTP APIs

ARO uses **contract-first** API development. HTTP routes are defined in
`openapi.yaml`, and feature sets are named after `operationId` values. Without
`openapi.yaml`, the HTTP server does not start.

```yaml
# openapi.yaml
paths:
  /users:
    get:
      operationId: listUsers
    post:
      operationId: createUser
```

```aro
(listUsers: User API) {
    Retrieve the <users> from the <user-repository>.
    Return an <OK: status> with <users>.
}

(createUser: User API) {
    Extract the <data> from the <request: body>.
    Create the <user> with <data>.
    Emit a <UserCreated: event> with <user>.
    Return a <Created: status> with <user>.
}
```

### Testing

Tests are feature sets whose business activity ends in `Test`:

```aro
(add-positive-numbers: Calculator Test) {
    Given the <a> with 5.
    Given the <b> with 3.
    When the <sum> from the <add-numbers>.
    Then the <sum> with 8.
}
```

Run tests with `aro test ./Examples/Calculator`.

### As a Library

```swift
import AROParser
import ARORuntime

let source = """
(Application-Start: My App) {
    Log "Hello, ARO!" to the <console>.
    Return an <OK: status> for the <startup>.
}
"""

let result = Compiler.compile(source)

if result.isSuccess {
    let runtime = Runtime()
    try await runtime.run(result.analyzedProgram)
} else {
    for diagnostic in result.diagnostics {
        print("\(diagnostic.severity): \(diagnostic.message)")
    }
}
```

### Creating Custom Actions

```swift
import ARORuntime

public struct MyCustomAction: ActionImplementation {
    public static let role: ActionRole = .own
    public static let verbs: Set<String> = ["MyVerb"]
    public static let validPrepositions: Set<Preposition> = [.with]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        let input: String = try context.require(object.identifier)
        let output = transform(input)
        context.bind(result.identifier, value: output)
        return output
    }
}

ActionRegistry.shared.register(MyCustomAction.self)
```

See the [Action Developer Guide](https://github.com/arolang/aro/wiki/Action-Developer-Guide).

### Plugins

Plugins live under `MyApp/Plugins/<plugin-name>/` with a `plugin.yaml` manifest
and source files. Four host languages are supported:

| Language | Registration Pattern |
|----------|---------------------|
| Swift | `@AROExport` macro on `let plugin = AROPlugin(...)` — SDK generates C ABI exports |
| Rust | `#[no_mangle] extern "C"` functions (`aro_plugin_info`, `aro_plugin_execute`, ...) |
| C/C++ | `ARO_PLUGIN()` + `ARO_ACTION()` / `ARO_QUALIFIER()` macros from `aro_plugin_sdk.h` |
| Python | `@plugin` + `@action` / `@qualifier` decorators + `export_abi(globals())` |

Plugins can register both actions and **qualifiers** that transform values:

```aro
Compute the <random-item: collections.pick-random> from the <items>.
Compute the <sorted-list: stats.sort> from the <numbers>.
```

The plugin namespace handle (`collections`, `stats`) is declared at the root of
`plugin.yaml`. Plugins work in both interpreter and compiled-binary modes; `aro
build` compiles and bundles them with the binary.

## Architecture

### Compilation & Execution Pipeline

```
Source files (*.aro in app directory and subdirectories)
    │
    ▼
┌───────────────────┐
│ ApplicationLoader │ ──► discovers all .aro files, validates Application-Start
└────────┬──────────┘
         │
         ▼
┌─────────┐
│  Lexer  │ ──► Tokens
└────┬────┘
     │
     ▼
┌─────────┐
│ Parser  │ ──► AST (FeatureSet[] of AROStatement / PublishStatement)
└────┬────┘
     │
     ▼
┌──────────────────┐
│ Semantic Analyzer│ ──► AnalyzedProgram (symbol tables, data flow)
└────────┬─────────┘
         │
         ├──► Interpreter:  ExecutionEngine ──► FeatureSetExecutor
         │                       │
         │                       ├──► ActionRegistry  ──► ActionImplementations
         │                       ├──► EventBus        ──► matching FeatureSets
         │                       ├──► QualifierRegistry
         │                       └──► Services (HTTP, Files, Sockets, Git, ...)
         │
         └──► Native: AROCompiler/LLVMCodeGenerator → LLVM IR → Linker → binary
                                                             (links libAROCRuntime, libgit2, plugins)
```

### Key Components

**Parser:**
1. **Lexer** — tokenizes source, recognising articles (`a`/`an`/`the`), prepositions, and compound identifiers
2. **Parser** — recursive descent, producing AST nodes
3. **AST** — Sendable value types with the visitor pattern (ARO-0061, ARO-0063)
4. **SymbolTable** — immutable, Sendable, per feature set; `GlobalSymbolRegistry` for published cross-feature-set symbols
5. **SemanticAnalyzer** — variable scoping, data flow, dead-code detection
6. **Compiler** — orchestrates the pipeline; entry point `Compiler.compile(source)`

**Runtime:**
1. **ExecutionEngine** — orchestrates program execution
2. **FeatureSetExecutor** — executes individual feature sets
3. **ActionRegistry** — maps verbs to action implementations
4. **AROFuture / ActionTaskExecutor** — lazy action handles; values force at consumer reads
5. **EventBus** — synchronous subscribe, payload force at first handler read
6. **Services** — HTTP, FileSystem, Sockets, WebSocket, Git, Templates, Metrics, ...

### Asynchronous Execution Model

As of the post-0.9.4 series, action execution is lazy by default. Each statement
returns an `AROFuture` handle bound to the result symbol; the value is forced
when a downstream consumer (a value accessor, a branch condition, an `Emit`
handler, or an explicit force point) needs it. This enables implicit pipeline
parallelism without changing the surface syntax. The previous eager path and
the standalone `StatementScheduler` have been removed; slot ownership is
managed via `TaskLocal` rather than thread dictionaries, with slow-force
diagnostics for debugging.

## Variable Scoping

Each feature set has its own symbol table. Actions are classified by data flow
direction:

- **REQUEST** (`Extract`, `Parse`, `Retrieve`, `Fetch`, `Pull`, `Clone`): External → Internal
- **OWN** (`Compute`, `Validate`, `Compare`, `Create`, `Transform`, `Stage`, `Checkout`): Internal → Internal
- **RESPONSE** (`Return`, `Throw`): Internal → External
- **EXPORT** (`Publish`, `Store`, `Log`, `Send`, `Emit`, `Commit`, `Push`, `Tag`): Makes symbols globally accessible or exports data

## Implementation Status

### Completed

- Lexer, recursive-descent parser, AST, symbol tables, semantic analysis
- Lazy `AROFuture` runtime with auto-forcing value accessors
- Action registry and 50+ built-in actions
- EventBus with state guards (ARO-0022) and typed event extraction (ARO-0046)
- HTTP server (SwiftNIO) and client (AsyncHTTPClient), plus SSE
- WebSocket server (ARO-0048)
- File system operations and FileMonitor (ARO-0029, ARO-0036, ARO-0040)
- TCP socket server / client, including binary socket events (ARO-0072)
- Native Git via libgit2 (ARO-0080)
- Store files / file-backed repositories (ARO-0073)
- Plugin system: Swift, Rust, C/C++, Python; actions + qualifiers
- Package manager: `aro add` / `aro remove` (ARO-0045)
- Streaming execution: lazy evaluation, Stream Tee, aggregation fusion (ARO-0051)
- Template engine, metrics export, structured logging, terminal UI
- Testing framework (`Given` / `When` / `Then`)
- Native compilation (`aro build`) with bundled plugins
- LSP server (ARO-0034)
- CLI: `run`, `build`, `compile`, `check`, `test`, `add`, `remove`

### In Progress / Proposed

- ARO-0081: User-defined actions (define new actions in ARO itself)
- Type narrowing (ARO-0071)
- Continued LLVM expression optimization (ARO-0070)

## Design Principles

1. **Protocol-Oriented**: Extensible via protocols at every layer
2. **Immutable Data**: Symbol tables and AST nodes are Sendable value types
3. **Swift 6.2 Concurrency**: All core types are `Sendable`
4. **Visitor Pattern**: AST traversal is decoupled from node types
5. **Error Recovery**: The parser continues after errors and reports diagnostics
6. **Event-Driven**: Loose coupling via the event bus
7. **Contract-First**: HTTP routes are derived from the OpenAPI spec
8. **Extensible Actions**: Plugins in four languages, packaged with `plugin.yaml`
9. **Lazy by Default**: Actions are scheduled, not executed eagerly

## License

MIT License

## Contributing

1. Read the relevant proposal in `Proposals/`.
2. File issues for bugs or feature requests.
3. PRs welcome.

---

*ARO — Making business features executable*
