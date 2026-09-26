# ARO Language Specification

This directory contains the ARO (Action-Result-Object) language specification: one
numbered Evolution Proposal per topic, 69 of them. The numbering is sparse —
proposals are added or rejected over time — so gaps are expected.

Every `ARO-NNNN` reference anywhere in the repository must resolve to a file here.
`Scripts/check-proposals.py` enforces that in CI, along with identifier uniqueness.
When citing a GitLab issue, write `GitLab #<number>`: the `ARO-` prefix means a
proposal and nothing else.

## Reading Order

New to ARO? Read 0001, 0004 and 0005 first — syntax, actions, and how an application
is put together. 0006 explains why there is no error handling to learn.

## Core Language

| # | Proposal | Topics |
|---|----------|--------|
| 1 | [Language Fundamentals](ARO-0001-language-fundamentals.md) | Core syntax, literals, expressions, scoping |
| 2 | [Control Flow](ARO-0002-control-flow.md) | `when` guards, `match`, iteration, `while`, `Break` |
| 3 | [Type System](ARO-0003-type-system.md) | Types, OpenAPI integration, schemas |
| 4 | [Actions](ARO-0004-actions.md) | Action roles, built-in actions, extensions |
| 5 | [Application Architecture](ARO-0005-application-architecture.md) | App structure and lifecycle (concurrency: see 0088) |
| 6 | [Error Philosophy](ARO-0006-error-philosophy.md) | "Code is the error message" |
| 7 | [Events & Reactive Systems](ARO-0007-events-reactive.md) | Events, state, repositories |
| 8 | [I/O Services](ARO-0008-io-services.md) | HTTP, files, sockets, system objects, webhooks |
| 9 | [Native Compilation](ARO-0009-native-compilation.md) | LLVM, `aro build`, plugins in binaries |
| 10 | [Advanced Features](ARO-0010-advanced-features.md) | Regex, dates, `Execute` |
| 11 | [HTML Parsing](ARO-0011-html-xml-parsing.md) | `Parse` for HTML documents (XML is a sketch, §4.2) |
| 14 | [Domain Modeling](ARO-0014-domain-modeling.md) | DDD patterns, entities, aggregates |
| 15 | [Testing Framework](ARO-0015-testing-framework.md) | Colocated tests, Given / When / Then |
| 16 | [Interoperability](ARO-0016-interoperability.md) | External services, `Call`, plugins |
| 18 | [Data Pipelines](ARO-0018-query-language.md) | Filter, transform, aggregate, group collections |
| 19 | [Standard Library](ARO-0019-standard-library.md) | Primitive types, the closed Compute-qualifier set |
| 22 | [State Guards](ARO-0022-state-guards.md) | Handler filtering with `field:value`, state observers |
| 81 | [User-Defined Actions](ARO-0081-user-defined-actions.md) | `Application.<Name>` callable feature sets, recursion |
| 88 | [Concurrency Model](ARO-0088-concurrency-model.md) | Statement overlap, ordered effects, `parallel for each` |
| 89 | [Ranges](ARO-0089-ranges.md) | `1..10` / `1..<10` as lazy values — **draft, not implemented** |

## Language Features

