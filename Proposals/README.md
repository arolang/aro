# ARO Language Specification

This directory contains the complete ARO (Action-Result-Object) language specification.

## Reading Order

For newcomers to ARO, read the proposals in order:

| # | Proposal | Topics |
|---|----------|--------|
| 1 | [Language Fundamentals](ARO-0001-language-fundamentals.md) | Core syntax, literals, expressions, scoping |
| 2 | [Control Flow](ARO-0002-control-flow.md) | When guards, match expressions, iteration |
| 3 | [Type System](ARO-0003-type-system.md) | Types, OpenAPI integration, schemas |
| 4 | [Actions](ARO-0004-actions.md) | Action roles, built-in actions, extensions |
| 5 | [Application Architecture](ARO-0005-application-architecture.md) | App structure, lifecycle, concurrency |
| 6 | [Error Philosophy](ARO-0006-error-philosophy.md) | "Code is the error message" |
| 7 | [Events & Reactive](ARO-0007-events-reactive.md) | Events, state, repositories |
| 8 | [I/O Services](ARO-0008-io-services.md) | HTTP, files, sockets, system objects |
| 9 | [Native Compilation](ARO-0009-native-compilation.md) | LLVM, aro build |
| 10 | [Advanced Features](ARO-0010-advanced-features.md) | Regex, dates, exec |
| 14 | [Domain Modeling](ARO-0014-domain-modeling.md) | DDD patterns, entities, aggregates |
| 15 | [Testing Framework](ARO-0015-testing-framework.md) | Colocated tests, Given/When/Then |
| 16 | [Interoperability](ARO-0016-interoperability.md) | External services, Call action |
| 18 | [Data Pipelines](ARO-0018-query-language.md) | Filter, transform, aggregate collections |
| 19 | [Standard Library](ARO-0019-standard-library.md) | Primitive types, utilities |
| 30 | [IDE Integration](ARO-0030-ide-integration.md) | Syntax highlighting, snippets |
| 34 | [Language Server Protocol](ARO-0034-language-server-protocol.md) | LSP server, diagnostics, navigation |
| 46 | [Typed Event Extraction](ARO-0046-typed-event-extraction.md) | Schema-validated event extraction |

## Quick Reference

### Core Language

```
ARO Statement:    Action [article] <result: qualifier> preposition [article] <object: qualifier>.
Feature Set:      (Name: Business Activity) { ... }
Publish:          Publish as <alias> <variable>.
```

### Control Flow

```
Guard:            Action ... when <condition>.
Match:            match <value> { case <pattern> { ... } otherwise { ... } }
Iteration:        for each <item> in <collection> { ... }
```

### Actions by Role

| Role | Actions |
|------|---------|
| REQUEST | Extract, Retrieve, Fetch, Read, List, Stat, Exists |
| OWN | Compute, Validate, Transform, Create, Update, Filter, Sort |
| RESPONSE | Return, Throw, Log, Send, Write |
| EXPORT | Publish, Store, Emit |
| SERVER | Start, Stop, Listen, Keepalive, Watch |

### I/O Syntax

```
Sink:             Log "message" to the <console>.
Source:           Read the <data> from the <file: "path">.
HTTP:             Request the <response> from the <url>.
```

## Directory Structure

```
Proposals/
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
├── ARO-0030-ide-integration.md
├── ARO-0034-language-server-protocol.md
└── ARO-0046-typed-event-extraction.md
```

---

*Last updated: January 2026*
