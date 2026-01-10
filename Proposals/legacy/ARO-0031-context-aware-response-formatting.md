# ARO-0031: Context-Aware Response Formatting

* Proposal: ARO-0031
* Author: ARO Language Team
* Status: **Implemented**
* Requires: ARO-0001, ARO-0020

## Abstract

ARO automatically formats activity responses based on the invocation context: JSON for HTTP/WebSocket requests, structured plaintext for console/CLI invocations, and detailed diagnostics for test/debug modes. This eliminates manual format conversion and makes ARO outputs natively consumable by web clients, shell pipelines, and debugging tools.

## Motivation

Consider the Greeting API example from the tutorial:

```aro
(sayHello: Greeting API) {
    <Extract> the <name> from the <queryParameters: name>.
    <Create> the <greeting> with { message: "Hello, ${name}!" }.
    <Return> an <OK: status> with <greeting>.
}
```

When called via HTTP, JSON is perfect:

```bash
$ curl http://localhost:8080/hello?name=Developer
{"status":"OK","reason":"success","data":{"greeting":{"message":"Hello, Developer!"}}}
```

But when the same activity runs from the console, JSON creates friction:

```bash
# Without context-aware formatting - requires parsing
$ aro run ./MyAPI
{"status":"OK","reason":"success","data":{"greeting":{"message":"Hello, Developer!"}}}

# To extract values, you'd need awkward constructs:
$ aro run ./MyAPI | jq -r '.data.greeting.message'
```

Shell scripts and CLI tools shouldn't need `jq`, `grep`, `sed`, or `awk` to consume ARO output. The runtime should understand *where* the request came from and respond accordingly.

ARO code should work consistently across all contexts without requiring explicit formatting logic:

1. **API Responses**: Machine consumers expect JSON/structured data
2. **Console Output**: Humans reading logs want clear, formatted text
3. **Test Assertions**: Developers need detailed diagnostic information
4. **Event Payloads**: Event handlers require typed data structures

## Design Principles

1. **Write Once**: Same ARO code works everywhere
2. **Context Detection**: Runtime automatically detects execution context
3. **Appropriate Formatting**: Each context gets optimal representation
4. **No Source Changes**: Existing code benefits without modification
5. **Unix Philosophy**: "Write programs that handle text streams, because that is a universal interface"

## Execution Contexts

### Machine Context

Triggered by HTTP API calls, WebSocket connections, and event handlers. Output is JSON-serializable structured data optimized for programmatic consumption.

### Human Context

Triggered by CLI execution (`aro run`) and console output. Output is formatted text with clear key-value structure for human readability.

### Developer Context

Triggered by testing (`aro test`) and debug modes (`--debug` flag). Output includes detailed diagnostic information with type annotations for debugging.

## Context Detection

| Entry Point | Detected Context | Format |
|-------------|------------------|--------|
| HTTP route handler | Machine | JSON |
| WebSocket connection | Machine | JSON |
| Event dispatch target | Machine | JSON |
| `aro run` (interactive) | Human | Plaintext KV |
| Unix socket (TTY/pipe) | Human | Plaintext KV |
| `aro test` | Developer | Diagnostic |
| `--debug` flag | Developer | Diagnostic |

## Output Format Specification

Given this activity result:

```aro
{
    message: "Hello, Developer!",
    timestamp: 1733318400,
    user: {
        id: 42,
        name: "Developer"
    },
    tags: ["greeting", "demo"]
}
```

### Machine Context (JSON)

Compact JSON for API responses:

```json
{"data":{"message":"Hello, Developer!","tags":["greeting","demo"],"timestamp":1733318400,"user":{"id":42,"name":"Developer"}},"reason":"success","status":"OK"}
```

### Human Context (Plaintext KV)

Readable key-value pairs for console using dot notation for nested objects:

```
[OK] success
  message: Hello, Developer!
  tags: demo, greeting
  timestamp: 1733318400
  user.id: 42
  user.name: Developer
```

Human output follows these rules:
- Status line first: `[STATUS] reason`
- Indented data fields
- Nested objects use dot notation (`user.name` not `user: {name: ...}`)
- Arrays as sorted, comma-separated values
- No quotes around simple strings