| # | Proposal | Topics |
|---|----------|--------|
| 31 | [Context-Aware Formatting](ARO-0031-context-aware-formatting.md) | Adaptive output for machine / human / developer |
| 35 | [Configurable Runtime](ARO-0035-configurable-runtime.md) | `Configure` for timeouts and settings |
| 36 | [Extended File Operations](ARO-0036-file-operations.md) | `Exists`, `Stat`, `Make`, `Copy`, `Move`, `Delete` |
| 37 | [Regex Split](ARO-0037-regex-split.md) | `Split` with regex delimiters |
| 38 | [List Element Access](ARO-0038-list-element-access.md) | `first`, `last`, index and range specifiers |
| 40 | [Format-Aware I/O](ARO-0040-format-aware-io.md) | Auto format detection for JSON, YAML, CSV and more |
| 41 | [Date/Time Ranges](ARO-0041-datetime-ranges.md) | Date arithmetic, ranges, recurrence |
| 42 | [Set Operations](ARO-0042-set-operations.md) | `intersect`, `difference`, `union` |
| 43 | [Sink Syntax](ARO-0043-sink-syntax.md) | Expressions in result position |
| 46 | [Typed Event Extraction](ARO-0046-typed-event-extraction.md) | Schema-validated event data |
| 47 | [Command-Line Parameters](ARO-0047-command-line-parameters.md) | `Parameters`, CLI argument parsing |
| 48 | [WebSocket](ARO-0048-websocket.md) | Server support, real-time messaging |
| 50 | [Template Engine](ARO-0050-template-engine.md) | Mustache-style templates, `Render`, escaping rules |
| 51 | [Streaming Execution](ARO-0051-streaming-execution.md) | Lazy evaluation, stream tee, aggregation fusion |
| 52 | [Unified URL I/O](ARO-0052-unified-url-io.md) | One I/O surface for files, URLs and streams |
| 56 | [Numeric Literal Underscores](ARO-0056-numeric-literal-underscores.md) | Superseded by 0082 |
| 60 | [Raw String Literals](ARO-0060-raw-string-literals.md) | Verbatim string syntax |
| 67 | [Pipeline Operator](ARO-0067-pipeline-operator.md) | Explicit pipelines (see also 0086) |
| 68 | [Extract Within Case](ARO-0068-extract-within-case.md) | Pattern-style extraction inside `match` |
| 71 | [Type Narrowing](ARO-0071-type-narrowing.md) | Flow-sensitive type refinement in branches |
| 72 | [Binary Socket & File Events](ARO-0072-binary-socket-file-events.md) | Binary payload handlers in compiled mode |
| 73 | [Store Files](ARO-0073-store-files.md) | File-backed repositories, YAML seeds, permission-based writability |
| 80 | [Git Actions](ARO-0080-git-actions.md) | Status, stage, commit, push, pull, clone, checkout, tag |
| 82 | [Numeric Separators](ARO-0082-numeric-separators.md) | Underscores in decimal literals (supersedes 0056) |
| 83 | [Terminal UI](ARO-0083-terminal-ui.md) | Terminal UI system |
| 86 | [Automatic Pipeline Detection](ARO-0086-automatic-pipeline-detection.md) | Implicit pipeline detection across statements |
| 90 | [Streaming I/O and Materialization](ARO-0090-streaming-io-and-materialization.md) | Bodies that stream vs. become values, `x-aro-max-body` |

## Tooling & Developer Experience

| # | Proposal | Topics |
|---|----------|--------|
| 30 | [IDE Integration](ARO-0030-ide-integration.md) | Syntax highlighting, snippets |
| 34 | [Language Server Protocol](ARO-0034-language-server-protocol.md) | `aro lsp`, diagnostics, navigation |
| 44 | [Runtime Metrics](ARO-0044-metrics.md) | Execution counts, timing, Prometheus format |
| 45 | [Package Manager](ARO-0045-package-manager.md) | `aro add` / `aro remove`, `plugin.yaml` |
| 49 | [Interactive REPL](ARO-0049-repl.md) | `aro repl` |
| 59 | [Structured Logging](ARO-0059-structured-logging.md) | JSON-shaped log records |
| 62 | [Dead Code Detection](ARO-0062-dead-code-detection.md) | Unreachable feature-set warnings |
| 84 | [Local LLM Integration](ARO-0084-local-llm.md) | `aro lm` — superseded by `aro ask` |
| 87 | [Plugin SDK](ARO-0087-plugin-sdk.md) | SDK and developer experience across Swift, Rust, C, Python |
| 91 | [Jupyter Kernel](ARO-0091-jupyter-kernel.md) | `aro repl --json`, native ZMQ kernel, notebook semantics |
| 92 | [The `aro ask` Assistant](ARO-0092-ask-assistant.md) | Local model, tool registry, approval model, `.context` |
| 94 | [Caller-Scoped Repositories](ARO-0094-caller-scoped-repositories.md) | `session` / `connection` repository scope over HTTP, WebSocket and TCP; session cookies (draft) |

