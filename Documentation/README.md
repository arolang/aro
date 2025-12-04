# ARO Documentation

Welcome to the ARO programming language documentation.

ARO (Action-Result-Object) is a declarative domain-specific language for expressing business features in a human-readable format. ARO programs describe *what* should happen using natural language constructs, and the runtime handles *how* it executes.

## About ARO

ARO is designed for building event-driven applications with clear, readable business logic. Key characteristics include:

- **Declarative Syntax**: Express intent, not implementation details
- **Event-Driven Architecture**: Feature sets respond to events automatically
- **Multi-File Applications**: Organize code across files without imports
- **Built-in Services**: HTTP server/client, file system, sockets out of the box

## Documentation

### Getting Started

| Document | Description |
|----------|-------------|
| [Getting Started](getting-started.html) | Install ARO and write your first application |
| [A Tour of ARO](language-tour.html) | A comprehensive introduction to ARO's features |

### Language Guide

Detailed documentation of ARO language features:

| Chapter | Description |
|---------|-------------|
| [The Basics](guide/thebasics.html) | Fundamental concepts, syntax, and structure |
| [Feature Sets](guide/featuresets.html) | Defining and organizing feature sets |
| [Actions](guide/actions.html) | Built-in actions and the ARO statement pattern |
| [Variables and Data Flow](guide/variables.html) | Variable binding, scoping, and publishing |
| [Type System](guide/typesystem.html) | Primitives, collections, and OpenAPI types |
| [Control Flow](guide/controlflow.html) | Conditionals, guards, and branching |
| [Error Handling](guide/errorhandling.html) | The "Code Is The Error Message" philosophy |
| [Concurrency](guide/concurrency.html) | Async feature sets, sync statements |
| [Events](guide/events.html) | Event-driven programming and handlers |
| [Application Lifecycle](guide/applicationlifecycle.html) | Start, run, and shutdown |
| [HTTP Services](guide/httpservices.html) | HTTP server and client operations |
| [File System](guide/filesystem.html) | File I/O and directory watching |
| [Sockets](guide/sockets.html) | TCP communication |

### Language Reference

Formal language specification:

| Document | Description |
|----------|-------------|
| [Grammar](reference/grammar.html) | Complete EBNF grammar specification |
| [Statements](reference/statements.html) | Statement types and syntax |
| [Actions Reference](reference/actionsreference.html) | Complete action verb reference |

### Extending ARO

| Document | Description |
|----------|-------------|
| [Action Developer Guide](action-developer-guide.html) | Creating custom actions in Swift |

## Quick Example

```aro
(* Application entry point *)
(Application-Start: Hello World) {
    <Log> the <greeting: message> for the <console> with "Hello, ARO!".
    <Return> an <OK: status> for the <startup>.
}

(* Graceful shutdown *)
(Application-End: Success) {
    <Log> the <farewell: message> for the <console> with "Goodbye!".
    <Return> an <OK: status> for the <shutdown>.
}
```

Run with:
```bash
aro run ./HelloWorld
```

## Resources

- [Evolution Proposals](https://github.com/KrisSimon/aro/tree/main/Proposals) - Language design proposals
- [Examples](https://github.com/KrisSimon/aro/tree/main/Examples) - Example applications
- [GitHub Repository](https://github.com/KrisSimon/aro) - Source code

## Version

This documentation covers ARO 1.0.
