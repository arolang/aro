# ARO-0049: Interactive REPL

* Proposal: ARO-0049
* Author: ARO Language Team
* Status: **Draft**
* Requires: ARO-0001, ARO-0004, ARO-0005

## Abstract

This proposal introduces an interactive Read-Eval-Print Loop (REPL) for ARO, enabling developers to explore, prototype, and test ARO statements without the ceremony of creating files or defining feature sets. The REPL supports two seamless modes: **Direct Mode** for immediate statement execution and **Feature Set Mode** for defining complete feature sets interactively. Sessions persist variables across statements and can be exported as proper `.aro` files.

## 1. Motivation

### 1.1 The Problem

ARO's feature-set-centric design excels for production applications but creates friction for:

- **Exploration**: Understanding how actions work requires creating files
- **Prototyping**: Testing a computation requires boilerplate
- **Learning**: New users must understand feature sets before writing their first statement
- **Debugging**: Reproducing issues requires building complete applications

### 1.2 The Vision

A REPL where you can immediately write:

```
aro> <Set> the <name> to "Alice".
=> OK

aro> <Compute> the <greeting> from "Hello, " ++ <name> ++ "!".
=> "Hello, Alice!"
```

No files. No feature set definitions. Immediate feedback.

Yet when you need feature sets, you define them naturally:

```
aro> (Greet User: API) {
(Greet User)> <Extract> the <name> from the <request: body>.
(Greet User)> <Return> an <OK: status> with { greeting: "Hello, ${<name>}!" }.
(Greet User)> }
Feature set 'Greet User' defined
```

## 2. REPL Architecture

### 2.1 Dual-Mode Design

```
┌─────────────────────────────────────────────────────────┐
│                     ARO REPL Shell                       │
├─────────────────────────────────────────────────────────┤
│                                                          │
│   ┌─────────────────────┐  ┌─────────────────────────┐  │
│   │   Direct Mode       │  │  Feature Set Mode       │  │
│   │                     │  │                         │  │
│   │  Execute statements │  │  Define complete        │  │
│   │  immediately        │  │  feature sets           │  │
│   │                     │  │                         │  │
│   │  Variables persist  │  │  Multi-line input       │  │
│   │  across statements  │  │  with continuation      │  │
│   └─────────────────────┘  └─────────────────────────┘  │
│              │                        │                  │
│              └──────────┬─────────────┘                  │
│                         ▼                                │
│              ┌─────────────────────┐                     │
│              │   Session Context   │                     │
│              │   (Persistent)      │                     │
│              └─────────────────────┘                     │
└─────────────────────────────────────────────────────────┘
```

### 2.2 Session as Implicit Feature Set

The REPL session acts as an implicit feature set:

| Aspect | Session Behavior |
|--------|------------------|
| Name | `_repl_session_` (internal) |
| Business Activity | `Interactive` |
| Scope | All direct statements share scope |
| Lifetime | Until `:clear` or session end |
| Export | Becomes named feature set |

### 2.3 Mode Detection

```
Input
  │
  ├─► Starts with `:` ──────────────► Meta-command
  │
  ├─► Starts with `(Name: Activity) {` ──► Feature Set Mode
  │
  ├─► In Feature Set Mode + `}` ────► Exit to Direct Mode
  │
  └─► Otherwise ────────────────────► Direct Statement Execution
```

## 3. CLI Integration

### 3.1 Launching the REPL

```bash
# Start interactive REPL
aro repl

# Start with a file pre-loaded
aro repl --load ./my-definitions.aro

# Start with plugins
aro repl --plugin ./Plugins/my-plugin

# Start with HTTP server enabled
aro repl --http 8080
```

### 3.2 Command-Line Options

| Option | Description |
|--------|-------------|
| `--load <file>` | Pre-load definitions from file |
| `--plugin <path>` | Load plugin at startup |
| `--http <port>` | Start HTTP server on port |
| `--history <file>` | Use custom history file |
| `--no-color` | Disable colored output |

## 4. Direct Mode

