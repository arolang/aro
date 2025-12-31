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

## Quick Reference

### Core Language

```
ARO Statement:    <Action> [article] <result: qualifier> preposition [article] <object: qualifier>.
Feature Set:      (Name: Business Activity) { ... }
Publish:          <Publish> as <alias> <variable>.
```

### Control Flow

```
Guard:            <Action> ... when <condition>.
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
Sink:             <Log> "message" to the <console>.
Source:           <Read> the <data> from the <file: "path">.
HTTP:             <Request> the <response> from the <url>.
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
├── legacy/                          # Original proposals (historical)
└── future/                          # Planned features
```

## Future Proposals

The following features are planned but not yet specified:

| Proposal | Feature |
|----------|---------|
| [ARO-0014](future/ARO-0014-domain-modeling.md) | Domain Modeling Patterns |
| [ARO-0015](future/ARO-0015-testing-framework.md) | Testing Framework |
| [ARO-0016](future/ARO-0016-interoperability.md) | Foreign Function Interface |
| [ARO-0018](future/ARO-0018-query-language.md) | Query Language |
| [ARO-0019](future/ARO-0019-standard-library.md) | Standard Library |
| [ARO-0030](future/ARO-0030-ide-integration.md) | IDE Integration |
| [ARO-0034](future/ARO-0034-language-server-protocol.md) | Language Server Protocol |

## Legacy Proposals

The `legacy/` directory contains the original evolution proposals. These are preserved for historical reference but have been superseded by the consolidated specifications above.

---

*Last updated: December 2025*
