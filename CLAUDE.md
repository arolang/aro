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
aro check -r ./Apps   # Check every application under a directory separately;
                      # without -r a directory of applications is an error (#824)
aro diff --graph main..my-branch          # Feature-graph diff: nodes, statements, wires
aro diff --graph main..my-branch --html report.html   # Same comparison, two graphs side by side
aro build ./MyApp     # Compile to native binary (LLVM IR + object file)
aro build ./MyApp --verbose --optimize  # Verbose build with optimizations
aro build ./MyApp --static   # Default. Static Swift runtime; single file. (Linux: Foundation still dynamic.)
aro build ./MyApp --dynamic  # Bundle libswift*.so / libFoundation*.so next to the binary; rpath=$ORIGIN.
echo 'Log "Hi" to the <console>.' | aro   # Evaluate piped source on stdin

# Testing `aro build` against local runtime changes: build the runtime
# archive too, or the linker silently picks up the INSTALLED one.
swift build --product ARORuntime && swift build --product aro
#   Two invocations: SwiftPM honours only the LAST --product, so
#   `--product aro --product ARORuntime` silently builds just the runtime.
#   `aro build` links libARORuntime.a by search order, and an installed
#   /opt/homebrew/lib/libARORuntime.a wins over a worktree that never
#   produced one. A runtime change then appears to have no effect —
#   the binary was built against the release you have installed.

aro repl                 # Start the interactive ARO REPL
aro repl --json          # REPL over line-delimited JSON on stdio (ARO-0091);
                         # the Python shim kernel in Editor/jupyter-aro speaks this
aro kernel install       # Register the native Jupyter kernel (ZMQ, no Python);
                         # Jupyter then launches `aro kernel --connection-file …`
aro test ./MyApp         # Run colocated tests (ARO-0015)
aro new plugin foo --lang swift   # Scaffold a plugin (--lang is required:
                                  # swift, rust, c, cpp, python, aro)
aro add github:org/repo  # Install a plugin from Git
aro plugins              # List installed plugins
aro actions              # List built-in and plugin actions
aro lsp                  # Start the Language Server (stdio)
aro mcp                  # Start the MCP server (Model Context Protocol)

aro ask                  # Interactive AI coding assistant with tool calling
aro ask "fix this"       # One-shot prompt; uses native MLX on macOS,
                         # llama-server on Linux (auto-downloaded)
```

## Architecture

This is a Swift 6.3 parser/compiler/runtime for ARO (Action Result Object), a DSL for expressing business features as Action-Result-Object statements.

### Application Structure

An ARO application is a **directory** containing `.aro` files:

```
MyApp/
├── openapi.yaml       # OpenAPI contract (required for HTTP server)
├── main.aro           # Contains Application-Start (required, exactly one)
├── users.aro          # Feature sets for user operations
├── orders.aro         # Feature sets for order operations
├── events.aro         # Event handler feature sets
├── products.store     # Seeds products-repository (read-only)
└── sessions.store     # Seeds sessions-repository (writable if chmod o+w)
```

For larger applications, use the `sources/` subdirectory convention:

```
MyApp/
├── openapi.yaml       # Configuration in root
├── main.aro           # Entry point (optional location)
└── sources/           # Source files in subdirectory
    ├── users/
    │   └── users.aro
    └── orders/
        └── orders.aro
```

**Key Rules:**
- All `.aro` files in the directory **and subdirectories** are automatically discovered and parsed
- Files can be in root, `sources/`, or any subdirectory to any depth
- No imports needed - all feature sets are globally visible within the application
- Exactly ONE `Application-Start` feature set per application (error if 0 or multiple)
- At most ONE `Application-End: Success` and ONE `Application-End: Error` (both optional)
- Feature sets are triggered by **events**, not direct calls
- **Contract-First HTTP**: `openapi.yaml` is required for HTTP server (no contract = no server)

**A directory of applications is not an application.** `aro run`, `aro build` and
`aro check` all refuse a path holding several `Application-Start` feature sets in
different subdirectories, and name one to point at instead. `aro check --recursive`
checks each of them separately — without it, every `.aro` file under the path is
pooled into one pseudo-application, so sibling applications appear to share feature
sets and entry points (GitLab #824).

### Importing another application (ARO-0005 §3)

No imports are needed *within* an application. `import` is for pulling in a
**separate** application's feature sets, and it is the one place a path appears in
ARO source:

```aro
import ../ModuleA
import ../ModuleB