### 4.1 Immediate Execution

Statements execute immediately against the session context:

```
aro> <Set> the <x> to 10.
=> OK

aro> <Set> the <y> to 20.
=> OK

aro> <Compute> the <sum> from <x> + <y>.
=> 30

aro> <Log> "Sum is ${<sum>}" to the <console>.
Sum is 30
=> OK
```

### 4.2 Result Display

| Result Type | Display |
|-------------|---------|
| Bound variable | `=> <value>` |
| Void/OK | `=> OK` |
| Error | `Error: <message>` |
| Complex object | Pretty-printed JSON |

### 4.3 Expression Evaluation

Direct expressions (without full statements) for quick testing:

```
aro> 2 + 2
=> 4

aro> "hello" ++ " " ++ "world"
=> "hello world"

aro> <name>
=> "Alice"
```

## 5. Feature Set Mode

### 5.1 Defining Feature Sets

Start a feature set with the standard syntax:

```
aro> (Calculate Tax: Finance) {
(Calculate Tax)> <Extract> the <amount> from the <input: value>.
  +
(Calculate Tax)> <Compute> the <tax> from <amount> * 0.2.
  +
(Calculate Tax)> <Return> an <OK: status> with { tax: <tax> }.
  +
(Calculate Tax)> }
Feature set 'Calculate Tax' defined
```

### 5.2 Multi-Line Continuation

The REPL detects incomplete input:

```
aro> <Create> the <user> with {
...>   name: "Alice",
...>   age: 30
...> }.
=> { name: "Alice", age: 30 }
```

Incomplete input triggers:
- Unclosed braces `{`, `(`, `[`, `<`
- Unclosed strings
- Statement without terminating `.`

### 5.3 Feature Set Invocation

Invoke defined feature sets:

```
aro> :invoke Calculate Tax
Input required. Set variables first or provide JSON:
aro> :set input { value: 100 }
=> OK
aro> :invoke Calculate Tax
=> { tax: 20 }
```

Or with inline input:

```
aro> :invoke Calculate Tax { value: 500 }
=> { tax: 100 }
```

## 6. Meta-Commands

### 6.1 Command Reference

| Command | Aliases | Description |
|---------|---------|-------------|
| `:help` | `:h`, `:?` | Show help |
| `:vars` | `:v` | List session variables |
| `:vars <name>` | | Show variable details |
| `:type <name>` | `:t` | Show variable type |
| `:clear` | `:c` | Clear session |
| `:history` | `:hist` | Show input history |
| `:history <n>` | | Show last n entries |
| `:save <file>` | | Save session to file |
| `:load <file>` | | Load and execute file |
| `:export [file]` | `:e` | Export as `.aro` file |
| `:fs` | | List feature sets |
| `:invoke <name>` | `:i` | Invoke feature set |
| `:services` | `:svc` | List active services |
| `:plugins` | | List loaded plugins |
| `:plugin load <path>` | | Load plugin |
| `:quit` | `:q`, `:exit` | Exit REPL |

### 6.2 Variable Inspection

```
aro> :vars
┌──────────┬─────────┬─────────────────────┐
│ Name     │ Type    │ Value               │
├──────────┼─────────┼─────────────────────┤
│ name     │ String  │ "Alice"             │
│ age      │ Integer │ 30                  │
│ user     │ Object  │ { name: "Alice"...  │
└──────────┴─────────┴─────────────────────┘

aro> :vars user
user
  Type:  Object
  Value: {
    name: "Alice",
    age: 30,
    email: "alice@example.com"
  }

aro> :type user
Object { name: String, age: Integer, email: String }
```

### 6.3 History Navigation

```
aro> :history 5
1. [ok]  <Set> the <name> to "Alice".           2ms
2. [ok]  <Set> the <age> to 30.                 1ms
3. [ok]  <Compute> the <sum> from <x> + <y>.    3ms
4. [err] <Get> the <missing> from <nowhere>.   --
5. [ok]  <Log> "test" to the <console>.        1ms
```

## 7. Tab Completion