## Runtime & Compiler Internals

| # | Proposal | Topics |
|---|----------|--------|
| 53 | [Lexer Lookup Optimization](ARO-0053-lexer-lookup-optimization.md) | Keyword / article / preposition recognition |
| 54 | [Execution Engine Refactor](ARO-0054-execution-engine-refactor.md) | Restructuring the interpreter's core |
| 55 | [Lexer Reserved Words](ARO-0055-lexer-reserved-words-optimization.md) | Faster reserved-word recognition |
| 57 | [Lexer `peekNext` Cache](ARO-0057-lexer-cache-peeknext.md) | Tokenization performance |
| 61 | [AST Visitor Pattern](ARO-0061-ast-visitor-pattern.md) | Traversal abstraction over the AST |
| 63 | [Value-Type AST Nodes](ARO-0063-value-type-ast-nodes.md) | `Sendable` AST representation |
| 64 | [Event Subscription Matching](ARO-0064-optimize-event-subscriptions.md) | Cheaper subscription lookup |
| 69 | [Async Plugin Compilation](ARO-0069-async-plugin-compilation.md) | Parallel plugin builds |
| 70 | [LLVM Expression Optimization](ARO-0070-llvm-expression-optimization.md) | Native codegen improvements |
| 85 | [Terminal Shadow Buffer](ARO-0085-terminal-shadow-buffer.md) | Shadow-buffer optimization (draft) |

## Quick Reference

### Core Language

```
ARO Statement:    Action [article] <result: qualifier> preposition [article] <object: qualifier>.
Feature Set:      (Name: Business Activity) { ... }
Publish:          Publish as <alias> <variable>.
User action:      (Name: Action takes <arg>) { ... }   ->  Application.Name the <r> from <x>.
```

### Control Flow

```
Guard:            Action ... when <condition>.
Guard block:      when <condition> { ... }
Header guard:     (Name: Event Handler) when <condition> { ... }
Match:            match <value> { case <pattern> { ... } otherwise { ... } }
Iteration:        for each <item> in <collection> { ... }
Concurrent:       parallel for each <item> in <collection> with <concurrency: N> { ... }
```

### Actions by Role

Roles are the data-flow direction the runtime assigns each action. `aro actions`
prints the live table, including each action's valid prepositions.

<!-- BEGIN GENERATED ROLE SUMMARY -->

<!-- Generated by Scripts/generate-action-reference.py — do not edit by hand. -->
<!-- Regenerate with: python3 Scripts/generate-action-reference.py -->

| Role | Actions |
|------|---------|
| REQUEST | Clone, Exists, Extract, List, ParseDispatch, Probe, Prompt, Pull, Read, Receive, Request, Retrieve, Select, Stat, Stream |
| OWN | Accept, Assert, Attach, Call, Clear, Compare, Compute, Configure, Create, Declare, Delete, Execute, Filter, GitCheckout, Given, Group, Include, Join, Map, Merge, ParseHtml, Reduce, Reverse, Show, Sleep, Sort, Split, Stage, Then, Transform, Update, Validate, When |
| RESPONSE | Append, Broadcast, Log, Notify, Render, Repaint, Return, Send, Store, Throw, Write |
| EXPORT | Emit, GitCommit, Publish, Push, Schedule, Tag |
| SERVER | Close, Connect, Copy, Listen, Make, Move, Start, Stop, Touch, WaitForEvents |

<!-- END GENERATED ROLE SUMMARY -->

`Store`, `Log`, `Send` and `Write` are conceptually exports but carry the RESPONSE
role in the implementation; ARO-0004 §2.4 records that tension rather than hiding it.
The wait action's type name is `WaitForEvents`; `keepalive` is the verb you write.

### I/O Syntax

```
Sink:             Log "message" to the <console>.
Source:           Read the <data> from the <file: "path">.
HTTP:             Request the <response> from the <url>.
```

---

*The table above is generated from this directory; `ls Proposals/` is the ground truth.*