(Application-Start: Combined) {
    Start the <http-server> with <contract>.
    Keepalive the <application> for the <events>.
    Return an <OK: status> for the <startup>.
}
```

The path is relative to the importing file's directory, and every feature set,
type and published variable of the imported application becomes visible — so
`Examples/ModulesExample/Combined` serves the routes whose handlers live in
`ModuleA` and `ModuleB`. Remove the two lines and startup fails with "Missing
ARO feature set handlers".

It is resolved by `Application.resolveImports`; there are no visibility modifiers
and no partial imports.

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
    Retrieve the <users> from the <user-repository>.
    Return an <OK: status> with <users>.
}

(createUser: User API) {
    Extract the <data> from the <request: body>.
    Create the <user> with <data>.
    Emit a <UserCreated: event> with <user>.
    Return a <Created: status> with <user>.
}

(getUser: User API) {
    Extract the <id> from the <pathParameters: id>.
    Retrieve the <user> from the <user-repository> where <id> is <id>.
    Return an <OK: status> with <user>.
}

(* Event handlers still work as before *)
(Send Welcome Email: UserCreated Handler) {
    Extract the <user> from the <event: user>.
    Send the <welcome-email> to the <user: email>.
    Return an <OK: status> for the <notification>.
}
```

**Path Parameters**: Extracted from URL and available via `pathParameters`:
- `Extract the <id> from the <pathParameters: id>.`

**Request Body**: Typed according to OpenAPI schema:
- `Extract the <data> from the <request: body>.`

### Happy Case
Code contains only the happy case. Errors are handled by the runtime, which
reconstructs the failed statement with its values:
`Cannot retrieve the user from the user-repository where id = 530`.

