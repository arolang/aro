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
| [Getting Started](GettingStarted.md) | Install ARO and write your first application |
| [A Tour of ARO](LanguageTour.md) | A comprehensive introduction to ARO's features |

### Language Guide

Detailed documentation of ARO language features:

| Chapter | Description |
|---------|-------------|
| [The Basics](LanguageGuide/TheBasics.md) | Fundamental concepts, syntax, and structure |
| [Feature Sets](LanguageGuide/FeatureSets.md) | Defining and organizing feature sets |
| [Actions](LanguageGuide/Actions.md) | Built-in actions and the ARO statement pattern |
| [Variables and Data Flow](LanguageGuide/Variables.md) | Variable binding, scoping, and publishing |
| [Control Flow](LanguageGuide/ControlFlow.md) | Conditionals, guards, and branching |
| [Events](LanguageGuide/Events.md) | Event-driven programming and handlers |
| [Application Lifecycle](LanguageGuide/ApplicationLifecycle.md) | Start, run, and shutdown |
| [HTTP Services](LanguageGuide/HTTPServices.md) | HTTP server and client operations |
| [File System](LanguageGuide/FileSystem.md) | File I/O and directory watching |
| [Sockets](LanguageGuide/Sockets.md) | TCP communication |

### Language Reference

Formal language specification:

| Document | Description |
|----------|-------------|
| [Grammar](LanguageReference/Grammar.md) | Complete EBNF grammar specification |
| [Statements](LanguageReference/Statements.md) | Statement types and syntax |
| [Actions Reference](LanguageReference/ActionsReference.md) | Complete action verb reference |

### Extending ARO

| Document | Description |
|----------|-------------|
| [Action Developer Guide](ActionDeveloperGuide.md) | Creating custom actions in Swift |

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

- [Evolution Proposals](../Proposals/README.md) - Language design proposals
- [Examples](../Examples/) - Example applications
- [GitHub Repository](https://github.com/KrisSimon/aro) - Source code

## Version

This documentation covers ARO 1.0.