### 7.1 Context-Aware Completion

The REPL provides intelligent completion based on cursor position:

| Position | Completes |
|----------|-----------|
| `<` | Action verbs |
| `<Action> the <` | Variables, type hints |
| `<Action> the <result> ` | Prepositions (from, to, with, for) |
| `:` | Meta-commands |
| `<Action> the <result> from the <` | Variables, services, repositories |

### 7.2 Examples

```
aro> <Com[TAB]
<Compute>  <Compare>  <Connect>

aro> <Compute> the <result> fr[TAB]
from

aro> <Compute> the <result> from <[TAB]
<x>       <y>       <name>    <user>

aro> :h[TAB]
:help     :history
```

### 7.3 Action Documentation

```
aro> <Compute>[TAB][TAB]
Compute [OWN]
  Transforms data using built-in operations.
  Operations: length, uppercase, lowercase, hash, arithmetic
  Example: <Compute> the <total> from <price> * <qty>.
```

## 8. Service Integration

### 8.1 HTTP Server

Start an HTTP server within the REPL:

```
aro> :service start http --port 3000 --contract ./openapi.yaml
HTTP server started on http://localhost:3000
Routes loaded from openapi.yaml:
  GET  /users     → listUsers
  POST /users     → createUser
  GET  /users/:id → getUser

aro> (listUsers: API) {
(listUsers)> <Return> an <OK: status> with [{ id: 1, name: "Alice" }].
(listUsers)> }
Feature set 'listUsers' defined
Route GET /users now handled by 'listUsers'
```

### 8.2 File Watcher

```
aro> :service start file-watcher --path ./data
File watcher started on ./data

aro> (File Change Handler: File Event Handler) {
(File Change...)> <Extract> the <path> from the <event: path>.
(File Change...)> <Log> "Changed: ${<path>}" to the <console>.
(File Change...)> }
Feature set 'File Change Handler' registered for file events
```

### 8.3 Service Management

```
aro> :services
┌────────────────────┬─────────────┬─────────┬──────────┐
│ Name               │ Type        │ Status  │ Details  │
├────────────────────┼─────────────┼─────────┼──────────┤
│ http-a1b2c3        │ http-server │ running │ :3000    │
│ watcher-d4e5f6     │ file-watcher│ running │ ./data   │
└────────────────────┴─────────────┴─────────┴──────────┘

aro> :service stop http-a1b2c3
HTTP server stopped
```

## 9. Plugin Testing

### 9.1 Loading Plugins

```
aro> :plugin load ./Plugins/json-validator
Loading plugin: json-validator
  Type: rust-plugin
  Actions: validate-json, format-json, minify-json
Plugin loaded successfully

aro> :plugins
┌─────────────────┬──────┬─────────────────────────────────┐
│ Name            │ Type │ Actions                         │
├─────────────────┼──────┼─────────────────────────────────┤
│ json-validator  │ rust │ validate-json, format-json, ... │
└─────────────────┴──────┴─────────────────────────────────┘
```

### 9.2 Testing Plugin Actions

```
aro> <Set> the <data> to { name: "test", valid: true }.
=> OK

aro> <Validate-json> the <result> from the <data>.
=> { valid: true, errors: [] }

aro> <Set> the <bad-data> to "{ invalid json }".
=> OK

aro> <Validate-json> the <result> from the <bad-data>.
=> { valid: false, errors: ["Unexpected token at position 2"] }
```

### 9.3 Plugin Reload

```
aro> :plugin reload json-validator
Unloading json-validator...
Recompiling...
Loading json-validator...
Plugin reloaded successfully
```

## 10. Session Export

### 10.1 Export as Feature Set

Convert your REPL session into a proper `.aro` file:

```
aro> <Set> the <base-price> to 100.
=> OK
aro> <Compute> the <tax> from <base-price> * 0.2.
=> 20
aro> <Compute> the <total> from <base-price> + <tax>.
=> 120

aro> :export
(* Generated from ARO REPL session *)
(* Date: 2024-01-15T10:30:00Z *)

(REPL Session: Interactive) {
    <Set> the <base-price> to 100.
    <Compute> the <tax> from <base-price> * 0.2.
    <Compute> the <total> from <base-price> + <tax>.
}

aro> :export ./pricing.aro
Exported to ./pricing.aro
```

