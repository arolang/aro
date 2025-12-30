# The ARO Programming Language

| **Website:** https://krissimon.github.io/aro/<br />Reference implementation of a parser, compiler, and runtime for the **ARO** programming language. | ![ARO Logo](./Graphics/logo-small.png) |
|---------------------------------------------------------------------------------------------------------|----------------------------------------|

## Overview

ARO is a declarative language for specifying business features in a human-readable format
that can be compiled and executed. Features are expressed as Action-Result-Object statements.

### Key Features

- **Event-Driven Execution**: Feature sets are triggered by events, not direct calls
- **Application Lifecycle**: `Application-Start` (required), `Application-End: Success/Error` (optional)
- **Contract-First APIs**: HTTP routes defined in `openapi.yaml`, handlers named after `operationId`
- **HTTP Server**: Built-in web server using SwiftNIO
- **HTTP Client**: Outgoing HTTP requests via AsyncHTTPClient
- **File System**: File I/O and directory watching via FileMonitor
- **Socket Communication**: TCP server and client support
- **Testing Framework**: BDD-style tests with Given/When/Then actions
- **Native Compilation**: Compile to native binaries with `aro build`
- **Extensible Actions**: Plugin architecture for custom actions

### Example

```aro
(* Entry point - exactly one per application *)
(Application-Start: My Service) {
    <Log> the <startup: message> for the <console> with "Starting service...".
    <Start> the <http-server> on <port> with 8080.
    <Keepalive> the <application> for the <events>.
    <Return> an <OK: status> for the <startup>.
}

(* Exit handler - called on graceful shutdown *)
(Application-End: Success) {
    <Log> the <shutdown: message> for the <console> with "Goodbye!".
    <Return> an <OK: status> for the <shutdown>.
}

(* HTTP route handler - matches operationId from openapi.yaml *)
(listUsers: User API) {
    <Retrieve> the <users> from the <user-repository>.
    <Return> an <OK: status> with <users>.
}

(* Event handler - triggered by UserCreated event *)
(Send Welcome Email: UserCreated Handler) {
    <Extract> the <user> from the <event: user>.
    <Send> the <welcome-email> to the <user: email>.
    <Return> an <OK: status> for the <notification>.
}

(* Test feature set - run with: aro test *)
(add-numbers-test: Calculator Test) {
    <Given> the <a> with 5.
    <Given> the <b> with 3.
    <When> the <sum> from the <add-numbers>.
    <Then> the <sum> with 8.
}
```

## Project Structure

```
ARO-Lang/
├── Package.swift           # Swift package manifest
├── README.md               # This file
├── Sources/
│   ├── AROParser/          # Core parser library
│   │   ├── SourceLocation.swift    # Position tracking
│   │   ├── Token.swift             # Lexical tokens
│   │   ├── AST.swift               # Abstract syntax tree
│   │   ├── Errors.swift            # Error types
│   │   ├── Lexer.swift             # Tokenizer
│   │   ├── Parser.swift            # Recursive descent parser
│   │   ├── SymbolTable.swift       # Symbol management
│   │   ├── SemanticAnalyzer.swift  # Semantic analysis
│   │   └── Compiler.swift          # Main compilation pipeline
│   ├── ARORuntime/         # Runtime execution engine
│   │   ├── Actions/                # Action system
│   │   ├── Core/                   # Execution engine
│   │   ├── Events/                 # Event bus
│   │   ├── HTTP/                   # HTTP server & client
│   │   ├── FileSystem/             # File operations
│   │   ├── Sockets/                # TCP communication
│   │   ├── OpenAPI/                # Contract-first routing
│   │   ├── Testing/                # Test framework
│   │   └── Application/            # App lifecycle
│   ├── AROCompiler/        # Native compilation (LLVM code generation)
│   ├── AROCRuntime/        # C-callable Swift runtime bridge
│   └── AROCLI/             # Command-line interface
│       └── Commands/               # run, build, compile, check, test
├── Examples/               # Example applications
│   ├── HelloWorld/         # Single-file example
│   ├── HTTPServer/         # HTTP server example
│   ├── FileWatcher/        # File monitoring example
│   ├── EchoSocket/         # Socket example
│   ├── Calculator/         # Test framework example
│   ├── UserService/        # Multi-file application with OpenAPI
│   │   ├── openapi.yaml    # API contract
│   │   ├── main.aro        # Application-Start entry point
│   │   ├── users.aro       # HTTP route handlers
│   │   └── events.aro      # Event handlers
│   ├── ModulesExample/     # Application composition with imports
│   │   ├── ModuleA/        # Standalone module with /module-a route
│   │   ├── ModuleB/        # Standalone module with /module-b route
│   │   └── Combined/       # Imports both modules
│   └── ...                 # Additional examples
├── Documentation/          # Developer guides
│   └── ActionDeveloperGuide.md
├── Tests/
│   └── AROParserTests/     # Unit tests
└── Proposals/              # 28 Language Evolution Proposals
    ├── ARO-0001 through 0019  # Core language
    ├── ARO-0020 through 0025  # Runtime architecture
    ├── ARO-0026              # Native compilation
    ├── ARO-0027              # OpenAPI contract-first
    ├── ARO-0028              # Long-running applications
    └── ARO-0029              # Native file monitoring
```