**A `Retrieve` that matches nothing is not one of those errors.** It binds an
empty list (`ExtractAction.swift:860`); with a `where` clause matching exactly
one row it binds that record rather than a one-element list. The only throw on
that path is a repository that does not exist. Guard on the result — the
statement does not fail for you (GitLab #835).

Do not use it for production code, it is terribly insecure.

### Key Types

**Parser:**
- `Program` → `FeatureSet[]` → `Statement[]` (either `AROStatement` or `PublishStatement`)
- `AROStatement`: `Action [the] <Result> preposition [the] <Object>` (articles optional)
- `SymbolTable`: Immutable, `Sendable` symbol storage per feature set
- `GlobalSymbolRegistry`: Cross-feature-set symbol access for published variables
- `FeatureGraph` / `FeatureGraphDiff`: The application as nodes (feature sets)
  and wires (events, `Application.<Name>` calls, repository observers), and the
  comparison of two revisions of it. Derived statically with the runtime's own
  matching rules, so `aro diff --graph` and SOLARO's review sheet show the same
  graph the EventBus will wire up (GitLab #443).

**Runtime:**
- `ActionImplementation`: Protocol for action implementations
- `ResultDescriptor` / `ObjectDescriptor`: Statement metadata for actions
- `ExecutionContext`: Runtime context protocol
- `RuntimeEvent`: Protocol for events

### Action Semantic Roles

Five roles, classified by data flow direction. `aro actions` prints the live
table and ARO-0004 §11 is generated from it — prefer either over this summary:

- **REQUEST** (Extract, Parse, Retrieve, Fetch, Probe, Pull, Clone): External → Internal
- **OWN** (Compute, Validate, Compare, Create, Transform, Stage, Checkout): Internal → Internal
- **RESPONSE** (Return, Throw, **Store, Log, Send, Write**, Render): Internal → External
- **EXPORT** (Publish, Emit, Commit, Push, Tag, Schedule): Makes symbols globally accessible or exports data
- **SERVER** (Start, Stop, Listen, Connect, Close, WaitForEvents): Service lifecycle

`Store`, `Log`, `Send` and `Write` read as exports and declare `.response`. That
is a known, deliberate inconsistency (GitLab #480, ARO-0004 §2.4), not a typo to
fix here — roles drive data-flow analysis, so changing one changes behaviour.

### Statement Execution (ARO-0088)

Statements start in source order; the program waits for one at the **first read
of its result**. Independent statements therefore overlap: two 2-second requests
in one feature set take ~2.1s interpreted (~2.8s compiled), not 4.2s.

Effects (`Log`, `Store`, `Emit`, `Send`, `Publish`, `Return`, …) never defer —
they run at their own statement and force what they read first, so observable
output stays in source order. Deferral is an allowlist of value-producing verbs
(`LazyActionPolicy.deferrableVerbs`); `Sleep` is deliberately excluded because
the delay *is* the effect.

Mechanics: a deferred action returns an `AROFuture` running on
`ActionTaskExecutor` (GCD's elastic queue, so blocked forcers can't starve the
work that would unblock them). Each statement gets its own scope for framework
variables (`_with_`, `_literal_`, …) — otherwise a deferred action would read
the next statement's modifiers. Feature-set exit forces whatever is outstanding,
so a failure nobody read is still reported, attributed to the statement that
caused it. Slow-force warnings fire after `ARO_FORCE_WARN_SECONDS` (default 5s).

Streams pipeline the same way: the producer runs ahead of the consumer by
`ARO_STREAM_PREFETCH` elements (default 2) through a bounded channel.

`ARO_NO_DEFER=1` disables deferral entirely — the fastest way to find out
whether a suspected bug is order-related.

### Request Bodies (ARO-0090)

**Streams don't have a size. Values do.** A feature set that only *moves* its
request body — `Write … to the <file: …>`, `Send`, `Return`, `Emit`, `for each`
— never builds it in memory, so its size is bounded by the sink and no limit
applies. A feature set that *reads* it — a field access, `Compute`, `Store`,
`Log`, or a `when` guard — turns it into a value, and that is what is bounded.

```aro
(uploadDocument: Files API) {
    Extract the <upload> from the <request: body>.   (* binds — reads nothing *)
    Write the <upload> to the <file: target>.        (* streams; 4 GB is fine *)
    Return a <Created: status> with <name>.
}
```

The limit is declared per route in the contract and defaults to 1 MB:

```yaml
paths:
  /notes:
    post:
      operationId: createNote
      x-aro-max-body: 256KB
```

`Configure the <http-server: max-body> with "1MB".` (or `ARO_MAX_BODY`) sets the
default; the route's own declaration wins. A body over the limit is answered
`413` before it is read — from `Content-Length` at the request head where the
client declared one, incrementally otherwise.

Which of the two a route is, is computed from the source before the server
binds a port (`BodyMaterializationAnalyzer`, verb table in
`StreamConsumptionPolicy`), so `aro check` reports it per route. Anything the
analysis cannot see through — a plugin action, an unknown verb — counts as
reading. A body arrives once and can be consumed once. `Emit`/`Publish` of a
body *anchors* it: drained to a temp file a chunk at a time so handlers that
outlive the request can each read it, deleted when the last reference goes.
Folding qualifiers (`sha256`, `length`, `lines`) consume the body chunk by
chunk, so hashing a 4 GB upload costs a chunk too — and hashes the upload's
bytes rather than a rendering of its parsed form. `aro run` and `aro build`
agree: the analysis is baked into the binary at build time, and the compiled
server enforces the same limits and streams the same bodies.

### User-Defined Actions (ARO-0081)

A feature set whose business activity is `Action` becomes callable
application-wide as `Application.<Name>`. Use this instead of writing a
plugin or hopping through the event bus when you want reusable inline
logic.

```aro
(DoubleValue: Action takes <number>) {
    Extract the <n> from the <input: number>.
    Compute the <doubled> from <n> * 2.
    Return an <OK: status> with { doubled: <doubled> }.
}

(SumAndDouble: Action) {
    Extract the <a> from the <input: a>.
    Extract the <b> from the <input: b>.
    Compute the <sum> from <a> + <b>.
    Application.DoubleValue the <inner> from <sum>.
    Extract the <result> from the <inner: doubled>.
    Return an <OK: status> with <result>.
}

(* Call site uses the same shape as plugin actions. `SumAndDouble` declares
   no `takes`, so the argument object goes through `with`, not `from`. *)
(Application-Start: Demo) {
    Application.SumAndDouble the <res> with { a: 3, b: 4 }.
    Log <res> to the <console>.
    Return an <OK: status> for the <startup>.
}
```

`takes <name>` is sugar for a single positional argument extracted as
`input.<name>`. Without `takes`, callers pass an object literal via `with`.
The return value follows the standard Return action shape; the caller pulls
named fields off it the same way they would for any other record.

**Recursion has no depth limit** (ARO-0081 §9). A call in tail position — the
final statement is an unguarded `Return … with <r>.` forwarding the call's
result untouched — reuses its frame, so depth costs nothing. Any other
recursion keeps its frames on the heap and is bounded by memory. A callee sees
its own bindings and application-level ones, never the caller's locals, so
lookup cost doesn't grow with depth. `aro check` warns when every path through
an action reaches a call before a `Return` (direct or mutual cycle), and a
runaway recursion stops at `ARO_MAX_CALL_DEPTH` (default 50 000, `0` disables)
with an error naming the call chain instead of an OOM kill.

## Services

Built-in services available at runtime:
- **AROHTTPServer**: SwiftNIO-based HTTP server
- **AROHTTPClient**: AsyncHTTPClient-based HTTP client
- **AROFileSystemService**: File I/O with FileMonitor watching
- **AROSocketServer** / **AROSocketClient**: TCP communication
- **GitService**: Native Git operations via libgit2 (ARO-0080)

## Plugin System

ARO supports plugins in multiple languages for extending functionality:

### Plugin Types

| Type | Language | Interface |
|------|----------|-----------|
| `swift-plugin` | Swift | `@_cdecl` functions with C ABI |
| `rust-plugin` | Rust | `#[no_mangle] extern "C"` functions |
| `c-plugin` | C/C++ | Standard C ABI |
| `python-plugin` | Python | `aro_plugin_info()` + `aro_action_{name}()` functions |

### Plugin Directory Structure

```
MyApp/
├── main.aro
├── openapi.yaml
└── Plugins/
    └── my-plugin/
        ├── plugin.yaml      # Plugin manifest (required)
        └── src/             # Source files
```

**`Plugins/` is the only plugin directory** (GitLab #848). A lowercase
`plugins/` is still read, with a deprecation warning, and will stop being read.

The two were never interchangeable, which is why this is worth a paragraph.
They used to be handled by two different loaders: `loadManagedPlugins` read
`Plugins/` and required one subdirectory per plugin with a `plugin.yaml` — the
layout `aro add` installs and `aro new plugin` scaffolds — while `loadPlugins`
read lowercase `plugins/` and took loose `.swift` files, prebuilt libraries and
bare Swift packages with no manifest. On macOS and Windows those are the same
directory, so both loaders walked it and one of them succeeded; on Linux they
are two, and only the matching one ran. A project therefore loaded a different
set of plugins depending on the developer's filesystem.

One directory is resolved now, and every layout above is loaded from it. Use
`Plugins/` with a manifest for anything new.

### Key Files

- **PluginLoader** (`Services/PluginLoader.swift`): Discovers and loads plugins from `Plugins/` directory
- **UnifiedPluginLoader** (`Plugins/UnifiedPluginLoader.swift`): Unified loading for all plugin types
- **NativePluginHost** (`Plugins/NativePluginHost.swift`): Loads C/Rust plugins via `dlopen`
- **PythonPluginHost** (`Plugins/PythonPluginHost.swift`): Runs Python plugins via subprocess
- **SwiftPluginHost** (`Plugins/SwiftPluginHost.swift`): Loads Swift plugins

### Plugin Registration by Language

| Language | Registration Pattern |
|----------|---------------------|
| **Swift** | `@AROExport` macro on `let plugin = AROPlugin(...)` — SDK generates all C ABI exports |
| **Rust** | `#[no_mangle] extern "C"` functions (`aro_plugin_info`, `aro_plugin_execute`, etc.) |
| **C/C++** | `ARO_PLUGIN()` + `ARO_ACTION()` / `ARO_QUALIFIER()` macros from `aro_plugin_sdk.h` |
| **Python** | `@plugin` + `@action` / `@qualifier` decorators + `export_abi(globals())` |

### C ABI Interface

Underlying all plugins is a C-compatible ABI. The SDKs generate these exports automatically:

```c
char* aro_plugin_info(void);                                      // metadata JSON
char* aro_plugin_execute(const char* action, const char* input);  // action dispatch
char* aro_plugin_qualifier(const char* name, const char* input);  // qualifier dispatch
void  aro_plugin_free(char* ptr);                                 // memory cleanup
```

### Plugin Qualifiers

Plugins can register custom qualifiers that transform values. Qualifiers work on types like List, String, Int, etc.

Plugin qualifiers are **namespaced** via the `handler:` field in `plugin.yaml`. Access them as `<value: handler.qualifier>`:

```aro
(* Plugin qualifiers use handler namespace *)
Compute the <random-item: collections.pick-random> from the <items>.
Compute the <sorted-list: stats.sort> from the <numbers>.
Log <numbers: collections.reverse> to the <console>.
```

**Declaring the namespace handle in plugin.yaml:**
```yaml
name: plugin-collection
version: 1.0.0
handle: Collections        # root-level PascalCase handle (canonical, GitLab #95)
provides:
  - type: swift-plugin
    path: Sources/
    handler: collections   # legacy fallback — use root-level handle: instead
```

The root-level `handle:` field (PascalCase) is the canonical way to declare the namespace.
- Qualifiers are accessed as `handle.qualifier` (e.g., `Collections.pick-random`)
- Actions are invoked as `Handle.Verb` (e.g., `Markdown.ToHTML`)
- The legacy `handler:` inside `provides:` still works but emits a deprecation
  warning — including when a root-level `handle:` is also present, which it did
  not before (GitLab #825). If the two name different namespaces, the root-level
  one wins and the warning says so.
- A plugin whose **code** declares a handle that disagrees with its manifest
  warns too. The manifest wins, because it is what the loader reads and what
  `aro add` writes; it used to win silently, so a plugin could ship every
  qualifier under a namespace its own source never mentioned.

Qualifiers are declared in `aro_plugin_info()` JSON with plain names (no namespace prefix).
The runtime automatically registers them as `handle.qualifier` in `QualifierRegistry`.

**Key Files:**
- **QualifierRegistry** (`Qualifiers/QualifierRegistry.swift`): Central registry for plugin qualifiers
- **PluginQualifierHost** (`Plugins/PluginQualifierHost.swift`): Protocol for executing qualifiers

### Binary Mode Support

Plugins work in both interpreter (`aro run`) and compiled binary (`aro build`) modes:
- During `aro build`, plugins in `Plugins/` are compiled and bundled
- Swift/C plugins are compiled to dynamic libraries
- Python plugins are copied with their source files
- Native plugins are linked INTO the binary, their symbols renamed
  `aro_static_<plugin>__<symbol>` so several can coexist (Linker.swift);
  Python plugins ship as source beside it

## ARO Syntax

<!-- aro-check: skip — the shape of a feature set, with placeholder names -->
```aro
(Feature Name: Business Activity) {
    Require the <token> from the <environment>.
    Extract the <result: qualifier> from the <source: qualifier>.
    Compute the <output> for the <input>.
    Return an <OK: status> for a <valid: result>.
    Publish as <alias> <output>.
}
```

### Statements that are not actions

Four forms are part of the grammar rather than the action registry, so they have
no role, no prepositions, and no entry in `aro actions` — which explains them
instead of reporting "no action named" (GitLab #828):

| Form | Meaning |
|------|---------|
| `Publish as <alias> <variable>.` | Makes a variable visible to other feature sets in the same business activity |
| `Require the <name> from the <source>.` | Declares an external dependency (below) |
| `match <noun> { case <pattern> { … } otherwise { … } }` | Branches on a value; the first matching case wins |
| `Break.` | Leaves the innermost loop |

**`Require`** names something the feature set expects to be there, and the source
decides who provides it:

```aro
Require the <console> from the <framework>.      (* provided by the runtime *)
Require the <API_TOKEN> from the <environment>.  (* binds that environment variable *)
Require the <settings> from the <ConfigLoader>.  (* expects that feature set to Publish it *)
```

`framework` is a no-op that documents the dependency. `environment` binds the
variable of that name, and reading it when the variable is unset fails the
statement in the usual way. Any other source names a feature set, and `aro check`
warns when nothing publishes that symbol — the one case where the warning is the
point. The source name is a single identifier, so a multi-word feature set cannot
be named here.

Application lifecycle handlers:
```aro
(* Entry point - exactly one per application *)
(Application-Start: My App) {
    Log "Starting..." to the <console>.
    Start the <http-server> with <contract>.
    Return an <OK: status> for the <startup>.
}

(* Exit handler for graceful shutdown - optional, at most one *)
(Application-End: Success) {
    Log "Shutting down..." to the <console>.
    Stop the <http-server> with <application>.
    Return an <OK: status> for the <shutdown>.
}

(* Exit handler for errors/crashes - optional, at most one *)
(Application-End: Error) {
    Extract the <error> from the <shutdown: error>.
    Log <error> to the <console>.
    Return an <OK: status> for the <error-handling>.
}
```

### Computations

The Compute action transforms data using built-in operations:

| Operation | Description | Example |
|-----------|-------------|---------|
| `length` / `count` | Count elements | `Compute the <len: length> from <text>.` |
| `uppercase` | Convert to UPPERCASE | `Compute the <upper: uppercase> from <text>.` |
| `lowercase` | Convert to lowercase | `Compute the <lower: lowercase> from <text>.` |
| `hash` | Compute hash value | `Compute the <hash: hash> from <password>.` |
| `trim` | Strip surrounding whitespace | `Compute the <clean: trim> from <field>.` |
| `replace` | Substring replacement | `Compute the <out: replace> from <t> with { find: "-", replace: "_" }.` |
| `html-escape` | Escape `& < > " '` for HTML | `Compute the <safe: html-escape> from <input>.` |
| `url-encode` / `url-decode` | Percent-encode a query value | `Compute the <enc: url-encode> from <query>.` |
| `base64-encode` / `base64-decode` | Standard Base64 | `Compute the <b64: base64-encode> from <creds>.` |
| `base64url-encode` / `base64url-decode` | URL-safe Base64 (JWTs) | `Compute the <tok: base64url-encode> from <payload>.` |
| `json-escape` | Escape for a JSON string literal | `Compute the <esc: json-escape> from <text>.` |
| `lines` | Split text into a list of lines | `Compute the <ls: lines> from <content>.` |
| `join` | Join a collection into a string | `Compute the <csv: join> from <items> with { separator: ", " }.` |
| `sum` | Total of a numeric collection | `Compute the <total: sum> from <amounts>.` |
| `avg` / `average` | Arithmetic mean | `Compute the <mean: avg> from <scores>.` |
| `unique` | Remove duplicates, first wins | `Compute the <tags: unique> from <all>.` |
| `random` | Random element, or Int below a bound | `Compute the <pick: random> from <options>.` |
| `sha256` | SHA-256 hex digest (alias of `hash`) | `Compute the <d: sha256> from <payload>.` |
| `fixed` | Round to N decimal places (2 by default) — money | `Compute the <total: fixed> from <raw>.` |
| Arithmetic | +, -, *, /, % | `Compute the <total> from <price> * <qty>.` |

Encoding qualifiers are specified in `Proposals/ARO-0019-standard-library.md` §3.1,
collection/text qualifiers in §3.2. A template whose path ends `.html` or `.htm`
escapes what it prints; `.tpl`, `.txt` and `.md` do not, so a `.tpl` emitting HTML
still needs `html-escape` (GitLab #476, `TemplateEscaping.forTemplate`). Both output
forms escape on the same rule — `Print <x> to the <template>.` and the `{{ <x> }}`
shorthand (GitLab #560) — and each opts out its own way: `<template: raw>` for
Print, the `| raw` filter for the shorthand. Escaping runs after the filters, so
`{{ <body> | markdown | raw }}` is how markup-emitting filters stay markup. Do not
hand-escape into an escaping template, or the reader sees `&amp;lt;`.

**The qualifier namespace is closed** (§3.3, GitLab #486). A Compute qualifier must
resolve to a built-in, a plugin qualifier (`handle.qualifier`), a chain (`a|b`), or a
date offset (`-7d`); anything else is an error naming the closest match. It
used to return the input unchanged, so an invented qualifier compiled, passed
`aro check`, exited `[OK]`, and printed the wrong value. Counting lines is
`lines` then `length` — `lines` already drops the trailing newline's phantom
element. Run `aro actions --qualifiers` for the live set.

`aro check` rejects unknown qualifiers too (GitLab #465), so a green check means
the qualifier exists. The names live in `ComputeQualifierCatalog` (AROParser,
because the check path never loads the runtime) and a runtime test asserts they
match `ComputeAction.builtInQualifiers` — add a qualifier to one and the suite
fails until you add it to the other. Namespaced names and chains are accepted at
check time and resolved at run time, since `aro check` does not load plugins.

Two forms are commonly mistaken for qualifiers, and the diagnostic names both:
sorting/reversing/element access are actions (`Sort the <s> for the <x>.`,
`Reverse the <r> for the <x>.`, `Extract the <f: first> from the <x>.`), and a
result *type* uses `as` (`Compute the <n> as Float from <s>.`) because the
qualifier slot selects an operation.

**`Map` takes a field name, not a value.** `Map the <ns> from the <us> with name.`
and `Map the <ns: name> from the <us>.` are the same statement. There is no
per-element binding, so `with <item> * 0.9` has nothing to range over — it used
to parse and die on `Undefined variable: item`, and `with 3` was discarded
silently; both are check-time errors now. Use `for each` to compute per element.

**Qualifier-as-Name Syntax**: When you need multiple results of the same operation, use the qualifier to specify the operation while the base becomes the variable name:

```aro
(* Old syntax: 'length' is both the variable name AND the operation *)
Compute the <length> from the <message>.

(* New syntax: variable name and operation are separate *)
Compute the <first-length: length> from the <first-message>.
Compute the <second-length: length> from the <second-message>.

(* Now both values are available *)
Compare the <same-length> from the <first-length> against the <second-length>.
Return an <OK: status> for the <check> when <same-length: matches>.
```

`Compare` takes both operands as inputs and binds a fresh result
(GitLab #469) — `<result: matches>` is the boolean, `<result: result>`
is `equal` / `less` / `greater`. The older two-operand spelling
(`Compare the <a> against the <b>.`) tried to rebind its own first
operand and could never run under immutability.

See `Proposals/ARO-0001-language-fundamentals.md` for the full specification.

### Long-Running Applications

For applications that need to stay alive and process events (servers, file watchers, etc.), use the `Keepalive` action:

```aro
(Application-Start: File Watcher) {
    Log "Starting..." to the <console>.
    Start the <file-monitor> with ".".

    (* Keep the application running to process events *)
    Keepalive the <application> for the <events>.

    Return an <OK: status> for the <startup>.
}
```

The `Keepalive` action:
- Blocks execution until a shutdown signal is received (SIGINT/SIGTERM)
- Allows the event loop to process incoming events
- Enables graceful shutdown with Ctrl+C

### Git Actions (ARO-0080)

Native version control via libgit2. The bare `<git>` system object discovers the enclosing repository upward from the current working directory (like the `git` CLI); use `<git: "/path">` for an explicit repository (opened as given, no discovery).

```aro
(* Status, log, branch via Retrieve *)
Retrieve the <status> from the <git>.
Retrieve the <log> from the <git>.
Retrieve the <branch> from the <git>.

(* Stage and commit *)
Stage the <files> to the <git> with ".".
Commit the <result> to the <git> with "feat: add feature".

(* Remote operations (requires git CLI) *)
Pull the <updates> from the <git>.
Push the <result> to the <git>.

(* Branching and tagging — a new name, because <branch> is already bound *)
Checkout the <switched> from the <git> with "feature/new".
Tag the <release> for the <git> with "v1.0.0".

(* Clone — optional `branch:` checks out that ref at clone time *)
Clone the <repo> from the <git> with { url: "https://github.com/user/repo.git", path: "./cloned" }.
Clone the <repo-on-develop> from the <git> with { url: "...", path: "./other", branch: "develop" }.
```

| Action | Verb | Role | Prepositions |
|--------|------|------|-------------|
| Status/Log/Branch | `Retrieve` | REQUEST | from |
| Stage | `Stage` | OWN | to, for |
| Commit | `Commit` | EXPORT | to, with |
| Pull | `Pull` | REQUEST | from |
| Push | `Push` | EXPORT | to, with |
| Clone | `Clone` | REQUEST | from, with, to |
| Checkout | `Checkout` | OWN | from, to, with |
| Tag | `Tag` | EXPORT | for, with |

Git actions emit events: `GitCommit`, `GitPush`, `GitPull`, `GitCheckout`, `GitTag`, `GitClone`.

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
│   ├── Plugins/        # Plugin hosts (Native, Python, Swift)
│   ├── Services/       # PluginLoader, UnifiedPluginLoader
│   ├── Git/            # GitService (libgit2), GitEvents (ARO-0080)
│   └── Application/    # App lifecycle, ApplicationLoader
├── AROCompiler/        # Native compilation (LLVM code generation)
│   ├── LLVMCodeGenerator.swift  # AST to LLVM IR transformation
│   └── Linker.swift    # Compilation and linking
│   └── Bridge/         # C-callable runtime for compiled binaries
│       ├── ActionBridge.swift     # Actions via @_cdecl (245 exports across the dir)
│       ├── FileSystemBridge.swift # File/watcher C interface
│       └── RuntimeExecutionBridge.swift # Expression evaluation for built code
└── AROCLI/             # CLI (run, compile, check, build commands)

Examples/               # 110 examples organized by category (run `ls Examples/` for full list)
│                       #
│                       # plan.md is the canonical description of an example:
│                       # 100 of the 110 have one, and it is the prompt the
│                       # example was written from. expected.txt is its
│                       # executable contract, and test.hint tells the
│                       # integration harness how (or whether) to run it.
│                       # README.md is optional narrative — 40 have one — and
│                       # is the layer that goes stale, so when they disagree,
│                       # plan.md and expected.txt win (GitLab #818).
│
│   # Getting Started
├── HelloWorld/         # Minimal single-file example
├── HelloWorldAPI/      # Simple HTTP API
├── Calculator/         # Basic arithmetic operations
│
│   # Core Language
├── Computations/       # Compute operations and qualifier-as-name syntax
├── Expressions/        # Arithmetic, comparison, and logical operators
├── Conditionals/       # When guards and conditional execution
├── Iteration/          # For-each loops and collection iteration
├── Scoping/            # Publish as, business activity scope, framework vars, pipeline, loop isolation
├── Immutability/       # Immutable bindings, new-name pattern, qualifier-as-name
├── ErrorHandling/      # Error philosophy demonstration
├── UserDefinedActions/ # Application.<Name> callable actions (ARO-0081)
├── RecursiveActions/   # Recursion shapes: nested frames, tail calls, mutual (ARO-0081 §9)
│
│   # Events & Lifecycle
├── EventExample/       # Custom event emission and handling
├── EventListener/      # Event subscription patterns
├── ApplicationEnd/     # Graceful shutdown handlers
├── StateMachine/       # State transitions with Accept action
├── OrderService/       # Full state machine example
│
│   # HTTP & WebSocket
├── HTTPServer/         # HTTP server with Keepalive
├── FileUpload/         # Streamed uploads, per-route body limits (ARO-0090)
├── HTTPClient/         # HTTP client requests
├── WeatherClient/      # Request action fetching live external API data
├── UserService/        # Multi-file REST API application
├── SimpleChat/         # WebSocket real-time messaging
├── WebSocketDemo/      # WebSocket server patterns
│
│   # File System
├── FileWatcher/        # File system monitoring
├── FileOperations/     # File I/O (read, write, copy, move)
├── FileMetadata/       # File stats and attributes
├── FormatAwareIO/      # Auto-detect JSON, YAML, CSV
├── DirectoryReplicator/ # Directory operations
│
│   # Data Processing
├── DataPipeline/       # Filter, transform, aggregate
├── GroupDemo/          # Group action: partition collections by field
├── SetOperations/      # Union, intersect, difference
├── CollectionMerge/    # Merging collections and objects
├── RepositoryObserver/ # Repository change observers
├── SQLiteExample/      # Database plugin usage
│
│   # Dates & Time
├── DateTimeDemo/       # Date/time operations
├── DateRangeDemo/      # Date ranges and recurrence
│
│   # Git
├── GitDemo/            # Native Git operations (status, log, stage, commit)
│
│   # Data engineering
├── MedallionPipeline/  # bronze/silver/gold: ingest CSV, filter, join, aggregate, write a data product
│
│   # Sockets & Services
├── EchoSocket/         # TCP socket server
├── SocketClient/       # TCP client connections
├── MultiService/       # Multiple services in one app
├── ExternalService/    # External service integration
│
│   # Templates & Output
├── TemplateEngine/     # Mustache-style templates
├── ContextAware/       # Human/machine/developer formatting
├── MetricsDemo/        # Prometheus metrics export
│
│   # CLI & Parameters
├── Parameters/         # Command-line argument parsing
├── ConfigurableTimeout/ # Runtime configuration
│
│   # Plugins (multi-language)
├── GreetingPlugin/     # Swift plugin example
├── HashPluginDemo/     # C plugin example
├── CSVProcessor/       # Rust plugin example
├── MarkdownRenderer/   # Python plugin example
├── ZipService/         # Plugin with external dependencies
│
│   # Plugin Qualifiers
├── QualifierPlugin/    # Swift plugin with qualifiers (pick-random, shuffle, reverse)
├── QualifierPluginC/   # C plugin with qualifiers (first, last, size)
├── QualifierPluginPython/ # Python plugin with qualifiers (sort, unique, sum, avg, min, max)
│
│   # Store Files
└── StoreFileDemo/      # File-backed repositories via .store files

Proposals/              # Language specifications
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
├── ARO-0011-html-xml-parsing.md
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
├── ARO-0043-sink-syntax.md
├── ARO-0044-metrics.md
├── ARO-0045-package-manager.md
├── ARO-0050-template-engine.md
├── ARO-0046-typed-event-extraction.md
├── ARO-0047-command-line-parameters.md
├── ARO-0048-websocket.md
├── ARO-0051-streaming-execution.md
├── ARO-0073-store-files.md
├── ARO-0080-git-actions.md
├── ARO-0081-user-defined-actions.md
├── ARO-0082-numeric-separators.md
├── ARO-0083-terminal-ui.md
├── ARO-0084-local-llm.md
├── ARO-0085-terminal-shadow-buffer.md
├── ARO-0086-automatic-pipeline-detection.md
├── ARO-0087-plugin-sdk.md
├── ARO-0088-concurrency-model.md
├── ARO-0089-ranges.md
├── ARO-0090-streaming-io-and-materialization.md
└── ARO-0091-jupyter-kernel.md
```

## Language Proposals

The `Proposals/` directory contains language specifications:

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
| **0009 Native Compilation** | LLVM, aro build, plugins in binaries |
| **0010 Advanced Features** | Regex, dates, exec |
| **0011 HTML Parsing** | Parse action for HTML documents (XML is a sketch) |
| **0014 Domain Modeling** | DDD patterns, entities, aggregates |
| **0015 Testing Framework** | Colocated tests, Given/When/Then |
| **0016 Interoperability** | External services, Call action, plugins |
| **0018 Data Pipelines** | Filter, transform, aggregate, group collections |
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
| **0044 Runtime Metrics** | Execution counts, timing, Prometheus format |
| **0045 Package Manager** | Plugin installation, aro add/remove, plugin.yaml |
| **0046 Typed Event Extraction** | Schema-validated event data extraction |
| **0047 Command-Line Parameters** | CLI argument parsing, Parameters action |
| **0048 WebSocket** | WebSocket server support, real-time messaging |
| **0050 Template Engine** | Mustache-style templates, Render action |
| **0051 Streaming Execution** | Lazy evaluation, Stream Tee, Aggregation Fusion |
| **0073 Store Files** | File-backed repositories, YAML seed data, permission-based writability |
| **0080 Git Actions** | Native Git via libgit2: status, stage, commit, push, pull, clone, checkout, tag |
| **0081 User-Defined Actions** | Feature sets callable as `Application.<Name>` from any other feature set |
| **0082 Numeric Separators** | Underscores in decimal literals (supersedes 0056) |
| **0083 Terminal UI** | Terminal UI system |
| **0084 Local LLM** | `aro lm` (superseded by `aro ask`, ARO-0092) |
| **0085 Terminal Shadow Buffer** | Terminal shadow-buffer optimization (draft) |
| **0086 Automatic Pipeline Detection** | Implicit pipeline detection |
| **0087 Plugin SDK** | Plugin SDK & developer experience |
| **0088 Concurrency Model** | What runs concurrently, ordering guarantees, `parallel for each`, event dispatch |
| **0089 Ranges** | `1..10` / `1..<10` as lazy values, lexing rules, why `[1..10]` stays an error (draft) |
| **0090 Streaming I/O** | Request bodies that stream vs. bodies that become values, `x-aro-max-body`, anchoring |
| **0091 Jupyter Kernel** | `aro repl --json` protocol, notebook cell semantics, output capture |
| **0092 `aro ask` Assistant** | Local model, tool registry, approval model, `.context` |

Proposal identifiers are unique and every `ARO-NNNN` reference must resolve —
enforced by `Scripts/check-proposals.py`, which runs in CI. When citing a GitLab
issue in code or docs, write `GitLab #<number>` — never the `ARO-` prefix, which
reads as a proposal reference. Eight such mistakes had accumulated in `Sources/`
before the check existed (GitLab #481).

## Concurrency

All core types (`SymbolTable`, `Token`, AST nodes, `ActionImplementation`) are `Sendable` for Swift 6.3 concurrency safety.

## Error Handling

The codebase follows these conventions:

### throws vs Optional

- **Boundaries** (parser entry points, action `execute()`, public API): Use `throws` with descriptive errors
- **Internal lookups** (symbol table, registry queries): Return `Optional` — callers decide whether absence is an error
- **SymbolTable**: Use `lookup()` for optional access, `lookupWithContext()` when a missing symbol is a hard error (it throws `SymbolLookupError` with scope chain context)

### Parser errors

- Use `expect(_:message:)` for single-token expectations
- Use `expectPreposition(_:message:)` for preposition tokens
- Use `expectIdentifier(message:)` for identifier-like tokens
- Direct `throw ParserError.unexpectedToken(...)` is reserved for multi-token or complex pattern checks where the helpers don't apply

### Silent fallbacks (`try?`)

- Never use `try?` without documenting **why** the fallback is acceptable
- When a `try?` fallback indicates data loss (e.g., returning `"[]"` for a failed array serialization), log a warning to stderr: `FileHandle.standardError.write(Data("[Component] Warning: ...\n".utf8))`
- `try?` is acceptable for truly optional operations (e.g., best-effort cleanup in `deinit`, optional file deletion)

## Git Commits

When creating git commits, do NOT include the Claude Code signature or co-author attribution in commit messages.