### 10.2 Export as Test

Generate a test file with assertions:

```
aro> :export --test ./pricing-test.aro
(* Generated test from ARO REPL session *)

(Pricing Test: Test) {
    <Set> the <base-price> to 100.
    <Assert> the <base-price> is 100.

    <Compute> the <tax> from <base-price> * 0.2.
    <Assert> the <tax> is 20.

    <Compute> the <total> from <base-price> + <tax>.
    <Assert> the <total> is 120.
}
```

### 10.3 Export Options

| Option | Description |
|--------|-------------|
| `--name <name>` | Custom feature set name |
| `--activity <act>` | Custom business activity |
| `--test` | Export as test with assertions |
| `--include-errors` | Include failed statements (commented) |
| `--compact` | Minimal formatting |

## 11. Error Handling

### 11.1 Interactive Error Display

```
aro> <Compute> the <result> from <undefined-var> + 1.
Error: Undefined variable 'undefined-var'

  Suggestion: Use :vars to see available variables

  Available similar:
    - user
    - user-name

  [r] Retry  [v] Show vars  [c] Cancel
```

### 11.2 Syntax Help

```
aro> <Compute> the result from x + 1
Error: Missing angle brackets around 'result'

  Expected: <Compute> the <result> from <x> + 1.
                          ^      ^

  ARO variables must be wrapped in angle brackets.
```

### 11.3 Recovery Options

When errors occur:
- Press `r` to retry with cursor at error position
- Press `e` to edit the previous command
- Press `c` to cancel and start fresh

## 12. Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `Tab` | Auto-complete |
| `Up/Down` | Navigate history |
| `Ctrl+R` | Reverse search history |
| `Ctrl+C` | Cancel current input |
| `Ctrl+D` | Exit REPL (on empty line) |
| `Ctrl+L` | Clear screen |
| `Ctrl+U` | Clear line |
| `Ctrl+W` | Delete word backward |

## 13. Configuration

### 13.1 REPL Configuration File

Create `~/.aro/repl.yaml`:

```yaml
# REPL Configuration
prompt:
  direct: "aro> "
  continuation: "...> "
  feature_set: "({name})> "

history:
  file: ~/.aro/history
  max_entries: 10000

completion:
  enabled: true
  show_types: true
  fuzzy: false

display:
  colors: true
  max_output_lines: 50
  truncate_strings: 100

startup:
  # Commands to run on startup
  commands:
    - ":load ~/.aro/prelude.aro"

  # Plugins to load
  plugins:
    - ~/.aro/plugins/common
```

### 13.2 Prelude File

A `prelude.aro` file for common definitions:

```aro
(* ~/.aro/prelude.aro *)
(* Loaded automatically on REPL startup *)

(Debug Helper: Utilities) {
    <Log> <message> to the <console>.
    <Return> an <OK: status> for <debug>.
}
```

## 14. Implementation

### 14.1 New Files

```
Sources/
├── AROREPL/
│   ├── Core/
│   │   ├── REPLShell.swift          # Main REPL loop
│   │   ├── REPLSession.swift        # Session state management
│   │   ├── REPLMode.swift           # Mode enum and transitions
│   │   └── SessionContext.swift     # Persistent runtime context
│   ├── Parser/
│   │   └── MultilineDetector.swift  # Incomplete input detection
│   ├── Commands/
│   │   ├── MetaCommand.swift        # Command protocol
│   │   ├── MetaCommandRegistry.swift
│   │   └── BuiltinCommands.swift    # :help, :vars, etc.
│   ├── Completion/
│   │   ├── CompletionEngine.swift   # Tab completion
│   │   └── CompletionProviders.swift
│   ├── Services/
│   │   └── REPLServiceManager.swift # Service lifecycle
│   ├── Plugins/
│   │   └── REPLPluginLoader.swift   # Interactive plugin loading
│   ├── Export/
│   │   └── SessionExporter.swift    # Export to .aro
│   └── Errors/
│       └── REPLErrorHandler.swift   # Error formatting
└── AROCLI/
    └── Commands/
        └── ReplCommand.swift        # CLI entry point
```