## Language Specification

The complete language is specified in 28 Evolution Proposals:

### Core Language (0001-0019)

| # | Proposal | Description |
|---|----------|-------------|
| 0001 | Core Syntax | Basic grammar, ARO statements, feature sets |
| 0002 | Literals & Expressions | Numbers, strings, operators |
| 0003 | Variable Scoping | Visibility, lifetime, publish mechanism |
| 0004 | Conditional Branching | if/then/else, when, match |
| 0005 | Iteration & Loops | for-each, while, repeat-until |
| 0006 | Type System | Types, generics, protocols |
| 0007 | Modules & Imports | Module system, packages |
| 0008 | Error Handling | Code is the error message |
| 0009 | Action Implementations | Action protocol, code generation |
| 0011 | Concurrency | Async runtime with sync semantics |
| 0012 | Events & Reactive | Event sourcing, direct dispatch |
| 0013 | State Machines | State objects with Accept action |
| 0014 | Domain Modeling | DDD constructs |
| 0015 | Testing Framework | BDD with Given/When/Then |
| 0016 | Interoperability | Swift, REST, databases |
| 0018 | Query Language | SQL-like queries |
| 0019 | Standard Library | Core utilities |

### Runtime Architecture (0020-0029)

| # | Proposal | Description |
|---|----------|-------------|
| 0020 | Runtime Architecture | Execution engine, contexts, services |
| 0021 | HTTP Server | SwiftNIO web server, routing |
| 0022 | HTTP Client | AsyncHTTPClient, API consumption |
| 0023 | File System | File I/O, FileMonitor integration |
| 0024 | Sockets | TCP server/client, bidirectional |
| 0025 | Action Extension | Custom action development |
| 0026 | Native Compilation | Compile to native binaries |
| 0027 | OpenAPI Contract-First | API routes from openapi.yaml |
| 0028 | Long-Running Applications | Keepalive action |
| 0029 | Native File Monitoring | Platform-specific file watching |

See [Proposals/README.md](Proposals/README.md) for details.

## Building

```bash
# Build
swift build

# Run tests
swift test

# Run an example application
aro run ./Examples/HelloWorld
```

## Usage

### CLI Commands

```bash
# Run an ARO application
aro run ./Examples/HTTPServer

# Compile to native binary
aro build ./Examples/HelloWorld

# Run tests
aro test ./Examples/Calculator

# Compile and check for errors
aro compile ./MyApp

# Quick syntax check
aro check ./MyApp
```

### Contract-First HTTP APIs

ARO uses **contract-first** API development. HTTP routes are defined in `openapi.yaml`,
and feature sets are named after `operationId` values:

```yaml
# openapi.yaml
paths:
  /users:
    get:
      operationId: listUsers    # Feature set name
    post:
      operationId: createUser
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
```

### Testing

Tests are feature sets with "Test" suffix in business activity:

