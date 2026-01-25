# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Source of Truth

The project must always be in sync. When there are conflicts or discrepancies, the priority order for truth is:

1. **Proposals** (`Proposals/`) - The authoritative specification
2. **Code** (`Sources/`) - The implementation
3. **Documentation** ([Wiki](https://github.com/arolang/aro/wiki), `OVERVIEW.md`, `README.md`) - Developer docs
4. **Website** (`Website/`) - Public website
5. **Book** (`Book/`) - The Language Guide

When updating any layer, ensure all lower-priority layers are updated to match.

## Platform Feature Table

The **Platform Support** table in `README.md` lists feature availability for macOS, Linux, and Windows. When adding or modifying platform-specific features, always update this table to reflect current support status.

## Documentation Style

- **Proposals** (`Proposals/`): Use ASCII art for diagrams
- **Book** (`Book/`): Use SVG for diagrams

## Build Commands

```bash
swift build              # Build the project
swift test               # Run all tests
aro run ./Examples/UserService      # Run multi-file application
aro run ./Examples/HTTPServer       # Run server (uses Keepalive action)
aro compile ./MyApp   # Compile all .aro files in directory
aro check ./MyApp     # Syntax check all .aro files
aro build ./MyApp     # Compile to native binary (LLVM IR + object file)
aro build ./MyApp --verbose --optimize  # Verbose build with optimizations
```

## Architecture

This is a Swift 6.2 parser/compiler/runtime for ARO (Action Result Object), a DSL for expressing business features as Action-Result-Object statements.

### Application Structure

An ARO application is a **directory** containing `.aro` files:

```
MyApp/
├── openapi.yaml       # OpenAPI contract (required for HTTP server)
├── main.aro           # Contains Application-Start (required, exactly one)
├── users.aro          # Feature sets for user operations
├── orders.aro         # Feature sets for order operations
└── events.aro         # Event handler feature sets
```

**Key Rules:**
- All `.aro` files in the directory are automatically discovered and parsed
- No imports needed - all feature sets are globally visible within the application
- Exactly ONE `Application-Start` feature set per application (error if 0 or multiple)
- At most ONE `Application-End: Success` and ONE `Application-End: Error` (both optional)
- Feature sets are triggered by **events**, not direct calls
- **Contract-First HTTP**: `openapi.yaml` is required for HTTP server (no contract = no server)

### Compilation Pipeline

```
Directory → Find all .aro files → Compile each → Validate single Application-Start → Register with EventBus
```

- **Lexer** (`Lexer.swift`): Tokenizes source, recognizing articles (a/an/the), prepositions, and compound identifiers
- **Parser** (`Parser.swift`): Recursive descent parser producing AST
- **SemanticAnalyzer** (`SemanticAnalyzer.swift`): Builds symbol tables and performs data flow analysis
- **Compiler** (`Compiler.swift`): Orchestrates the pipeline, entry point is `Compiler.compile(source)`

### Runtime Execution

```
Application-Start executes → Services start → Event loop waits → Events trigger feature sets
```

- **ApplicationLoader**: Discovers and compiles all `.aro` files in directory
- **ExecutionEngine** (`Core/ExecutionEngine.swift`): Orchestrates program execution
- **EventBus** (`Events/EventBus.swift`): Routes events to matching feature sets
- **FeatureSetExecutor** (`Core/FeatureSetExecutor.swift`): Executes feature sets when triggered
- **ActionRegistry** (`Actions/ActionRegistry.swift`): Maps verbs to implementations

### Event-Driven Feature Sets

Feature sets are triggered by events based on their **business activity**:

| Business Activity Pattern | Triggered By |
|---------------------------|--------------|
| `operationId` (e.g., `listUsers`) | HTTP route match via OpenAPI contract |
| `{EventName} Handler` | Custom domain events |
| `{repository-name} Observer` | Repository changes (store/update/delete) |
| `File Event Handler` | File system events |
| `Socket Event Handler` | Socket events |

### Contract-First HTTP APIs

ARO uses **contract-first** API development. HTTP routes are defined in `openapi.yaml`, and feature sets are named after `operationId` values.

**Without openapi.yaml**: HTTP server does NOT start, no port is opened.
**With openapi.yaml**: HTTP server is enabled and routes are handled.

Example:
```yaml
# openapi.yaml
openapi: 3.0.3
info:
  title: User API
  version: 1.0.0
paths:
  /users:
    get:
      operationId: listUsers    # Feature set name
    post:
      operationId: createUser
  /users/{id}:
    get:
      operationId: getUser
```

```aro
(* Feature set names match operationIds from openapi.yaml *)

(listUsers: User API) {
    <Retrieve> the <users> from the <user-repository>.
    <Return> an <OK: status> with <users>.
}

(createUser: User API) {
    <Extract> the <data> from the <request: body>.
    <Create> the <user> with <data>.
    <Emit> a <UserCreated: event> with <user>.
    <Return> a <Created: status> with <user>.
}

(getUser: User API) {
    <Extract> the <id> from the <pathParameters: id>.
    <Retrieve> the <user> from the <user-repository> where id = <id>.
    <Return> an <OK: status> with <user>.
}

(* Event handlers still work as before *)
(Send Welcome Email: UserCreated Handler) {
    <Extract> the <user> from the <event: user>.
    <Send> the <welcome-email> to the <user: email>.
    <Return> an <OK: status> for the <notification>.
}
```

**Path Parameters**: Extracted from URL and available via `pathParameters`:
- `<Extract> the <id> from the <pathParameters: id>.`

**Request Body**: Typed according to OpenAPI schema:
- `<Extract> the <data> from the <request: body>.`

### Happy Case
Code contains only the happy case. Errors are handled by the runtime. For example when a user cannot be retrieved from the repository, the server just returns: `Can not retrieve the user from the user-repository where id = 530`.

Do not use it for production code, it is terribly insecure.

### Key Types

**Parser:**
- `Program` → `FeatureSet[]` → `Statement[]` (either `AROStatement` or `PublishStatement`)
- `AROStatement`: `<Action> the <Result> preposition the <Object>`
- `SymbolTable`: Immutable, `Sendable` symbol storage per feature set
- `GlobalSymbolRegistry`: Cross-feature-set symbol access for published variables

**Runtime:**
- `ActionImplementation`: Protocol for action implementations
- `ResultDescriptor` / `ObjectDescriptor`: Statement metadata for actions
- `ExecutionContext`: Runtime context protocol
- `RuntimeEvent`: Protocol for events

### Action Semantic Roles

Actions are classified by data flow direction:
- **REQUEST** (Extract, Parse, Retrieve, Fetch): External → Internal
- **OWN** (Compute, Validate, Compare, Create, Transform): Internal → Internal
- **RESPONSE** (Return, Throw): Internal → External
- **EXPORT** (Publish, Store, Log, Send, Emit): Makes symbols globally accessible or exports data

## Services

Built-in services available at runtime:
- **AROHTTPServer**: SwiftNIO-based HTTP server
- **AROHTTPClient**: AsyncHTTPClient-based HTTP client
- **AROFileSystemService**: File I/O with FileMonitor watching
- **AROSocketServer** / **AROSocketClient**: TCP communication

## ARO Syntax

```aro
(Feature Name: Business Activity) {
    <Extract> the <result: qualifier> from the <source: qualifier>.
    <Compute> the <output> for the <input>.
    <Return> an <OK: status> for a <valid: result>.
    <Publish> as <alias> <variable>.
}
```

Application lifecycle handlers:
```aro
(* Entry point - exactly one per application *)
(Application-Start: My App) {
    <Log> "Starting..." to the <console>.
    <Start> the <http-server> with <contract>.
    <Return> an <OK: status> for the <startup>.
}

(* Exit handler for graceful shutdown - optional, at most one *)
(Application-End: Success) {
    <Log> "Shutting down..." to the <console>.
    <Stop> the <http-server> with <application>.
    <Return> an <OK: status> for the <shutdown>.
}

(* Exit handler for errors/crashes - optional, at most one *)
(Application-End: Error) {
    <Extract> the <error> from the <shutdown: error>.
    <Log> <error> to the <console>.
    <Return> an <OK: status> for the <error-handling>.
}
```

### Computations

The Compute action transforms data using built-in operations:

| Operation | Description | Example |
|-----------|-------------|---------|
| `length` / `count` | Count elements | `<Compute> the <len: length> from <text>.` |
| `uppercase` | Convert to UPPERCASE | `<Compute> the <upper: uppercase> from <text>.` |
| `lowercase` | Convert to lowercase | `<Compute> the <lower: lowercase> from <text>.` |
| `hash` | Compute hash value | `<Compute> the <hash: hash> from <password>.` |
| Arithmetic | +, -, *, /, % | `<Compute> the <total> from <price> * <qty>.` |

**Qualifier-as-Name Syntax**: When you need multiple results of the same operation, use the qualifier to specify the operation while the base becomes the variable name:

```aro
(* Old syntax: 'length' is both the variable name AND the operation *)
<Compute> the <length> from the <message>.

(* New syntax: variable name and operation are separate *)
<Compute> the <first-length: length> from the <first-message>.
<Compute> the <second-length: length> from the <second-message>.

(* Now both values are available *)
<Compare> the <first-length> against the <second-length>.
```

See `Proposals/ARO-0001-language-fundamentals.md` for the full specification.

### Long-Running Applications

For applications that need to stay alive and process events (servers, file watchers, etc.), use the `<Keepalive>` action:

```aro
(Application-Start: File Watcher) {
    <Log> "Starting..." to the <console>.
    <Start> the <file-monitor> with ".".

    (* Keep the application running to process events *)
    <Keepalive> the <application> for the <events>.

    <Return> an <OK: status> for the <startup>.
}
```

The `<Keepalive>` action:
- Blocks execution until a shutdown signal is received (SIGINT/SIGTERM)
- Allows the event loop to process incoming events
- Enables graceful shutdown with Ctrl+C

## Creating Custom Actions

```swift
public struct MyAction: ActionImplementation {
    public static let role: ActionRole = .own
    public static let verbs: Set<String> = ["MyVerb"]
    public static let validPrepositions: Set<Preposition> = [.with, .from]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        // Get input from context
        let input: String = try context.require(object.identifier)

        // Process and bind result
        let output = process(input)
        context.bind(result.identifier, value: output)

        // Emit event
        context.emit(MyEvent(value: output))

        return output
    }
}

// Register
ActionRegistry.shared.register(MyAction.self)
```

See the [Action Developer Guide](https://github.com/arolang/aro/wiki/Action-Developer-Guide) for full guide.

## Project Structure

```
Sources/
├── AROParser/          # Core parser library
├── ARORuntime/         # Runtime execution (interpreter)
│   ├── Actions/        # Action protocol, registry, built-ins
│   ├── Core/           # ExecutionEngine, Context
│   ├── Events/         # EventBus, event types
│   ├── HTTP/           # Server (SwiftNIO), Client (AsyncHTTPClient)
│   ├── FileSystem/     # File operations, FileMonitor
│   ├── Sockets/        # TCP server/client
│   ├── OpenAPI/        # Contract-first routing (OpenAPISpec, RouteRegistry)
│   └── Application/    # App lifecycle, ApplicationLoader
├── AROCompiler/        # Native compilation (LLVM code generation)
│   ├── LLVMCodeGenerator.swift  # AST to LLVM IR transformation
│   └── Linker.swift    # Compilation and linking
├── AROCRuntime/        # C-callable Swift runtime bridge
│   ├── RuntimeBridge.swift   # Core runtime C interface
│   ├── ActionBridge.swift    # All 48 actions via @_cdecl
│   └── ServiceBridge.swift   # HTTP/File/Socket C interface
└── AROCLI/             # CLI (run, compile, check, build commands)

Examples/
├── HelloWorld/         # Single-file example
├── Computations/       # Compute operations and qualifier-as-name syntax
├── HTTPServer/         # HTTP server example
├── FileWatcher/        # File monitoring example
├── EchoSocket/         # Socket example
├── UserService/        # Multi-file application example
│   ├── openapi.yaml    # OpenAPI contract (defines HTTP routes)
│   ├── main.aro        # Application-Start
│   ├── users.aro       # Feature sets (named after operationIds)
│   └── events.aro      # Event handlers
└── RepositoryObserver/ # Repository observers example
    ├── openapi.yaml    # API contract
    ├── main.aro        # Application-Start
    ├── api.aro         # CRUD operations
    └── observers.aro   # Repository change observers

Proposals/              # 27 language specifications
├── ARO-0001-language-fundamentals.md
├── ARO-0002-control-flow.md
├── ARO-0003-type-system.md
├── ARO-0004-actions.md
├── ARO-0005-application-architecture.md
├── ARO-0006-error-philosophy.md
├── ARO-0007-events-reactive.md
├── ARO-0008-io-services.md
├── ARO-0009-native-compilation.md
├── ARO-0010-advanced-features.md
├── ARO-0014-domain-modeling.md
├── ARO-0015-testing-framework.md
├── ARO-0016-interoperability.md
├── ARO-0018-query-language.md
├── ARO-0019-standard-library.md
├── ARO-0022-state-guards.md
├── ARO-0030-ide-integration.md
├── ARO-0031-context-aware-formatting.md
├── ARO-0034-language-server-protocol.md
├── ARO-0035-configurable-runtime.md
├── ARO-0036-file-operations.md
├── ARO-0037-regex-split.md
├── ARO-0038-list-element-access.md
├── ARO-0040-format-aware-io.md
├── ARO-0041-datetime-ranges.md
├── ARO-0042-set-operations.md
└── ARO-0043-sink-syntax.md
```

## Language Proposals

The `Proposals/` directory contains 27 specifications:

| Proposal | Topics |
|----------|--------|
| **0001 Language Fundamentals** | Core syntax, literals, expressions, scoping |
| **0002 Control Flow** | When guards, match expressions, iteration |
| **0003 Type System** | Types, OpenAPI integration, schemas |
| **0004 Actions** | Action roles, built-in actions, extensions |
| **0005 Application Architecture** | App structure, lifecycle, concurrency |
| **0006 Error Philosophy** | "Code is the error message" |
| **0007 Events & Reactive** | Events, state, repositories |
| **0008 I/O Services** | HTTP, files, sockets, system objects |
| **0009 Native Compilation** | LLVM, aro build |
| **0010 Advanced Features** | Regex, dates, exec |
| **0014 Domain Modeling** | DDD patterns, entities, aggregates |
| **0015 Testing Framework** | Colocated tests, Given/When/Then |
| **0016 Interoperability** | External services, Call action |
| **0018 Data Pipelines** | Filter, transform, aggregate collections |
| **0019 Standard Library** | Primitive types, utilities |
| **0022 State Guards** | Event handler filtering with field:value syntax |
| **0030 IDE Integration** | Syntax highlighting, snippets |
| **0031 Context-Aware Formatting** | Adaptive output for machine/human/developer |
| **0034 Language Server Protocol** | LSP server, diagnostics, navigation |
| **0035 Configurable Runtime** | Configure action for timeouts and settings |
| **0036 Extended File Operations** | Exists, Stat, Make, Copy, Move actions |
| **0037 Regex Split** | Split action with regex delimiters |
| **0038 List Element Access** | first, last, index, range specifiers |
| **0040 Format-Aware I/O** | Auto format detection for JSON, YAML, CSV |
| **0041 Date/Time Ranges** | Date arithmetic, ranges, recurrence patterns |
| **0042 Set Operations** | intersect, difference, union on collections |
| **0043 Sink Syntax** | Expressions in result position |

## Concurrency

All core types (`SymbolTable`, `Token`, AST nodes, `ActionImplementation`) are `Sendable` for Swift 6.2 concurrency safety.

## Git Commits

When creating git commits, do NOT include the Claude Code signature or co-author attribution in commit messages.