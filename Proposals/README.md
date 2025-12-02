# ARO Language Evolution Proposals

This directory contains the complete language specification for ARO (Action Result Object), organized as evolution proposals.

## Proposal Index

### Foundation

| Proposal | Title | Status | Description |
|----------|-------|--------|-------------|
| [0001](ARO-0001-core-syntax.md) | Core Language Syntax | Accepted | Basic grammar, ARO statements, feature sets |
| [0002](ARO-0002-literals-expressions.md) | Literals and Expressions | Draft | Numbers, strings, operators, expressions |
| [0003](ARO-0003-variable-scoping.md) | Variable Scoping | Draft | Visibility, lifetime, publish mechanism |

### Control Flow

| Proposal | Title | Status | Description |
|----------|-------|--------|-------------|
| [0004](ARO-0004-conditional-branching.md) | Conditional Branching | Draft | if/then/else, when guards, match |
| [0005](ARO-0005-iteration-loops.md) | Iteration and Loops | Draft | for-each, while, repeat-until |

### Type System

| Proposal | Title | Status | Description |
|----------|-------|--------|-------------|
| [0006](ARO-0006-type-system.md) | Type System | Draft | Types, generics, protocols |

### Modularity

| Proposal | Title | Status | Description |
|----------|-------|--------|-------------|
| [0007](ARO-0007-modules-imports.md) | Modules and Imports | Draft | Module system, visibility, packages |

### Error Handling

| Proposal | Title | Status | Description |
|----------|-------|--------|-------------|
| [0008](ARO-0008-error-handling.md) | Error Handling | Draft | try/catch, Result type, guards |

### Execution

| Proposal | Title | Status | Description |
|----------|-------|--------|-------------|
| [0009](ARO-0009-action-implementations.md) | Action Implementations | Draft | Action protocol, registry, code generation |

### Metadata

| Proposal | Title | Status | Description |
|----------|-------|--------|-------------|
| [0010](ARO-0010-annotations-metadata.md) | Annotations and Metadata | Draft | @annotations, documentation, validation |

### Concurrency

| Proposal | Title | Status | Description |
|----------|-------|--------|-------------|
| [0011](ARO-0011-concurrency-async.md) | Concurrency and Async | Draft | async/await, actors, channels |

### Reactive

| Proposal | Title | Status | Description |
|----------|-------|--------|-------------|
| [0012](ARO-0012-events-reactive.md) | Events and Reactive | Draft | Events, event sourcing, sagas |

### State Management

| Proposal | Title | Status | Description |
|----------|-------|--------|-------------|
| [0013](ARO-0013-state-machines.md) | State Machines | Draft | States, transitions, guards |

### Domain Modeling

| Proposal | Title | Status | Description |
|----------|-------|--------|-------------|
| [0014](ARO-0014-domain-modeling.md) | Domain Modeling | Draft | DDD: entities, value objects, aggregates |

### Testing

| Proposal | Title | Status | Description |
|----------|-------|--------|-------------|
| [0015](ARO-0015-testing-framework.md) | Testing Framework | Draft | BDD tests, mocking, fixtures |

### Integration

| Proposal | Title | Status | Description |
|----------|-------|--------|-------------|
| [0016](ARO-0016-interoperability.md) | Interoperability | Draft | Swift, REST, databases, FFI |

### Metaprogramming

| Proposal | Title | Status | Description |
|----------|-------|--------|-------------|
| [0017](ARO-0017-macros-metaprogramming.md) | Macros and Metaprogramming | Draft | Macros, code generation, DSLs |

### Data

| Proposal | Title | Status | Description |
|----------|-------|--------|-------------|
| [0018](ARO-0018-query-language.md) | Query Language | Draft | SQL-like queries, aggregations |

### Standard Library

| Proposal | Title | Status | Description |
|----------|-------|--------|-------------|
| [0019](ARO-0019-standard-library.md) | Standard Library | Draft | Core types, collections, utilities |

---

### Runtime Architecture