```aro
(add-positive-numbers: Calculator Test) {
    <Given> the <a> with 5.
    <Given> the <b> with 3.
    <When> the <sum> from the <add-numbers>.
    <Then> the <sum> with 8.
}
```

Run tests with: `aro test ./Examples/Calculator`

### As a Library

```swift
import AROParser
import ARORuntime

// Compile source code
let source = """
(Application-Start: My App) {
    <Log> the <startup: message> for the <console> with "Hello, ARO!".
    <Return> an <OK: status> for the <startup>.
}
"""

let result = Compiler.compile(source)

if result.isSuccess {
    // Execute the compiled program
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
        // Implementation
        return "result"
    }
}

// Register the action
ActionRegistry.shared.register(MyCustomAction.self)
```

See [Documentation/ActionDeveloperGuide.md](Documentation/ActionDeveloperGuide.md) for full details.

## Architecture

### Compilation & Execution Pipeline

```
Source Code (.aro files)
    │
    ▼
┌─────────┐
│  Lexer  │ ──► Tokens
└────┬────┘
     │
     ▼
┌─────────┐
│ Parser  │ ──► AST
└────┬────┘
     │
     ▼
┌──────────────────┐
│ Semantic Analyzer│ ──► AnalyzedProgram
└────────┬─────────┘
         │
         ▼
┌──────────────────┐
│ Execution Engine │ ──► Runtime Execution
└────────┬─────────┘
         │
         ├──► ActionRegistry ──► Action Implementations
         ├──► EventBus ──► Event Handlers
         └──► Services (HTTP, Files, Sockets)
```

### Key Components

**Parser Components:**
1. **Lexer**: Tokenizes source into keywords, identifiers, delimiters
2. **Parser**: Recursive descent parser producing AST
3. **AST**: Protocol-oriented node types with Visitor pattern
4. **Symbol Table**: Immutable, Sendable symbol storage
5. **Semantic Analyzer**: Variable scoping, data flow analysis
6. **Compiler**: Orchestrates the compilation pipeline

**Runtime Components:**
1. **ExecutionEngine**: Orchestrates program execution
2. **FeatureSetExecutor**: Executes individual feature sets
3. **ActionRegistry**: Maps verbs to action implementations
4. **RuntimeContext**: Variable binding and service access
5. **EventBus**: Publish/subscribe event system
6. **Services**: HTTP, FileSystem, Sockets

## Variable Scoping

Each Feature Set has its own symbol table:

- **REQUEST Actions** (Extract, Parse, Retrieve): External → Internal
- **OWN Actions** (Compute, Validate, Compare, Create): Internal → Internal
- **RESPONSE Actions** (Return, Throw): Internal → External
- **EXPORT Actions** (Publish): Makes internal variables accessible globally

## Implementation Status

### Completed
- Lexer with full token support
- Recursive descent parser with expression support
- AST with visitor pattern
- Symbol table management
- Basic semantic analysis
- Error recovery and diagnostics
- Runtime execution engine
- Action registry and built-in actions
- Event bus system
- HTTP server (SwiftNIO)
- HTTP client (AsyncHTTPClient)
- File system operations (FileMonitor)
- Socket server/client
- Testing framework (Given/When/Then/Assert)
- Native compilation (`aro build`)
- CLI tool (`aro run/build/compile/check/test`)
- Example applications

### In Progress
- Type checking
- Advanced conditional branching

### Planned
- LSP server
- IDE integration
- Additional built-in actions

## Design Principles

1. **Protocol-Oriented**: Extensible via protocols
2. **Immutable Data**: SymbolTable and AST nodes are value types
3. **Swift 6.2 Concurrency**: All core types are `Sendable`
4. **Visitor Pattern**: Extensible tree traversal
5. **Error Recovery**: Continue parsing after errors
6. **Event-Driven**: Loose coupling via event bus
7. **Contract-First**: API routes from OpenAPI spec
8. **Extensible Actions**: Plugin architecture for custom verbs

## License

MIT License

## Contributing

1. Read the relevant proposals in `Proposals/`
2. Submit issues for bugs or feature requests
3. PRs welcome!

---

*ARO - Making business features executable*