### Developer Context (Diagnostic Table)

Formatted table with type annotations for debugging:

```
┌──────────────────────────────────────────────┐
│ Response<OK>                                 │
├────────────────┬─────────────────────────────┤
│ reason         │ String("success")           │
│ message        │ String("Hello, Developer!") │
│ tags           │ Array<String>[2]            │
│ timestamp      │ Int(1733318400)             │
│ user.id        │ Int(42)                     │
│ user.name      │ String("Developer")         │
└────────────────┴─────────────────────────────┘
```

Developer output includes:
- Clean table format for easy scanning
- Type annotations for all values
- Flattened keys with dot notation
- Automatic column width adjustment

## Benefits

### 1. Shell-Native Consumption

Extract values with standard Unix tools - no JSON parsers required:

```bash
# Human-readable output is immediately scannable
$ aro run ./MyAPI
[OK] success
  greeting.message: Hello, Developer!

# Pipe-friendly for simple extraction
$ aro run ./MyAPI | grep 'greeting.message:'
```

### 2. Pipeline-Friendly

Consistent output makes piping trivial:

```bash
# Compare two responses
$ diff <(aro run ./staging-config) <(aro run ./prod-config)
```

### 3. Human Readable

Console output is immediately scannable without mental JSON parsing.

### 4. Zero Configuration

The runtime detects context automatically. No flags, no format specifiers, no content negotiation boilerplate in activity code.

### 5. Debug-Friendly

Developer context provides rich type information during test development and debugging sessions.

## Explicit Override

Users can force a specific format when needed:

```bash
# Force JSON output in CLI (future enhancement)
$ aro run ./MyAPI --format=json

# Force plaintext from HTTP (via Accept header, future enhancement)
$ curl -H "Accept: text/plain" http://localhost:8080/hello
```

## Implementation

### OutputContext Enum

```swift
public enum OutputContext: String, Sendable, Equatable, CaseIterable {
    case machine    // API, events - JSON output
    case human      // CLI, console - formatted text
    case developer  // Tests, debug - diagnostic output
}
```

### ResponseFormatter

Formats responses differently based on context:

- `formatForMachine()` - Compact JSON with sorted keys
- `formatForHuman()` - Readable plaintext with dot notation for nested objects
- `formatForDeveloper()` - Formatted table with type annotations

### ExecutionContext Integration

The `ExecutionContext` protocol provides:

```swift
var outputContext: OutputContext { get }
var isDebugMode: Bool { get }
var isTestMode: Bool { get }
```

### Log Action Integration

The `<Log>` action respects output context:

```aro
<Log> the <message> for the <console> with "Processing request".
```

| Context | Output |
|---------|--------|
| Human | `[FeatureSetName] Processing request` |
| Machine | `{"level":"info","source":"FeatureSetName","message":"Processing request"}` |
| Developer | Formatted table with source and message |

## Alternatives Considered

### 1. Always Return JSON Everywhere

**Rejected**: Forces CLI users into JSON-parsing toolchains. Violates ARO's "clarity over cleverness" philosophy.

### 2. YAML for Console Output

**Rejected**: More complex to parse than simple KV pairs. Introduces ambiguity (is `yes` a boolean or string?).

### 3. TOML-style Output

**Rejected**: Section headers add complexity. Inline structures are simpler for typical response sizes.

### 4. Tab-Separated Values

**Rejected**: Harder to read, doesn't handle nested structures elegantly.

## Compatibility

This proposal:

- Does not change ARO syntax
- Does not break existing code
- Enhances existing Return and Log actions
- Requires no migration
- Is additive and non-breaking

## References

- ARO Tutorial: https://arolang.github.io/aro/tutorial.html
- Unix Philosophy: "Write programs that handle text streams, because that is a universal interface"

## Revision History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2025-12 | Initial specification and implementation |
| 1.1 | 2025-12 | Added detailed examples, format specification, benefits, and alternatives |
| 1.2 | 2025-12 | Human output uses dot notation; Developer output uses formatted table |