### 14.2 Parser Extensions

Add to `Parser.swift`:

```swift
extension Parser {
    /// Parse a standalone statement for REPL use
    public func parseStandaloneStatement() throws -> ParseResult {
        // Check for feature set start
        if check(.leftParen) && isFeatureSetStart() {
            return .featureSetStart(try parseFeatureSetHeader())
        }

        // Parse as statement
        return .statement(try parseStatement())
    }
}
```

### 14.3 Key Protocols

```swift
/// REPL session management
public protocol REPLSession: AnyObject, Sendable {
    var id: UUID { get }
    var context: RuntimeContext { get }
    var featureSets: [String: AnalyzedFeatureSet] { get }
    var history: [HistoryEntry] { get }

    func execute(_ statement: Statement) async throws -> REPLResult
    func defineFeatureSet(_ featureSet: FeatureSet) async throws
    func invokeFeatureSet(named: String) async throws -> Response
    func clear()
    func export() -> String
}

/// Meta-command protocol
public protocol MetaCommand: Sendable {
    static var name: String { get }
    static var aliases: [String] { get }
    static var help: String { get }

    func execute(args: [String], session: REPLSession) async throws -> MetaCommandResult
}
```

## 15. Examples

### 15.1 Data Processing Pipeline

```
aro> <Set> the <data> to [
...>   { name: "Alice", score: 85 },
...>   { name: "Bob", score: 92 },
...>   { name: "Carol", score: 78 }
...> ].
=> OK

aro> <Filter> the <passing> from <data> where score >= 80.
=> [{ name: "Alice", score: 85 }, { name: "Bob", score: 92 }]

aro> <Map> the <names> from <passing> select name.
=> ["Alice", "Bob"]

aro> <Compute> the <average: average> from <data> by score.
=> 85
```

### 15.2 HTTP API Testing

```
aro> :service start http --port 3000

aro> (getHealth: API) {
(getHealth)> <Return> an <OK: status> with { status: "healthy" }.
(getHealth)> }
Feature set 'getHealth' defined

aro> <Fetch> the <response> from "http://localhost:3000/health".
=> { status: "healthy" }
```

### 15.3 Plugin Development Workflow

```
aro> :plugin load ./Plugins/my-new-plugin --watch
Plugin loaded with file watching enabled

# Make changes to plugin source...

[Plugin recompiled automatically]
Reloaded: my-new-plugin (2 actions)

aro> <My-action> the <result> from <test-input>.
=> { success: true }
```

## 16. Summary

| Feature | Description |
|---------|-------------|
| **Direct Mode** | Execute statements immediately without feature sets |
| **Feature Set Mode** | Define complete feature sets interactively |
| **Session Persistence** | Variables survive across statements |
| **Meta-Commands** | `:vars`, `:clear`, `:export`, `:services`, etc. |
| **Tab Completion** | Context-aware completion for actions, variables |
| **Service Integration** | HTTP, file watchers, sockets work in REPL |
| **Plugin Testing** | Load, test, and reload plugins interactively |
| **Session Export** | Convert sessions to `.aro` files or tests |
| **Error Recovery** | Interactive error handling with suggestions |

The ARO REPL transforms the development experience from file-based iteration to immediate, interactive exploration while preserving full access to ARO's event-driven feature set architecture.

---

## References

- `Sources/AROParser/Parser.swift` - Parser extensions needed
- `Sources/ARORuntime/Core/RuntimeContext.swift` - Session context base
- `Sources/ARORuntime/Core/FeatureSetExecutor.swift` - Statement execution
- `Sources/AROCLI/ARO.swift` - CLI integration point
- `Examples/` - Usage examples for REPL testing