| Proposal | Title | Status | Description |
|----------|-------|--------|-------------|
| [0020](ARO-0020-runtime-architecture.md) | Runtime Architecture | Draft | Execution engine, contexts, services |
| [0021](ARO-0021-http-server.md) | HTTP Server | Draft | SwiftNIO web server, routing |
| [0022](ARO-0022-http-client.md) | HTTP Client | Draft | AsyncHTTPClient, API consumption |
| [0023](ARO-0023-file-system.md) | File System | Draft | File I/O, FileMonitor integration |
| [0024](ARO-0024-sockets.md) | Socket Communication | Draft | TCP server/client, bidirectional |
| [0025](ARO-0025-action-extension-interface.md) | Action Extension Interface | Draft | Custom action development |

---

## Dependency Graph

```
0001 Core Syntax
 ├── 0002 Literals/Expressions
 │    └── 0018 Query Language
 ├── 0003 Variable Scoping
 │    ├── 0004 Conditionals
 │    │    ├── 0005 Loops
 │    │    └── 0008 Error Handling
 │    └── 0007 Modules
 ├── 0006 Type System
 │    ├── 0012 Events
 │    ├── 0014 Domain Modeling
 │    └── 0016 Interoperability
 ├── 0009 Action Implementations
 │    └── 0025 Action Extension Interface
 ├── 0010 Annotations
 │    └── 0015 Testing
 ├── 0011 Concurrency
 │    └── 0012 Events
 ├── 0013 State Machines
 ├── 0017 Macros
 └── 0019 Standard Library

0020 Runtime Architecture
 ├── 0021 HTTP Server
 ├── 0022 HTTP Client
 ├── 0023 File System
 ├── 0024 Socket Communication
 └── 0025 Action Extension Interface
```

---

## Implementation Status

| Phase | Proposals | Status |
|-------|-----------|--------|
| **Phase 1: Core** | 0001 | Implemented (Parser, AST, Semantic Analysis) |
| **Phase 1: Core** | 0002 | Lexer tokens implemented; Parser pending |
| **Phase 1: Core** | 0003 | Implemented (Scoping, Publish mechanism) |
| **Phase 1: Core** | 0004, 0005 | Lexer tokens implemented; Parser pending |
| **Phase 2: Types** | 0006, 0007 | Lexer tokens implemented; Parser pending |
| **Phase 3: Execution** | 0008, 0009, 0010 | Lexer tokens implemented; Parser pending |
| **Phase 4: Advanced** | 0011-0019 | Future |
| **Phase 5: Runtime** | 0020-0025 | Implemented (requires Swift 6 fixes) |

### Detailed Feature Status

| Feature | Lexer | Parser | Semantic | Runtime |
|---------|-------|--------|----------|---------|
| Core ARO Statements | ✅ | ✅ | ✅ | ✅ |
| Publish Statements | ✅ | ✅ | ✅ | ✅ |
| String Literals | ✅ | Pending | - | - |
| Number Literals | ✅ | Pending | - | - |
| Boolean Literals | ✅ | Pending | - | - |
| Operators (+, -, *, /, ==, etc.) | ✅ | Pending | - | - |
| if/then/else | ✅ | Pending | - | - |
| when Guards | ✅ | Pending | - | - |
| match Expressions | ✅ | Pending | - | - |
| for-each Loops | ✅ | Pending | - | - |
| while/repeat-until | ✅ | Pending | - | - |
| Type Annotations | ✅ | Pending | - | - |
| try/catch/guard | ✅ | Pending | - | - |
| @Annotations | ✅ | Pending | - | - |

---

## Reading Order

For newcomers to ARO:

1. Start with **0001 Core Syntax** - understand the basic structure
2. Read **0002 Literals/Expressions** - learn about values
3. Study **0003 Variable Scoping** - understand data flow
4. Continue with **0004 Conditionals** and **0005 Loops** - control flow
5. Learn **0006 Type System** - for type safety
6. Explore **0020 Runtime Architecture** - understand execution
7. Review **0025 Action Extension Interface** - for custom actions
8. Explore domain-specific proposals as needed

---

## Contributing

Each proposal follows the Swift Evolution format:

- **Abstract**: Brief summary
- **Motivation**: Why this is needed
- **Proposed Solution**: Detailed specification
- **Grammar**: EBNF grammar extensions
- **Examples**: Complete working examples
- **Implementation Notes**: Compiler/runtime considerations

---

*Last updated: December 2024*
